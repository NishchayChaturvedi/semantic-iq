-- Grain: one row per (currency, rate_date) — daily SPOT rate to USD.
-- Filters to SPOT + to_currency=USD only; CONTRACT rates live in staging for audit.
-- No USD row (1.0 is implicit; USD facts need no lookup).
-- Three deliberate gaps preserved as-is — FX interpolation/NULL strategy
-- is the semantic view's responsibility, not the mart's.

SELECT
    from_currency                               AS currency,
    rate_date,
    rate

FROM {{ ref('stg_fx_rates') }}
WHERE to_currency = 'USD'
  AND rate_type   = 'SPOT'
