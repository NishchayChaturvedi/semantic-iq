-- Grain: one row per subscription_id (account_id + product_id + billing_month).
--
-- account_key is the SCD2 surrogate resolved at build time: whichever dim_accounts
-- version was active during billing_month. This locks in the historical segment,
-- enabling the nrr_as_reported vs nrr_current_view comparison in the semantic view:
--   as-reported:   JOIN dim_accounts ON fact.account_key = dim.account_key
--   current view:  JOIN dim_accounts ON fact.account_id = dim.account_id AND dim.is_current
--
-- mrr_amount is stored in contract_currency — no FX conversion here.
-- FX conversion to USD is done in the semantic view at query time via dim_fx_rates.

SELECT
    s.subscription_id,
    s.account_id,
    d.account_key,
    s.product_id,
    s.billing_month,
    s.mrr_amount,
    s.mrr_amount * 12                        AS arr_amount,
    s.mrr_amount * COALESCE(fx.rate, 1.0)    AS mrr_amount_usd,
    s.mrr_amount * 12 * COALESCE(fx.rate, 1.0) AS arr_amount_usd,
    s.currency,
    s.billing_type,
    s.status,
    s.created_at,
    c.account_id IS NOT NULL                 AS is_active_account

FROM {{ ref('stg_subscriptions') }} s

LEFT JOIN {{ ref('dim_accounts') }} d
    ON  s.account_id    = d.account_id
    AND s.billing_month BETWEEN d.valid_from AND d.valid_to_effective

LEFT JOIN {{ ref('dim_accounts_current') }} c
    ON  s.account_id    = c.account_id

LEFT JOIN {{ ref('dim_fx_rates_filled') }} fx
    ON  s.currency      = fx.currency
    AND s.billing_month = fx.rate_date
