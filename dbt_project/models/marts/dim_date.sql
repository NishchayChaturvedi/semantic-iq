-- Grain: one row per calendar day, 2021-01-01 through 2025-12-31.
-- Buffer extends one year on each side of the Jan 2022–Dec 2024 data range
-- so role-playing date joins never fall off the edge of the calendar.
-- Used three times in saas_revenue_model with distinct aliases:
--   billing_date  → fact_subscriptions.billing_month
--   completion_date → fact_services_milestones.completed_date
--   created_date  → fact_subscriptions.created_at

WITH spine AS (
    {{ dbt_utils.date_spine(
        datepart   = "day",
        start_date = "cast('2021-01-01' as date)",
        end_date   = "cast('2026-01-01' as date)"
    ) }}
)

SELECT
    date_day,

    -- Year / quarter / month
    YEAR(date_day)                                          AS year,
    QUARTER(date_day)                                       AS quarter,
    'Q' || QUARTER(date_day)::VARCHAR                       AS quarter_name,
    YEAR(date_day)::VARCHAR || '-Q' || QUARTER(date_day)::VARCHAR
                                                            AS year_quarter,
    MONTH(date_day)                                         AS month,
    MONTHNAME(date_day)                                     AS month_name,
    LEFT(MONTHNAME(date_day), 3)                            AS month_short,
    YEAR(date_day)::VARCHAR || '-' || LPAD(MONTH(date_day)::VARCHAR, 2, '0')
                                                            AS year_month,

    -- Week / day
    WEEKOFYEAR(date_day)                                    AS week_of_year,
    DAYOFWEEK(date_day)                                     AS day_of_week,   -- 0=Sun
    DAYNAME(date_day)                                       AS day_name,
    DAYOFMONTH(date_day)                                    AS day_of_month,

    -- Flags
    DAYOFWEEK(date_day) IN (0, 6)                          AS is_weekend,
    DAYOFWEEK(date_day) NOT IN (0, 6)                      AS is_weekday,

    -- Period anchors (useful for range filters in Sigma)
    DATE_TRUNC('month',   date_day)::DATE                   AS first_day_of_month,
    LAST_DAY(date_day,    'month')::DATE                    AS last_day_of_month,
    DATE_TRUNC('quarter', date_day)::DATE                   AS first_day_of_quarter,
    DATE_TRUNC('year',    date_day)::DATE                   AS first_day_of_year

FROM spine
