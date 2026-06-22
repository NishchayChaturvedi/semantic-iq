-- Grain: one row per (api_key_id, assigned_at) — light SCD2.
-- NOT unique on api_key_id alone: six keys have two rows each (mid-period reassignment).
-- revoked_at_effective uses 9999-12-31 sentinel for active keys, enabling BETWEEN
-- range joins in fact_usage_daily without COALESCE on every query.

SELECT
    api_key_id,
    api_key_hash,
    account_id,
    assigned_at,
    revoked_at,
    COALESCE(revoked_at, '9999-12-31'::DATE)    AS revoked_at_effective,
    is_active,
    is_reassigned

FROM {{ ref('stg_api_keys') }}
