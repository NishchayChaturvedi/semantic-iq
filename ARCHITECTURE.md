# SemanticIQ — Architecture Decision Records

Modeling decisions for the SemanticIQ showcase. Accumulated here as they are made.
Each record captures: the decision, the alternatives rejected, and the reasoning.

---

## Decision Record 1 — Snowflake Semantic View Design

**Decision:** Use Snowflake Semantic Views as the governed semantic layer for `saas_revenue_model`.

**Syntax constraints confirmed against Snowflake 10.21.x:**
- `TABLES` clause: fully qualified name + `PRIMARY KEY (col)` — no `AS` alias, no `WITH` prefix
- `DIMENSIONS`: `table.column AS table.alias` — the alias portion must reference an **actual column** in the source table; you cannot invent logical names here. Renaming (e.g., `segment → segment_current`) must be done in the upstream dbt mart view.
- `METRICS`: `table.metric_name AS aggregate_expression` — metric name is table-qualified
- `RELATIONSHIPS`: unqualified table names; requires `PRIMARY KEY` declared in `TABLES`
- No inline `COMMENT` on individual dimension or metric entries; `COMMENT` applies at view level only

**Queryability constraint:**
Snowflake Semantic Views are metadata objects, not directly queryable via standard SQL aggregations. Validation is via `DESCRIBE SEMANTIC VIEW`, `SHOW SEMANTIC VIEWS`, and Cortex Analyst queries — not raw `SELECT`. Single-table dimension browsing works via `SELECT` (e.g., `SELECT segment FROM saas_revenue_model LIMIT 5`), but cross-table metric aggregation does not. Attempting `SUM(total_mrr)` returns "Invalid metric expression"; attempting `SELECT *` fails because METRIC type entries are not DIMENSION or FACT types. The SCD2 dual-path divergence proof was validated against the mart tables directly.

**SCD2 dual-path implementation:**
The semantic view exposes two dimension paths to account attributes:
- `dim_accounts` (190 rows, all SCD2 versions) — joined via `account_key` surrogate, pre-resolved in the fact at dbt build time → gives segment at billing time
- `dim_accounts_current` (150 rows, `is_current = TRUE` only) — joined via `account_id` business key at query time → gives today's segment

The `_current` suffix columns (`segment_current`, `industry_current`, `contract_currency_current`) are defined in `dim_accounts_current` directly, not renamed in the semantic view DDL, because the `AS table.alias` clause requires the alias to be an existing column.

---

## Decision Record 2 — Bridge vs Fact account_key Resolution

**Decision:** `bridge_account_products` does NOT resolve `account_key` at dbt build time. All three fact tables (`fact_subscriptions`, `fact_usage_daily`, `fact_services_milestones`) DO resolve it at build time.

**Why facts resolve account_key at build time:**
Each fact carries a point-in-time event date (`billing_month`, `usage_date`, `completed_date`). That date anchors exactly which SCD2 version of the account was active, so the surrogate key resolution is deterministic and unambiguous.

**Why the bridge does not:**
`bridge_account_products` represents a time-ranged many-to-many relationship (product assignment valid from `effective_from` to `effective_to_effective`). A single assignment can span multiple SCD2 versions of the same account. Resolving `account_key` at build time would require picking one version arbitrarily — wrong semantics. Fact queries that use the bridge align the range join with `dim_accounts` at query time: `bridge JOIN dim_accounts ON account_id AND event_date BETWEEN bridge.effective_from AND bridge.effective_to_effective`. The date anchor lives where the date is known: at the fact grain.

**Why this matters:** Bridge tables represent structural membership; facts represent measurable events. The resolution point (build time vs query time) should follow where the disambiguating date lives.

---

## Decision Record 3 — FX Gap-Filling vs FX Conversion Separation

**Decision:** `dim_fx_rates_filled` forward-fills three known gap dates using `LAST_VALUE IGNORE NULLS`. FX conversion (amount × rate) is NOT performed in dbt — it lives exclusively in `saas_revenue_model` metric definitions.

**Why gap-filling is NOT an FX conversion violation:**
Gap-filling is data quality resolution: the rate *exists* in the real world on the three gap dates (`GBP 2022-08-29`, `EUR 2023-03-14`, `GBP 2024-01-02`) — it simply was not captured. Forward-filling with the prior day's SPOT rate is a factual correction, not a business logic choice. The conversion expression (amount × rate) still lives exclusively in the semantic view.

**Boundary:** `dim_fx_rates_filled` is a cleaned reference table. It contains no amounts, no join to facts, and no multiplication. Any query that uses it to convert currency amounts belongs in the semantic layer.

**Why this decision record exists:** The two responsibilities (data quality vs business logic) look similar from the outside — both touch FX rates — but their nature is fundamentally different.

---

## Decision Record 4 — Snowflake Semantic View Metric Constraints (Complexity 2)

These are platform constraints, not design choices. Documented so they are not re-discovered.

**Constraint 1: `NON ADDITIVE BY` is not supported on Snowflake 10.21.x**

The `NON ADDITIVE BY (column_list)` clause — used to mark semi-additive metrics so BI tools know not to sum them across certain dimensions — is a syntax error on this Snowflake account version. All three syntax variants tested fail with "unexpected 'NON'".

Specific failure mode for `distinct_account_count`: `COUNT(DISTINCT account_id)` is semi-additive over time. If a user in Sigma selects `distinct_account_count` over a multi-month range *without* including `billing_month` as a dimension, the metric counts unique accounts across all selected months — which is correct for "total unique accounts in Q1". But if a user slices by quarter and tries to sum month-level distinct counts to get a quarterly total, they will overcount accounts that appear in multiple months. Without `NON ADDITIVE BY`, this constraint cannot be enforced at the semantic layer. Resolution: govern via BI-layer documentation and training — do not re-aggregate already-grouped `distinct_account_count` values.

**Constraint 2: Cross-table CASE WHEN expressions are rejected in the METRICS clause**

Metric expressions referencing columns from a joined dimension table (e.g., `CASE WHEN dim_accounts_current.account_id IS NOT NULL THEN ...`) fail with "invalid identifier" even when the table is registered in TABLES and the relationship is declared in RELATIONSHIPS. The METRICS clause evaluates expressions in the context of the base fact table only.

Resolution: pre-compute the boolean flag at dbt build time. `is_active_account` is computed in `fact_subscriptions` as `c.account_id IS NOT NULL` from a LEFT JOIN to `dim_accounts_current`. The semantic view metric then uses the single-table expression `CASE WHEN fact_subscriptions.is_active_account THEN ...`. This means `is_active_account` reflects account status as of the last dbt run, not at query time — a known and accepted approximation for the NRR showcase.

---

## Decision Record 5 — FX Conversion: Intended Query-Time, Forced to dbt (Complexity 6)

**Intent per DR3:** FX conversion logic (amount × rate) was designed to live in the semantic view METRICS clause, keeping the mart layer free of business logic and enabling true query-time currency conversion with up-to-date rates.

**Platform constraint:** Cross-table column references in METRICS are rejected (confirmed by Probe 3 — `SUM(fact_subscriptions.mrr_amount * dim_fx_rates_filled.rate)` fails with "invalid identifier 'DIM_FX_RATES_FILLED.RATE'"). This is the same constraint documented in DR4 for `active_mrr`. Compound PRIMARY KEY and multi-column RELATIONSHIPS both work (Probes 1 and 2 passed) — the blocker is exclusively the METRICS expression scope.

**Resolution:** `mrr_amount_usd` and `arr_amount_usd` are pre-computed in `fact_subscriptions` at dbt build time via `LEFT JOIN dim_fx_rates_filled ON (currency, billing_month)`. USD rows use `COALESCE(rate, 1.0)` passthrough. Semantic view metrics then use single-table `SUM(fact_subscriptions.mrr_amount_usd)`.

FX conversion was designed as query-time semantic layer logic per DR3 — forced to dbt pre-computation due to Snowflake METRICS clause rejecting cross-table column references. Same resolution pattern as `active_mrr` in Complexity 2. DR3 intent is preserved in documentation; implementation is pragmatically in the mart layer.

**Implication:** If exchange rates are updated in `dim_fx_rates_filled`, `fact_subscriptions` must be re-run to refresh USD amounts. The semantic view does not pick up rate changes automatically.

---

## Decision Record 6 — Role-Playing Date Dimensions (Complexity 3)

**Pattern:** `dim_date` serves four roles in `saas_revenue_model`: billing calendar (`billing_month`), creation calendar (`created_date`), milestone calendar (`completed_date`), and usage calendar (`usage_date`). Each role requires a distinct logical name so Sigma can distinguish "MRR by billing month" from "subscriptions by cohort creation quarter" from API usage by day.

**Constraint confirmed by probe:** The Snowflake Semantic View TABLES clause rejects the same fully-qualified table name appearing twice — error 002027 "duplicate alias 'DIM_DATE'". No AS alias syntax exists in TABLES (DR1), so the alias is always derived from the object name. This means the same physical table cannot serve multiple roles within one semantic view.

**Resolution:** Four thin dbt views — `dim_date_billing`, `dim_date_created`, `dim_date_milestone`, `dim_date_usage` — each defined as `SELECT * FROM dim_date`. Zero data duplication; each view is a transparent pass-through. Same pattern as `dim_accounts_current` in Complexity 1.

**`created_date` pre-computation:** `fact_subscriptions.created_at` is a TIMESTAMP. RELATIONSHIPS requires an exact column name (no expression casting), so `created_at::DATE AS created_date` is pre-computed in the mart — consistent with the single-table-only constraint on DIMENSIONS (DR1) and the broader pattern of pre-computing join keys at dbt build time.

**Complexity 5 additions:** `dim_date_milestone` and `dim_date_usage` were wired into the semantic view in Complexity 5 alongside `fact_services_milestones` and `fact_usage_daily`. `dim_date_usage` was kept distinct from `dim_date_billing` deliberately — a shared date role would hide the daily/monthly grain mismatch between usage and subscription facts; four separate roles force BI consumers to actively choose a time axis. See DR7.

---

## Decision Record 7 — Multi-Grain Fact Integration and Non-Conformance (Complexity 5)

**Facts integrated:** `fact_services_milestones` (milestone grain, irregular dates) and `fact_usage_daily` (API-key + day grain, 45,995 rows) added to `saas_revenue_model` alongside `fact_subscriptions` (account + month grain).

**What works:** All three facts share `dim_accounts` via `account_key`, pre-resolved at dbt build time. Snowflake Semantic Views handle multi-fact configurations correctly — each fact registers its own RELATIONSHIPS, and `dim_accounts` serves as the conforming dimension across all three.

**The non-conformance problem:** `fact_usage_daily` is at day grain; `fact_subscriptions` is at month grain. When a user slices both `total_usage_revenue` and `total_mrr` together by `dim_accounts.segment` in Sigma, the join through `dim_accounts` works correctly — but the metric values represent different time units. There is no semantic-layer-level guard against summing daily usage revenue and monthly subscription MRR into a combined "total revenue" figure without declaring a common time spine. This is a governance constraint enforced by documentation and BI-layer training, not a platform-level constraint.

**Why `dim_date_usage` is kept separate from `dim_date_billing`:** A single shared date role would allow Sigma to implicitly treat billing month and usage date as interchangeable time axes. Four distinct role views (`dim_date_billing`, `dim_date_created`, `dim_date_milestone`, `dim_date_usage`) force BI consumers to actively choose a time axis — making the grain mismatch visible as a user experience rather than hiding it.

**USD pre-computation extended:** `revenue_amount_usd` (milestones) and `daily_amount_usd` (usage) are pre-computed in their respective mart tables via `LEFT JOIN dim_fx_rates_filled`, same pattern as `fact_subscriptions`. See DR5.

---

## Decision Record 8 — Ragged Hierarchy: Fan-Out Bridge Cannot Be the Dim Side (Complexity 4)

**The problem:** `dim_account_hierarchy` is a fan-out bridge table (292 rows, 134 accounts — average 2.18 rows per `account_id`). Registering it in the SV TABLES clause with `PRIMARY KEY (account_id)` would violate uniqueness: `account_id` is not unique in this table. Registering with the correct compound `PRIMARY KEY (account_id, ancestor_id)` makes no single-column relationship from `fact_subscriptions (account_id)` resolvable to that PK. Either way, the bridge cannot be the dimension side of a RELATIONSHIP.

**What "would" happen if it could be joined:** A flat `SUM(mrr_amount) GROUP BY segment` via a fact_subscriptions → dim_account_hierarchy join would multiply each subscription row by its ancestor count (up to 5× for the deepest accounts) before aggregating — silently inflating all subscription metrics in any query that traversed the hierarchy path. The correct rollup (`SUM(mrr_amount) GROUP BY ancestor_id`) works precisely because each subscription row contributes once per ancestor; the fan-out is the feature, not the bug — but only in the rollup context, not in flat queries.

**Resolution:** Pre-compute the fan-out join in dbt as `fact_hierarchy_rollup` (grain: `ancestor_id × billing_month`, 4,778 rows). The semantic view sees a clean fact table with no bridge fan-out. `ancestor_id` relates to `dim_accounts_current (account_id)` for ancestor segment/industry; `billing_month` reuses `dim_date_billing` — confirmed that one dimension table can be referenced by multiple facts.

**`subsidiary_count` semi-additivity:** `COUNT(DISTINCT account_id)` in `fact_hierarchy_rollup` is computed per `billing_month` snapshot. Do not sum `subsidiary_count` across months — an account appearing in multiple months is overcounted. Read at a single `billing_month` or use MAX. Same governance pattern as `distinct_account_count` on `fact_subscriptions` (DR4).

**`UNKNOWN` ancestor sentinel:** Four accounts with deliberately NULLed `parent_account_id` resolve to an `UNKNOWN` synthetic ancestor in `dim_account_hierarchy`. These 36 rows in `fact_hierarchy_rollup` (UNKNOWN × 36 billing months) have `ancestor_depth = NULL` — no real position in the tree — and `is_root_ancestor = TRUE`. The `ancestor_id → dim_accounts_current` relationship returns NULL attributes for UNKNOWN, which is correct and expected.

---

## Decision Record 9 — Row-Level Security: SV Metadata Constraint + Secure View Intermediary (Complexity 7)

**Probe result: Semantic Views do not support RAP attachment.** `ALTER SEMANTIC VIEW ... ADD ROW ACCESS POLICY` fails with SQL compilation error 001003 `syntax error ... unexpected 'ADD'`. Snowflake Semantic Views are metadata objects (defining TABLES, RELATIONSHIPS, DIMENSIONS, METRICS); Row Access Policies require a data object (table or view) to attach to. There is no column in the SV's own schema to attach a policy to.

**Platform constraint 2: `SYSTEM$GET_USER_CONTEXT` unavailable.** The planned session-context approach (set REGION per session, RAP reads it) is unsupported on this Snowflake account version. Resolution: role-based mapping via a fixture table `RAP_ROLE_REGION_MAP (snowflake_role, region)`. The session's `CURRENT_ROLE()` is looked up in this table to derive the rep's region. No per-session setup required — region is determined automatically at login.

**Resolution: Secure view intermediary layer.** A `SEMANTIC_IQ.SEMANTIC_LAYER` schema holds four SECURE VIEWs — transparent `SELECT *` pass-throughs of the four MARTS fact tables. `rap_account_region` is attached to each view on the appropriate column (`account_id` for three facts, `ancestor_id` for `fact_hierarchy_rollup`). The `saas_revenue_model` SV references `SEMANTIC_LAYER.FACT_*` instead of `MARTS.FACT_*`. MARTS fact tables are untouched — no policies. Dimension tables (`DIM_ACCOUNTS`, `DIM_DATE_*`) are not row-filtered; account attributes are visible once the fact row passes the filter.

**RAP function design.** The function `rap_account_region (p_account_id VARCHAR) → BOOLEAN` has two branches:
1. `CURRENT_ROLE() IN ('SEMANTIC_IQ_GLOBAL_ROLE', 'SYSADMIN', 'ACCOUNTADMIN')` → TRUE (finance/admin bypass)
2. EXISTS join of `DIM_ACCOUNT_OWNERSHIP × RAP_ROLE_REGION_MAP` filtered by `CURRENT_ROLE()` and `is_current = TRUE`

The function runs under **owner (definer) rights** — SYSADMIN can query `DIM_ACCOUNT_OWNERSHIP` and `RAP_ROLE_REGION_MAP` regardless of the session role's grants. Session users need no SELECT on these tables.

**Safe-fail confirmed.** A role absent from `RAP_ROLE_REGION_MAP` and not in the global bypass list returns FALSE for every row — zero rows visible, not all rows. Verified: `SEMANTIC_IQ_NOROLE` (test role with SELECT on the secure views but no mapping entry) returned `COUNT(DISTINCT account_id) = 0`.

**Verification matrix results (all pass):**

| Query | User | Role | Accounts | MRR |
|---|---|---|---|---|
| Q1 — MARTS direct (no RAP) | SYSADMIN | SYSADMIN | 150 | 8,602,548 |
| Q2 — SEMANTIC_LAYER (finance) | SEMANTIC_IQ_FINANCE | GLOBAL_ROLE | 150 | 8,602,548 |
| Q3 — SEMANTIC_LAYER (EMEA rep) | SEMANTIC_IQ_EMEA_REP | EMEA_ROLE | 50 | 3,213,166 |
| Q4 — SEMANTIC_LAYER (no mapping) | SEMANTIC_IQ_NOROLE_USER | NOROLE | **0** | NULL |

Q1 = Q2 proves the mart is open and the global bypass is transparent. Q3 proves regional filtering. Q4 is the safe-fail gate.

**Ghost accounts: emergent governance behavior.** 16 accounts appear in `FACT_SUBSCRIPTIONS` but have no current ownership record in `DIM_ACCOUNT_OWNERSHIP`. These were not constructed as a deliberate RLS test case — they emerged from the data generator's churn simulation (accounts that churned may have lost their ownership assignment). Under the RAP: ghost accounts are visible to the finance bypass (Q2 count = Q1 count = 150) and invisible to ALL regional reps (no current owner → EXISTS = FALSE for every region value). This is correct governance behavior: orphaned/churned accounts roll up to finance, not to any rep's portfolio. The total rep-visible accounts (50 EMEA + 34 APAC + 26 LATAM + 24 North America = 134) confirm 16 ghost accounts are excluded from regional views.

**Demo user lifecycle.** `SEMANTIC_IQ_EMEA_REP` and `SEMANTIC_IQ_FINANCE` are active for the Sigma showcase. Drop commands after showcase:
```sql
DROP USER SEMANTIC_IQ_EMEA_REP;
DROP USER SEMANTIC_IQ_FINANCE;
DROP ROLE SEMANTIC_IQ_EMEA_ROLE;
DROP ROLE SEMANTIC_IQ_GLOBAL_ROLE;
```

---

## Guiding Constraint — Snowflake Semantic View METRICS Clause Is Single-Table Only

Snowflake Semantic View METRICS clause is single-table only — no cross-table column references, no cross-table arithmetic, no window functions. Any computation requiring multiple tables must be pre-computed at dbt build time. This constraint affected `active_mrr` (Complexity 2), `mrr_amount_usd`/`arr_amount_usd` (Complexity 6), and rules out true NRR as a semantic view metric entirely.

---
