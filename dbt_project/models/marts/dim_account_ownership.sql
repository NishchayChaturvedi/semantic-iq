-- Grain: one row per (account_id, valid_from) — ownership version.
-- An account has exactly one owner at any point in time.
-- Source of truth for row-level security (rep → region mapping).
-- valid_to_effective uses 9999-12-31 sentinel for current owner rows.
-- Overlap integrity guarded by tests/assert_no_ownership_overlaps.sql.

SELECT
    ownership_id,
    account_id,
    owner_name,
    owner_type,
    region,
    valid_from,
    valid_to,
    COALESCE(valid_to, '9999-12-31'::DATE)      AS valid_to_effective,
    is_current

FROM {{ ref('stg_account_ownership') }}
