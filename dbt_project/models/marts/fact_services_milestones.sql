-- Grain: one row per milestone_id (single professional services payment event).
-- No fixed calendar grain — completed_date is irregular.
--
-- account_key resolved at build time using the same ROW_NUMBER strategy as
-- fact_usage_daily: pick the most recent dim_accounts version with
-- valid_from <= completed_date. Unlike usage, a NULL account_key here is a
-- genuine data problem (no plausible post-churn milestone), so the not_null
-- test is a hard assertion, not an edge case to handle gracefully.
--
-- revenue_amount stored in contract_currency — FX conversion in semantic view.

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
    milestone_id,
    account_id,
    account_key,
    project_name,
    milestone_name,
    completed_date,
    revenue_amount,
    currency,
    created_at

FROM milestones_with_dim
WHERE _rn = 1
