-- =============================================================================
-- saas_revenue_model  ·  Snowflake Semantic View
-- =============================================================================
-- Complexity 1 (LIVE): SCD2 dual-path dimension
--   dim_accounts      (190 rows, all versions) → segment as-reported at billing time
--   dim_accounts_current (150 rows, is_current=TRUE) → segment_current as of today
--
-- Complexity 2 (LIVE): Full metric taxonomy + billing_month dimension
--   Additive:       total_mrr, total_arr, subscription_count
--   Semi-additive:  distinct_account_count (COUNT DISTINCT — see ARCHITECTURE.md DR4
--                   for NON ADDITIVE BY limitation and overcounting failure mode)
--   NRR component:  active_mrr (pre-computed is_active_account flag in mart — see DR4)
--
-- Complexity 3 (LIVE): Multi-currency USD normalisation
--   mrr_amount_usd / arr_amount_usd pre-computed in fact_subscriptions at dbt build
--   time via LEFT JOIN to dim_fx_rates_filled. Cross-table multiplication rejected in
--   METRICS clause (see ARCHITECTURE.md DR5). Metrics: total_mrr_usd, total_arr_usd,
--   active_mrr_usd.
--
-- Syntax rules (confirmed against Snowflake 10.21.x):
--   TABLES:        fully qualified name + PRIMARY KEY (col[, col])  — compound PK works
--   DIMENSIONS:    table.column AS table.alias  — alias must be real column in source
--   METRICS:       table.metric_name AS agg_expr  — single-table expressions only;
--                  cross-table column refs and NON ADDITIVE BY both unsupported
--   RELATIONSHIPS: supports multi-column (col1, col2) REFERENCES (col1, col2)
--   Not directly queryable via standard SQL — consumed by Cortex Analyst / Sigma
-- =============================================================================

CREATE OR REPLACE SEMANTIC VIEW SEMANTIC_IQ.MARTS.saas_revenue_model

  TABLES (
    SEMANTIC_IQ.MARTS.FACT_SUBSCRIPTIONS,
    SEMANTIC_IQ.MARTS.DIM_ACCOUNTS          PRIMARY KEY (account_key),
    SEMANTIC_IQ.MARTS.DIM_ACCOUNTS_CURRENT  PRIMARY KEY (account_id)
  )

  RELATIONSHIPS (
    fact_subscriptions (account_key) REFERENCES dim_accounts (account_key),
    fact_subscriptions (account_id)  REFERENCES dim_accounts_current (account_id)
  )

  DIMENSIONS (
    -- Fact grain dimension (enables time-sliced metric queries)
    fact_subscriptions.billing_month AS fact_subscriptions.billing_month,

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
    -- _current suffix columns defined directly in dim_accounts_current mart view
    dim_accounts_current.segment_current           AS dim_accounts_current.segment_current,
    dim_accounts_current.industry_current          AS dim_accounts_current.industry_current,
    dim_accounts_current.contract_currency_current AS dim_accounts_current.contract_currency_current
  )

  METRICS (
    -- Contract-currency metrics (Complexity 2)
    fact_subscriptions.total_mrr              AS SUM(fact_subscriptions.mrr_amount),
    fact_subscriptions.total_arr              AS SUM(fact_subscriptions.arr_amount),
    fact_subscriptions.subscription_count     AS COUNT(fact_subscriptions.subscription_id),
    -- Semi-additive: do not sum distinct_account_count across billing_month (see DR4)
    fact_subscriptions.distinct_account_count AS COUNT(DISTINCT fact_subscriptions.account_id),
    -- NRR numerator component; ratio assembled in Sigma
    fact_subscriptions.active_mrr
      AS SUM(CASE WHEN fact_subscriptions.is_active_account
                  THEN fact_subscriptions.mrr_amount ELSE 0 END),

    -- USD-normalised metrics (Complexity 3)
    -- mrr_amount_usd / arr_amount_usd pre-computed in mart via dim_fx_rates_filled JOIN
    -- (cross-table multiplication unsupported in METRICS clause — see ARCHITECTURE.md DR5)
    fact_subscriptions.total_mrr_usd          AS SUM(fact_subscriptions.mrr_amount_usd),
    fact_subscriptions.total_arr_usd          AS SUM(fact_subscriptions.arr_amount_usd),
    fact_subscriptions.active_mrr_usd
      AS SUM(CASE WHEN fact_subscriptions.is_active_account
                  THEN fact_subscriptions.mrr_amount_usd ELSE 0 END)
  )

;
