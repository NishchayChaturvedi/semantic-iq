# SemanticIQ — Design Document
### A Governed Semantic Architecture Showcase
**Stack:** dbt + Snowflake Semantic Views + Sigma
**Author:** Nishchay Chaturvedi
**Status:** Locked — build phase begins from this document

---

## 1. Purpose & Positioning

SemanticIQ is not a BI demo. It is a deliberate stress test of semantic layer architecture against seven named, real-world modeling failure modes that break naive implementations at most enterprise companies.

This project demonstrates the ability to architect the **governed semantic foundation** that any BI tool (Sigma) or AI consumption layer (Cortex Analyst) sits on top of — distinct from, and complementary to, GenAI/agent-focused projects elsewhere in the portfolio.

**Core thesis demonstrated:** One governed metric definition, multiple consumers, correct under real-world complexity — not just a working dashboard.

---

## 2. The Business: "Meridian"

A fictional B2B platform company with three revenue lines, deliberately chosen because no single line can be modeled correctly using a naive single-grain, single-currency, flat-hierarchy approach.

| Revenue Line | Billing Pattern | Currency | Grain |
|---|---|---|---|
| Subscription (core product + add-ons) | Monthly/annual recurring | Multi-currency (USD/GBP/EUR) | Account + Product + Month |
| Professional Services | Milestone-based | USD only | Event (irregular) |
| Marketplace/Usage | Daily metered consumption | Multi-currency, billed monthly | API Key + Day |

One account can participate in all three lines simultaneously and can have multiple products under subscription (many-to-many).

**Real-world precedent:** This blended subscription + consumption + services model mirrors how companies like Snowflake itself structure revenue (platform consumption credits + professional services + multi-product subscriptions) — the modeling challenges are representative of real enterprise SaaS, not contrived.

---

## 3. Data Authenticity Statement

This dataset is **synthetically generated, by design** — not an attempt to simulate a real company's actual transactions. The goal is to deliberately surface seven known, hard semantic modeling problems with sufficient volume and realistic messiness to prove the architecture handles them correctly, including their failure modes.

To avoid the "too clean to be credible" trap, the generator deliberately injects:
- Out-of-order / backdated SCD2 change events (a segment correction logged 2 days after the fact)
- NULL `parent_account_id` on accounts that logically should have a parent (tests "Unknown" hierarchy handling)
- 5–10 API keys reassigned between accounts mid-period (stresses the conformance join)
- 2–3 FX rate gaps — a currency/date with no published spot rate (forces an explicit fallback rule)
- Genuinely uneven hierarchy depth (some branches 1 level, some 4 levels — not designed to be tidy)

---

## 4. The Seven Complexities (Locked Scope)

1. **SCD Type 2 + historical metric recalculation**
2. **Non-additive & semi-additive metrics**
3. **Role-playing dimensions + many-to-many relationships**
4. **Ragged / variable-depth hierarchies**
5. **Multi-grain fact integration + non-conformed dimension grain** (extended scope: API-key-level usage vs. account-level subscriptions)
6. **Multi-currency conversion timing** (contract rate vs. spot rate)
7. **Row-level security / multi-tenant governance** — fully implemented and demonstrated live in Sigma (two-login proof), not just documented

### Future Considerations (named, explicitly out of scope)
- **CDC-based ingestion** — SCD2 is built from pre-constructed rows in this project, not derived from a simulated raw change-event stream. A production implementation would likely build `dim_accounts` from a CDC feed (e.g., Fivetran/Debezium-style insert/update/delete events with source + load timestamps), requiring explicit out-of-order event handling.
- **Late-arriving facts** — no "as-reported vs. as-corrected" distinction is implemented for facts that land after a period has already been reported.
- **Metric definition versioning** — no mechanism for retroactively tracking changes to a metric's *definition* (e.g., NRR formula changes) separate from changes to the underlying data.
- **Bi-temporal modeling** — this project implements single-axis SCD2 (valid_from/valid_to) only, not a second "as-known" temporal axis for backdated corrections.
- **Null/unknown member handling beyond hierarchy** — explicit "Unknown" handling is implemented for the ragged hierarchy; not extended to every dimension.

---

## 5. Entity List

### Dimensions
| Entity | Grain | SCD Type | Notes |
|---|---|---|---|
| `dim_accounts` | One row per account per change version | SCD2 | Includes `parent_account_id` for ragged hierarchy; pre-built SCD2 rows (not CDC-derived) |
| `dim_date` | One row per calendar day | Type 1 (static) | Single physical table; 3 role-playing semantic roles (signup/billing/churn) |
| `dim_products` | One row per product | Type 1 (static) | Joins via bridge for M:M |
| `dim_api_keys` | One row per key per assignment period | Light SCD2 | Keys reassigned between accounts mid-period (messiness) |
| `dim_fx_rates` | One row per currency + date + rate_type | Type 1 (static) | Two rate types: `contract_rate`, `spot_rate`; intentional gaps |
| `dim_account_ownership` | One row per account + owner + effective period | SCD2 | Drives row-level security (rep/region) |

### Bridge
| Entity | Purpose |
|---|---|
| `bridge_account_products` | Many-to-many between accounts and products; carries allocation logic for shared/bundled discounts |

### Facts
| Entity | Grain | Notes |
|---|---|---|
| `fact_subscriptions` | Account + Product + Month | Multi-product, multi-currency, monthly recurring |
| `fact_usage_daily` | API Key + Day | Finest grain; rolls up to account only via explicit aggregation (conformance problem) |
| `fact_services_milestones` | Milestone (irregular event) | No fixed calendar grain; tied to project completion |

### Security
| Entity | Purpose |
|---|---|
| Row access policy on Semantic View | Filters via `dim_account_ownership`; enforced live in Sigma via two distinct trial user logins (regional manager vs. finance/global view) |

---

## 6. Metric Additivity Classification

Every metric in the semantic view is explicitly tagged by additivity type — this classification itself is a deliverable, documented in `semantic_views/metric_additivity_reference.md`:

| Type | Definition | Example Metrics |
|---|---|---|
| **Additive** | Safe to SUM across any dimension | `mrr`, `usage_units`, `milestone_revenue` |
| **Semi-additive** | Safe to SUM across some dimensions (e.g., accounts) but NOT across time | `active_account_balance` (snapshot-style) |
| **Non-additive** | Must be calculated at the correct grain first, never pre-aggregated and summed | `nrr`, `churn_rate`, `nps_score` |

---

## 7. Decision Records (to be detailed in ARCHITECTURE.md during build)

1. **SCD2 Strategy** — Type 2 chosen over Type 1/Type 4 hybrid; semantic view exposes both point-in-time and current-state paths for the same metric (e.g., `nrr_as_reported` vs. `nrr_current_view`)
2. **Multi-Grain Fact Integration** — grain-aware semantic relationships chosen over forcing a common grain in dbt; tradeoff is query complexity vs. modeling flexibility
3. **Metric Additivity Classification** — explicit tagging framework; failure mode demonstrated (naive SUM vs. correct weighted calculation side by side in Sigma)
4. **Role-Playing Dimensions & M:M Handling** — one physical `dim_date`, three semantic roles; FX conversion decision: handled in the semantic layer at query time, not pre-converted in dbt
5. **Ragged Hierarchy Handling** — recursive rollup logic (dbt `WITH RECURSIVE` or Snowflake-native hierarchy functions); explicit "Unknown" member strategy for NULL `parent_account_id`
6. **Multi-Currency Conversion Timing** — `contract_rate` (locked at signing) vs. `spot_rate` (daily) as two distinct, explicitly-chosen metric variants; fallback rule defined for FX gap dates
7. **Row-Level Security** — row access policy design on the Semantic View; live two-login proof in Sigma

---

## 8. Architecture Layers

```
Layer 1 — Raw Synthetic Data (Python + Faker)
  → accounts (pre-built SCD2 rows, incl. messiness),
    subscriptions, usage_events (daily, api_key grain),
    services_milestones, fx_rates (dual rate type),
    products, account_products (bridge), account_ownership
  → Snowflake RAW schema

Layer 2 — dbt Staging
  → Clean, typed, deduplicated models
  → Explicit grain documentation per model (dbt model contracts + tests)

Layer 3 — dbt Marts (Dimensional)
  → dim_accounts (SCD2), dim_date, dim_products, dim_api_keys,
    dim_fx_rates, dim_account_ownership,
    bridge_account_products,
    fact_subscriptions, fact_usage_daily, fact_services_milestones

Layer 4 — Snowflake Semantic Views
  → saas_revenue_model (primary semantic view)
    - role-playing date dimension (3 named roles)
    - multi-grain fact relationships explicitly defined
    - metrics tagged by additivity type
    - SCD2-aware historical vs. current dimension paths
    - multi-currency conversion logic embedded in metric definitions
    - ragged hierarchy rollup logic
  → Row access policy applied at this layer

Layer 5 — Sigma (single workbook, multiple pages)
  → One page per complexity (or paired where they share data)
  → Two-login row-level security proof
  → Naive-vs-correct metric comparison page

Layer 6 — Cortex Analyst (stretch goal)
  → Same semantic view powering natural language queries
  → Proves one governed model, two consumption modes (Sigma + Cortex)
```

---

## 9. Deliverables

1. **Working system** — Snowflake (data + dbt + semantic views + RLS) + one Sigma workbook, fully clickable/demoable
2. **`design.md`** (this document) — locked before build
3. **`ARCHITECTURE.md`** — full decision record with tradeoffs, written during build, not after
4. **`metric_additivity_reference.md`** — explicit metric classification table
5. **GitHub repo** — `semantic-iq`, public, professional README
6. **LinkedIn post** — with visual proof: two-login RLS screenshots side by side, one naive-vs-correct metric example, simplified architecture diagram

---

## 10. GitHub Repo Structure

```
semantic-iq/
  ├── README.md
  ├── design.md
  ├── ARCHITECTURE.md
  ├── architecture/
  │     └── semantic_model_diagram.mmd
  ├── data/
  │     ├── generate_data.py       (includes messiness injection)
  │     └── load_to_snowflake.py
  ├── dbt_project/
  │     ├── models/staging/
  │     ├── models/marts/
  │     └── tests/                  (grain + additivity assertions)
  ├── semantic_views/
  │     ├── saas_revenue_model.sql
  │     └── metric_additivity_reference.md
  ├── sigma/
  │     └── screenshots + workbook notes
  ├── cortex_analyst/                (stretch)
  │     └── semantic_model.yaml
  ├── .env.example
  └── requirements.txt
```

---

## 11. Build Order

| Step | What | Deliverable Checkpoint |
|---|---|---|
| 1 | Generate synthetic data (incl. messiness injection) → load to Snowflake | Tables visible in RAW schema |
| 2 | dbt staging + dimensional marts, with grain tests | `dbt test` passing |
| 3 | Build Snowflake Semantic View incrementally, one complexity at a time | Each complexity query-validated in Snowflake before moving to Sigma |
| 4 | Sigma trial setup, connect to Semantic View | Connection confirmed |
| 5 | Build single Sigma workbook, page by page per complexity | Screenshot each page as it's completed |
| 6 | Implement + test row-level security with two logins | **Capture two-login screenshots before moving on** |
| 7 | Write `ARCHITECTURE.md` alongside the build | Updated per decision record as each is implemented |
| 8 | (Stretch) Cortex Analyst on same semantic view | NL query demo working |
| 9 | README + LinkedIn post assembly | Final polish |

---

*This document is the locked reference for the build phase. Any scope change during build should be reflected back here, not silently drifted from.*
