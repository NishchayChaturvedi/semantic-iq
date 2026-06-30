# saas_revenue_model — Metric Additivity Reference

Classification of all 18 METRICS defined in `saas_revenue_model` plus `subsidiary_count`,
a dimension column with semi-additive governance identical in kind to `distinct_account_count`.

**Definitions used:**
- **Additive** — SUM is correct across every dimension (account, segment, product, date, region, etc.)
- **Semi-additive** — SUM is correct across some dimensions but not others; specific unsafe axis documented per metric
- **Non-additive** — SUM across multiple anchor values produces double-counted results regardless of dimension; always filter to a single anchor before aggregating

---

## fact_subscriptions (8 metrics)

| Metric | Additivity | Expression |
|---|---|---|
| `total_mrr` | Additive | `SUM(mrr_amount)` |
| `total_arr` | Additive | `SUM(arr_amount)` |
| `total_mrr_usd` | Additive | `SUM(mrr_amount_usd)` |
| `total_arr_usd` | Additive | `SUM(arr_amount_usd)` |
| `active_mrr` | Additive | `SUM(mrr_amount) WHERE is_active_account` |
| `active_mrr_usd` | Additive | `SUM(mrr_amount_usd) WHERE is_active_account` |
| `subscription_count` | Additive | `COUNT(subscription_id)` |
| `distinct_account_count` | **Semi-additive** | `COUNT(DISTINCT account_id)` |

**`distinct_account_count` caveat:** Additive over segments, products, and regions. Not summable over `billing_month` — an account appearing in multiple months is counted once per month, overcounting unique accounts across a date range. Governance detail in **DR4**.

---

## fact_services_milestones (3 metrics)

| Metric | Additivity | Expression |
|---|---|---|
| `total_services_revenue` | Additive | `SUM(revenue_amount)` |
| `total_services_revenue_usd` | Additive | `SUM(revenue_amount_usd)` |
| `milestone_count` | Additive | `COUNT(milestone_id)` |

---

## fact_usage_daily (3 metrics)

| Metric | Additivity | Expression |
|---|---|---|
| `total_units_consumed` | Additive | `SUM(units_consumed)` |
| `total_usage_revenue` | Additive | `SUM(daily_amount)` |
| `total_usage_revenue_usd` | Additive | `SUM(daily_amount_usd)` |

---

## fact_hierarchy_rollup (4 metrics)

| Metric | Additivity | Expression |
|---|---|---|
| `total_mrr_with_subs` | **Non-additive** | `SUM(mrr_amount_with_subs)` |
| `total_arr_with_subs` | **Non-additive** | `SUM(arr_amount_with_subs)` |
| `total_mrr_usd_with_subs` | **Non-additive** | `SUM(mrr_amount_usd_with_subs)` |
| `total_arr_usd_with_subs` | **Non-additive** | `SUM(arr_amount_usd_with_subs)` |

**Hierarchy rollup caveat:** Each row in `fact_hierarchy_rollup` represents the pre-aggregated MRR for all subsidiaries beneath a given `ancestor_id`. Ancestor nodes in the same hierarchy overlap — a parent's value includes all of its children's values. Summing across multiple `ancestor_id` values double- (or triple-, quadruple-) counts subsidiary revenue proportional to each account's depth in the tree. Always filter to a single `ancestor_id` before reading these metrics. To get total company MRR via the hierarchy path, filter to `is_root_ancestor = TRUE`.

---

## fact_hierarchy_rollup — dimension column with semi-additive governance

`subsidiary_count` is a DIMENSION column in the semantic view (not a METRIC), but carries the same semi-additive constraint as `distinct_account_count`.

| Column | Additivity | Expression |
|---|---|---|
| `subsidiary_count` | **Semi-additive** | `COUNT(DISTINCT account_id)` per `(ancestor_id, billing_month)` |

**`subsidiary_count` caveat:** Computed once per `billing_month` snapshot. Summing `subsidiary_count` across months overcounts accounts that appear in multiple billing periods. Read at a single `billing_month` or use `MAX`. Governance detail in **DR8**.

---

## Summary counts

| Additivity | Count | Metrics |
|---|---|---|
| Additive | 13 | total_mrr, total_arr, total_mrr_usd, total_arr_usd, active_mrr, active_mrr_usd, subscription_count, total_services_revenue, total_services_revenue_usd, milestone_count, total_units_consumed, total_usage_revenue, total_usage_revenue_usd |
| Semi-additive | 1 (+1 dim col) | distinct_account_count (+ subsidiary_count dimension column) |
| Non-additive | 4 | total_mrr_with_subs, total_arr_with_subs, total_mrr_usd_with_subs, total_arr_usd_with_subs |
