-- Grain: one row per milestone_id (single professional services payment event).
-- No fixed calendar grain — completed_date is irregular.
--
-- account_key resolved at build time using the same ROW_NUMBER strategy as
-- fact_usage_daily: pick the most recent dim_accounts version with
-- valid_from <= completed_date. Unlike usage, a NULL account_key here is a
-- genuine data problem (no plausible post-churn milestone), so the not_null
-- test is a hard assertion, not an edge case to handle gracefully.
--
-- revenue_amount stored in contract_currency; revenue_amount_usd pre-computed via
-- LEFT JOIN to dim_fx_rates_filled (same pattern as fact_subscriptions — Snowflake
-- Semantic View METRICS clause rejects cross-table column references, see ARCHITECTURE.md DR5).

WITH milestones AS (
    SELECT * FROM {{ ref('stg_services_milestones') }}
),

dim AS (
    SELECT * FROM {{ ref('dim_accounts') }}
),

milestones_with_dim AS (
    SELECT
        m.milestone_id,
        m.account_id,
        m.project_name,
        m.milestone_name,
        m.completed_date,
        m.revenue_amount,
        m.currency,
        m.created_at,
        d.account_key,
        ROW_NUMBER() OVER (
            PARTITION BY m.milestone_id
            ORDER BY d.valid_from DESC
        )                                           AS _rn

    FROM milestones m
    LEFT JOIN dim d
        ON  m.account_id  = d.account_id
        AND d.valid_from <= m.completed_date
)

SELECT
    mwd.milestone_id,
    mwd.account_id,
    mwd.account_key,
    mwd.project_name,
    mwd.milestone_name,
    mwd.completed_date,
    mwd.revenue_amount,
    mwd.revenue_amount * COALESCE(fx.rate, 1.0)  AS revenue_amount_usd,
    mwd.currency,
    mwd.created_at

FROM milestones_with_dim mwd

LEFT JOIN {{ ref('dim_fx_rates_filled') }} fx
    ON  mwd.currency       = fx.currency
    AND mwd.completed_date = fx.rate_date

WHERE mwd._rn = 1
