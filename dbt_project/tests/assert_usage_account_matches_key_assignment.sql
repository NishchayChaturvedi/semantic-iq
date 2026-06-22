-- Asserts that the account_id stamped on stg_usage_daily matches the account_id
-- from the stg_api_keys assignment window active on that usage_date.
--
-- This test guards the conformance join: if anyone naively joins usage to api_keys
-- on api_key_id alone (ignoring the date window), reassigned keys return two rows
-- and the account attribution is wrong. This test catches that regression.
--
-- Returns rows on failure; 0 rows = pass.

WITH usage_with_key_account AS (

    SELECT
        u.usage_id,
        u.api_key_id,
        u.usage_date,
        u.account_id                                AS usage_account_id,
        k.account_id                                AS key_account_id

    FROM {{ ref('stg_usage_daily') }} u

    LEFT JOIN {{ ref('stg_api_keys') }} k
        ON  u.api_key_id = k.api_key_id
        AND u.usage_date BETWEEN k.assigned_at
                             AND COALESCE(k.revoked_at, '9999-12-31'::DATE)

)

SELECT *
FROM usage_with_key_account
WHERE usage_account_id != key_account_id
   OR key_account_id IS NULL
