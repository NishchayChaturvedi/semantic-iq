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

## Decision Record 5 — FX Conversion: Intended Query-Time, Forced to dbt (Complexity 3)

**Intent per DR3:** FX conversion logic (amount × rate) was designed to live in the semantic view METRICS clause, keeping the mart layer free of business logic and enabling true query-time currency conversion with up-to-date rates.

**Platform constraint:** Cross-table column references in METRICS are rejected (confirmed by Probe 3 — `SUM(fact_subscriptions.mrr_amount * dim_fx_rates_filled.rate)` fails with "invalid identifier 'DIM_FX_RATES_FILLED.RATE'"). This is the same constraint documented in DR4 for `active_mrr`. Compound PRIMARY KEY and multi-column RELATIONSHIPS both work (Probes 1 and 2 passed) — the blocker is exclusively the METRICS expression scope.

**Resolution:** `mrr_amount_usd` and `arr_amount_usd` are pre-computed in `fact_subscriptions` at dbt build time via `LEFT JOIN dim_fx_rates_filled ON (currency, billing_month)`. USD rows use `COALESCE(rate, 1.0)` passthrough. Semantic view metrics then use single-table `SUM(fact_subscriptions.mrr_amount_usd)`.

FX conversion was designed as query-time semantic layer logic per DR3 — forced to dbt pre-computation due to Snowflake METRICS clause rejecting cross-table column references. Same resolution pattern as `active_mrr` in Complexity 2. DR3 intent is preserved in documentation; implementation is pragmatically in the mart layer.

**Implication:** If exchange rates are updated in `dim_fx_rates_filled`, `fact_subscriptions` must be re-run to refresh USD amounts. The semantic view does not pick up rate changes automatically.

---
