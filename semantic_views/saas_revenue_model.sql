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
-- Complexity 3 (LIVE): Multi-currency USD normalisation
--   mrr_amount_usd / arr_amount_usd pre-computed in mart (see ARCHITECTURE.md DR5)
--   Metrics: total_mrr_usd, total_arr_usd, active_mrr_usd
--
-- Complexity 4 (LIVE): Role-playing date dimensions
--   dim_date_billing → billing_month (subscription billing calendar)
--   dim_date_created → created_date  (subscription creation calendar)
--   dim_date_milestone → completed_date (activated in Complexity 7 with fact_services_milestones)
--   Same physical table (dim_date) cannot appear in TABLES twice — duplicate alias error.
--   Three separate dbt views required (see ARCHITECTURE.md DR6).
--   created_date pre-computed in fact_subscriptions as created_at::DATE.
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
    SEMANTIC_IQ.MARTS.FACT_SUBSCRIPTIONS,
    SEMANTIC_IQ.MARTS.DIM_ACCOUNTS          PRIMARY KEY (account_key),
    SEMANTIC_IQ.MARTS.DIM_ACCOUNTS_CURRENT  PRIMARY KEY (account_id),
    SEMANTIC_IQ.MARTS.DIM_DATE_BILLING      PRIMARY KEY (date_day),
    SEMANTIC_IQ.MARTS.DIM_DATE_CREATED      PRIMARY KEY (date_day)
  )

  RELATIONSHIPS (
    fact_subscriptions (account_key)   REFERENCES dim_accounts (account_key),
    fact_subscriptions (account_id)    REFERENCES dim_accounts_current (account_id),
    fact_subscriptions (billing_month) REFERENCES dim_date_billing (date_day),
    fact_subscriptions (created_date)  REFERENCES dim_date_created (date_day)
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
    dim_date_created.is_weekend  AS dim_date_created.is_weekend
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

    -- USD-normalised metrics (Complexity 3)
    fact_subscriptions.total_mrr_usd          AS SUM(fact_subscriptions.mrr_amount_usd),
    fact_subscriptions.total_arr_usd          AS SUM(fact_subscriptions.arr_amount_usd),
    fact_subscriptions.active_mrr_usd
      AS SUM(CASE WHEN fact_subscriptions.is_active_account
                  THEN fact_subscriptions.mrr_amount_usd ELSE 0 END)
  )

;
