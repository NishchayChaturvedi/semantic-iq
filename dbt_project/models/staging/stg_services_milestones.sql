-- Grain: one row per milestone_id.
-- No fixed calendar grain — milestones complete on irregular dates.
-- Joins to accounts via account_id (use current or point-in-time SCD2 version).

SELECT
    milestone_id                                AS milestone_id,
    account_id                                  AS account_id,
    TRIM(project_name)                          AS project_name,
    TRIM(milestone_name)                        AS milestone_name,
    TRY_TO_DATE(completed_date)                 AS completed_date,
    TRY_TO_DECIMAL(revenue_amount, 12, 2)       AS revenue_amount,
    currency                                    AS currency,
    TRY_TO_DATE(created_at)                     AS created_at

FROM {{ source('raw', 'services_milestones') }}
