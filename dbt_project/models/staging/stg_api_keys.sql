-- Grain: one row per (api_key_id, assigned_at).
-- NOT unique on api_key_id alone — six keys have two rows (mid-period reassignment).
-- Account attribution must join on assigned_at/revoked_at window, not api_key_id alone.

SELECT
    api_key_id                                  AS api_key_id,
    api_key_hash                                AS api_key_hash,
    account_id                                  AS account_id,
    TRY_TO_DATE(assigned_at)                    AS assigned_at,
    TRY_TO_DATE(revoked_at)                     AS revoked_at,
    TRY_TO_DATE(revoked_at) IS NULL             AS is_active,
    _reassigned::BOOLEAN                        AS is_reassigned

FROM {{ source('raw', 'api_keys') }}
