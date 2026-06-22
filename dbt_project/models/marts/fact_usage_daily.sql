-- Grain: one row per usage_id (api_key_id + usage_date).
--
-- Non-conformed grain: usage is at API-key + day; subscriptions are at account + month.
-- account_id reflects the account that held the key on usage_date (not current assignment).
-- Conformance integrity guarded by tests/assert_usage_account_matches_key_assignment.sql.
--
-- dim_accounts join strategy:
--   We use ROW_NUMBER() on valid_from DESC rather than BETWEEN valid_from AND valid_to_effective.
--   Reason: some API keys are not revoked at account churn time, producing usage rows that
--   post-date the account's valid_to_effective. The BETWEEN join would leave those rows with
--   NULL account_key. Instead we pick the most recent dim version with valid_from <= usage_date,
--   attributing post-churn usage to the account's last known segment — the correct semantic choice.

WITH usage AS (
    SELECT * FROM {{ ref('stg_usage_daily') }}
),

api_keys AS (
    SELECT * FROM {{ ref('stg_api_keys') }}
),

dim AS (
    SELECT * FROM {{ ref('dim_accounts') }}
),

-- For each usage row, pick the most recent dim_accounts version
-- whose valid_from is on or before usage_date.
usage_with_dim AS (
    SELECT
        u.usage_id,
        u.api_key_id,
        u.account_id,
        u.usage_date,
        u.units_consumed,
        u.unit_rate,
        u.currency,
        u.created_at,
        d.account_key,
        ROW_NUMBER() OVER (
            PARTITION BY u.usage_id
            ORDER BY d.valid_from DESC
        )                                           AS _rn

    FROM usage u
    LEFT JOIN dim d
        ON  u.account_id  = d.account_id
        AND d.valid_from <= u.usage_date
)

SELECT
    ud.usage_id,
    ud.api_key_id,
    ud.account_id,
    ud.account_key,
    ud.usage_date,
    ud.units_consumed,
    ud.unit_rate,
    ud.units_consumed * ud.unit_rate            AS daily_amount,
    ud.currency,
    k.is_reassigned,
    ud.created_at

FROM usage_with_dim ud

LEFT JOIN api_keys k
    ON  ud.api_key_id = k.api_key_id
    AND ud.usage_date BETWEEN k.assigned_at
                          AND COALESCE(k.revoked_at, '9999-12-31'::DATE)

WHERE ud._rn = 1
