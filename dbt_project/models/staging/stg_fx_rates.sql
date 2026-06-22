-- Grain: one row per (rate_date, from_currency, to_currency, rate_type).
-- Three deliberate SPOT gaps: (GBP,2022-08-29), (EUR,2023-03-14), (GBP,2024-01-02).
-- Fallback rule for gaps: use most recent available SPOT rate for that currency.

SELECT
    rate_id                                     AS rate_id,
    TRY_TO_DATE(rate_date)                      AS rate_date,
    from_currency                               AS from_currency,
    to_currency                                 AS to_currency,
    rate_type                                   AS rate_type,
    TRY_TO_DECIMAL(rate, 10, 6)                AS rate,
    TRY_TO_DATE(created_at)                     AS created_at

FROM {{ source('raw', 'fx_rates') }}
