-- Grain: one row per (currency, rate_date) — identical to dim_fx_rates but
-- with the three known gap dates forward-filled using the prior day's SPOT rate.
--
-- Gap dates: GBP 2022-08-29, EUR 2023-03-14, GBP 2024-01-02.
-- Fill strategy: LAST_VALUE(rate IGNORE NULLS) over date-ordered window — takes
-- the most recent published rate for that currency before the gap date.
--
-- This does NOT perform FX conversion. It is a data quality correction:
-- the rate exists in the real world on gap dates; it simply wasn't captured.
-- Conversion (amount * rate) lives exclusively in saas_revenue_model metric
-- definitions — consistent with Decision Record 6 in ARCHITECTURE.md.
--
-- is_gap_filled = TRUE flags the three synthetic rows for audit visibility.

WITH date_currency_spine AS (
    SELECT
        d.date_day,
        c.currency
    FROM {{ ref('dim_date') }} d
    CROSS JOIN (
        SELECT 'GBP' AS currency UNION ALL
        SELECT 'EUR'
    ) c
    WHERE d.date_day BETWEEN '2022-01-01' AND '2024-12-31'
),

joined AS (
    SELECT
        s.date_day,
        s.currency,
        f.rate
    FROM date_currency_spine s
    LEFT JOIN {{ ref('dim_fx_rates') }} f
        ON  f.currency  = s.currency
        AND f.rate_date = s.date_day
),

filled AS (
    SELECT
        date_day,
        currency,
        rate,
        LAST_VALUE(rate IGNORE NULLS) OVER (
            PARTITION BY currency
            ORDER BY date_day
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                               AS rate_filled
    FROM joined
)

SELECT
    date_day                            AS rate_date,
    currency,
    COALESCE(rate, rate_filled)         AS rate,
    rate IS NULL                        AS is_gap_filled

FROM filled
WHERE rate_filled IS NOT NULL           -- exclude dates before any rate exists for that currency
