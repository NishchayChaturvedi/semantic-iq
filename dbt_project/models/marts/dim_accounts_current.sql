{{ config(materialized='view') }}

-- Filtered snapshot of dim_accounts for current account versions only.
-- Grain: one row per account_id (150 rows, no historical versions).
-- Columns shared with dim_accounts get _current suffix so the semantic view
-- can expose both SCD2 paths with distinct, non-ambiguous names.

SELECT
    account_key,
    account_id,
    account_name,
    parent_account_id,
    segment           AS segment_current,
    industry          AS industry_current,
    contract_currency AS contract_currency_current,
    valid_from,
    valid_to_effective,
    is_current,
    is_backdated,
    loaded_at
FROM {{ ref('dim_accounts') }}
WHERE is_current = TRUE
