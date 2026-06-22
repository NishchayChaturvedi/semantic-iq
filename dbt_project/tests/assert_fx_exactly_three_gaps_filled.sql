-- Asserts exactly 3 rows in dim_fx_rates_filled have is_gap_filled = TRUE,
-- corresponding to the three known missing rate dates in the source data:
--   GBP 2022-08-29, EUR 2023-03-14, GBP 2024-01-02.
-- Returns a row if the count deviates — test passes when this returns 0 rows.

SELECT
    COUNT(*)                    AS gap_filled_count,
    3                           AS expected_count

FROM {{ ref('dim_fx_rates_filled') }}
WHERE is_gap_filled = TRUE

HAVING COUNT(*) != 3
