-- =============================================================================
-- saas_revenue_model  ·  Snowflake Semantic View
-- =============================================================================
-- Complexity 1 (LIVE): SCD2 dual-path dimension
--   dim_accounts      (190 rows, all versions) → segment as-reported at billing time
--   dim_accounts_current (150 rows, is_current=TRUE) → segment_current as of today
--
-- Complexity 2 (LIVE): Full metric taxonomy + billing_month dimension
--   Additive:       total_mrr, total_arr, subscription_count
--   Semi-additive:  distinct_account_count (see ARCHITECTURE.md DR4)
--   NRR component:  active_mrr (pre-computed is_active_account — see DR4)
--
-- Complexity 3 (LIVE): Role-playing date dimensions
--   dim_date_billing   → billing_month  (subscription billing calendar)
--   dim_date_created   → created_date   (subscription creation calendar)
--   dim_date_milestone → completed_date (milestone completion calendar)
--   dim_date_usage     → usage_date     (API usage calendar)
--   Same physical table (dim_date) cannot appear in TABLES twice — duplicate alias error.
--   Four separate dbt views required (see ARCHITECTURE.md DR6).
--   created_date pre-computed in fact_subscriptions as created_at::DATE.
--
-- Complexity 7 (LIVE): Row-level security
--   RAP rap_account_region attached to four secure views in SEMANTIC_IQ.SEMANTIC_LAYER.
--   Mart tables (SEMANTIC_IQ.MARTS.*) remain open — no policies attached.
--   Secure views are transparent pass-throughs; the SV references them instead of marts.
--   Probe confirmed: ALTER SEMANTIC VIEW ... ADD ROW ACCESS POLICY is unsupported
--   (syntax error — SV is a metadata object, not a data object). See ARCHITECTURE.md DR9.
--   Enforcement: CURRENT_ROLE() → rap_role_region_map → dim_account_ownership region join.
--   Safe-fail: role absent from mapping → zero rows (not all rows).
--   SYSTEM$GET_USER_CONTEXT unavailable on this account; role-based mapping used instead.
--
-- Complexity 4 (LIVE): Ragged hierarchy rollup
--   fact_hierarchy_rollup: (ancestor_id, billing_month) grain (4,778 rows)
--   Pre-computes fact_subscriptions × dim_account_hierarchy fan-out in dbt.
--   dim_account_hierarchy cannot be the dim-side of a SV RELATIONSHIP — non-unique
--   account_id PK (292 rows / 134 accounts). Solution: rollup fact with clean grain.
--   ancestor_id → dim_accounts_current for segment/industry of parent account.
--   ancestor_id → dim_date_billing reuse confirmed: dual-reference probe passed.
--   subsidiary_count semi-additive: read at single billing_month (see ARCHITECTURE.md DR8).
--
-- Complexity 5 (LIVE): Multi-grain fact integration
--   fact_services_milestones: milestone grain (107 rows, irregular dates)
--   fact_usage_daily:         API-key + day grain (45,995 rows)
--   Non-conformance: usage_date is daily; billing_month is monthly. Shared
--   dim_accounts join works (both resolve account_key at build time) but
--   temporal misalignment is a governance constraint, not a query-time guard.
--   dim_date_usage kept distinct from dim_date_billing so Sigma exposes the
--   two time axes as separate choices — making the grain mismatch visible.
--
-- Complexity 6 (LIVE): Multi-currency USD normalisation
--   mrr_amount_usd / arr_amount_usd pre-computed in mart (see ARCHITECTURE.md DR5)
--   Metrics: total_mrr_usd, total_arr_usd, active_mrr_usd
--   revenue_amount_usd, daily_amount_usd added for milestone + usage facts (same pattern)
--
-- Syntax rules (confirmed against Snowflake 10.21.x):
--   TABLES:        fully qualified name + PRIMARY KEY (col[, col]) — compound PK works;
--                  same physical table twice → "duplicate alias" error
--   DIMENSIONS:    table.column AS table.alias — alias must be real column in source
--   METRICS:       table.metric_name AS agg_expr — single-table expressions only
--   RELATIONSHIPS: supports multi-column (col1, col2) REFERENCES (col1, col2)
--   Not directly queryable via standard SQL — consumed by Cortex Analyst / Sigma
-- =============================================================================

CREATE OR REPLACE SEMANTIC VIEW SEMANTIC_IQ.MARTS.saas_revenue_model

  TABLES (
    SEMANTIC_IQ.SEMANTIC_LAYER.FACT_SUBSCRIPTIONS,
    SEMANTIC_IQ.SEMANTIC_LAYER.FACT_SERVICES_MILESTONES,
    SEMANTIC_IQ.SEMANTIC_LAYER.FACT_USAGE_DAILY,
    SEMANTIC_IQ.SEMANTIC_LAYER.FACT_HIERARCHY_ROLLUP,
    SEMANTIC_IQ.MARTS.DIM_ACCOUNTS          PRIMARY KEY (account_key),
    SEMANTIC_IQ.MARTS.DIM_ACCOUNTS_CURRENT  PRIMARY KEY (account_id),
    SEMANTIC_IQ.MARTS.DIM_DATE_BILLING      PRIMARY KEY (date_day),
    SEMANTIC_IQ.MARTS.DIM_DATE_CREATED      PRIMARY KEY (date_day),
    SEMANTIC_IQ.MARTS.DIM_DATE_MILESTONE    PRIMARY KEY (date_day),
    SEMANTIC_IQ.MARTS.DIM_DATE_USAGE        PRIMARY KEY (date_day)
  )

  RELATIONSHIPS (
    -- fact_subscriptions
    fact_subscriptions (account_key)   REFERENCES dim_accounts (account_key),
    fact_subscriptions (account_id)    REFERENCES dim_accounts_current (account_id),
    fact_subscriptions (billing_month) REFERENCES dim_date_billing (date_day),
    fact_subscriptions (created_date)  REFERENCES dim_date_created (date_day),

    -- fact_services_milestones
    fact_services_milestones (account_key)    REFERENCES dim_accounts (account_key),
    fact_services_milestones (completed_date) REFERENCES dim_date_milestone (date_day),

    -- fact_usage_daily
    fact_usage_daily (account_key) REFERENCES dim_accounts (account_key),
    fact_usage_daily (usage_date)  REFERENCES dim_date_usage (date_day),

    -- fact_hierarchy_rollup
    fact_hierarchy_rollup (ancestor_id)    REFERENCES dim_accounts_current (account_id),
    fact_hierarchy_rollup (billing_month)  REFERENCES dim_date_billing (date_day)
  )

  DIMENSIONS (
    -- Fact grain / join keys exposed as dimensions
    fact_subscriptions.billing_month AS fact_subscriptions.billing_month,
    fact_subscriptions.created_date  AS fact_subscriptions.created_date,

    -- SCD2 as-reported path: attributes at billing time
    dim_accounts.account_id         AS dim_accounts.account_id,
    dim_accounts.account_name       AS dim_accounts.account_name,
    dim_accounts.segment            AS dim_accounts.segment,
    dim_accounts.industry           AS dim_accounts.industry,
    dim_accounts.contract_currency  AS dim_accounts.contract_currency,
    dim_accounts.parent_account_id  AS dim_accounts.parent_account_id,
    dim_accounts.valid_from         AS dim_accounts.valid_from,
    dim_accounts.valid_to_effective AS dim_accounts.valid_to_effective,
    dim_accounts.is_current         AS dim_accounts.is_current,
    dim_accounts.is_backdated       AS dim_accounts.is_backdated,

    -- Current-view path: today's account state
    dim_accounts_current.segment_current           AS dim_accounts_current.segment_current,
    dim_accounts_current.industry_current          AS dim_accounts_current.industry_current,
    dim_accounts_current.contract_currency_current AS dim_accounts_current.contract_currency_current,

    -- Billing date role (subscription billing calendar)
    dim_date_billing.date_day    AS dim_date_billing.date_day,
    dim_date_billing.year        AS dim_date_billing.year,
    dim_date_billing.quarter     AS dim_date_billing.quarter,
    dim_date_billing.month       AS dim_date_billing.month,
    dim_date_billing.month_name  AS dim_date_billing.month_name,
    dim_date_billing.year_month  AS dim_date_billing.year_month,
    dim_date_billing.is_weekend  AS dim_date_billing.is_weekend,

    -- Created date role (subscription creation calendar)
    dim_date_created.date_day    AS dim_date_created.date_day,
    dim_date_created.year        AS dim_date_created.year,
    dim_date_created.quarter     AS dim_date_created.quarter,
    dim_date_created.month       AS dim_date_created.month,
    dim_date_created.month_name  AS dim_date_created.month_name,
    dim_date_created.year_month  AS dim_date_created.year_month,
    dim_date_created.is_weekend  AS dim_date_created.is_weekend,

    -- Milestone date role (services milestone completion calendar)
    dim_date_milestone.date_day    AS dim_date_milestone.date_day,
    dim_date_milestone.year        AS dim_date_milestone.year,
    dim_date_milestone.quarter     AS dim_date_milestone.quarter,
    dim_date_milestone.month       AS dim_date_milestone.month,
    dim_date_milestone.month_name  AS dim_date_milestone.month_name,
    dim_date_milestone.year_month  AS dim_date_milestone.year_month,
    dim_date_milestone.is_weekend  AS dim_date_milestone.is_weekend,

    -- Usage date role (API usage calendar — distinct from billing to surface grain mismatch)
    dim_date_usage.date_day    AS dim_date_usage.date_day,
    dim_date_usage.year        AS dim_date_usage.year,
    dim_date_usage.quarter     AS dim_date_usage.quarter,
    dim_date_usage.month       AS dim_date_usage.month,
    dim_date_usage.month_name  AS dim_date_usage.month_name,
    dim_date_usage.year_month  AS dim_date_usage.year_month,
    dim_date_usage.is_weekend  AS dim_date_usage.is_weekend,

    -- Services milestones grain attributes
    fact_services_milestones.milestone_id   AS fact_services_milestones.milestone_id,
    fact_services_milestones.completed_date AS fact_services_milestones.completed_date,
    fact_services_milestones.project_name   AS fact_services_milestones.project_name,
    fact_services_milestones.milestone_name AS fact_services_milestones.milestone_name,

    -- Usage daily grain attributes (api_key_id: non-conformed sub-account grain)
    fact_usage_daily.usage_id      AS fact_usage_daily.usage_id,
    fact_usage_daily.api_key_id    AS fact_usage_daily.api_key_id,
    fact_usage_daily.usage_date    AS fact_usage_daily.usage_date,
    fact_usage_daily.is_reassigned AS fact_usage_daily.is_reassigned,

    -- Hierarchy rollup grain attributes (Complexity 4)
    fact_hierarchy_rollup.ancestor_id      AS fact_hierarchy_rollup.ancestor_id,
    fact_hierarchy_rollup.billing_month    AS fact_hierarchy_rollup.billing_month,
    fact_hierarchy_rollup.ancestor_depth   AS fact_hierarchy_rollup.ancestor_depth,
    fact_hierarchy_rollup.is_root_ancestor AS fact_hierarchy_rollup.is_root_ancestor
  )

  METRICS (
    -- Contract-currency metrics (Complexity 2)
    fact_subscriptions.total_mrr              AS SUM(fact_subscriptions.mrr_amount),
    fact_subscriptions.total_arr              AS SUM(fact_subscriptions.arr_amount),
    fact_subscriptions.subscription_count     AS COUNT(fact_subscriptions.subscription_id),
    -- Semi-additive: do not sum across billing_month (see ARCHITECTURE.md DR4)
    fact_subscriptions.distinct_account_count AS COUNT(DISTINCT fact_subscriptions.account_id),
    -- NRR numerator component; ratio assembled in Sigma
    fact_subscriptions.active_mrr
      AS SUM(CASE WHEN fact_subscriptions.is_active_account
                  THEN fact_subscriptions.mrr_amount ELSE 0 END),

    -- USD-normalised metrics (Complexity 6)
    fact_subscriptions.total_mrr_usd          AS SUM(fact_subscriptions.mrr_amount_usd),
    fact_subscriptions.total_arr_usd          AS SUM(fact_subscriptions.arr_amount_usd),
    fact_subscriptions.active_mrr_usd
      AS SUM(CASE WHEN fact_subscriptions.is_active_account
                  THEN fact_subscriptions.mrr_amount_usd ELSE 0 END),

    -- Services milestones metrics (Complexity 5)
    fact_services_milestones.total_services_revenue
      AS SUM(fact_services_milestones.revenue_amount),
    fact_services_milestones.total_services_revenue_usd
      AS SUM(fact_services_milestones.revenue_amount_usd),
    fact_services_milestones.milestone_count
      AS COUNT(fact_services_milestones.milestone_id),

    -- Usage daily metrics (Complexity 5)
    fact_usage_daily.total_units_consumed
      AS SUM(fact_usage_daily.units_consumed),
    fact_usage_daily.total_usage_revenue
      AS SUM(fact_usage_daily.daily_amount),
    fact_usage_daily.total_usage_revenue_usd
      AS SUM(fact_usage_daily.daily_amount_usd),

    -- Hierarchy rollup metrics (Complexity 4)
    -- Semi-additive: subsidiary_count should not be summed across billing_month (see DR8)
    fact_hierarchy_rollup.total_mrr_with_subs
      AS SUM(fact_hierarchy_rollup.mrr_amount_with_subs),
    fact_hierarchy_rollup.total_mrr_usd_with_subs
      AS SUM(fact_hierarchy_rollup.mrr_amount_usd_with_subs),
    fact_hierarchy_rollup.total_arr_with_subs
      AS SUM(fact_hierarchy_rollup.arr_amount_with_subs),
    fact_hierarchy_rollup.total_arr_usd_with_subs
      AS SUM(fact_hierarchy_rollup.arr_amount_usd_with_subs)
  )

;
