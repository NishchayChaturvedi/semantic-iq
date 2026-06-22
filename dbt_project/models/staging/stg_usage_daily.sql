-- Grain: one row per usage_id (api_key_id + usage_date).
-- account_id here reflects which account held the key on usage_date —
-- not the current account. Critical for correct conformance join to subscriptions.

SELECT
    usage_id                                    AS usage_id,
    api_key_id                                  AS api_key_id,
    account_id                                  AS account_id,
    TRY_TO_DATE(usage_date)                     AS usage_date,
    TRY_TO_DECIMAL(units_consumed, 12, 4)       AS units_consumed,
    TRY_TO_DECIMAL(unit_rate, 10, 5)            AS unit_rate,
    currency                                    AS currency,
    TRY_TO_DATE(created_at)                     AS created_at

FROM {{ source('raw', 'usage_daily') }}
