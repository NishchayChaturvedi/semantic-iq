-- Grain: one row per account_key (SCD2 surrogate).
-- Natural key: account_id (stable across versions).
--
-- Join patterns:
--   Point-in-time ("as-reported"):
--     ON fact.account_id = dim.account_id
--        AND fact.event_date BETWEEN dim.valid_from AND dim.valid_to_effective
--
--   Current state:
--     ON fact.account_id = dim.account_id
--        AND dim.is_current = TRUE
--
-- parent_account_id is NULL for both true root accounts and the four accounts
-- with deliberately missing parents (ACC-0025/0033/0047/0062). The Unknown
-- member strategy for hierarchy rollup lives in the semantic view layer.

SELECT
    account_key,
    account_id,
    account_name,
    segment,
    industry,
    parent_account_id,
    contract_currency,
    valid_from,
    valid_to,
    COALESCE(valid_to, '9999-12-31'::DATE)      AS valid_to_effective,
    is_current,
    source_updated_at,
    loaded_at,
    loaded_at > source_updated_at               AS is_backdated

FROM {{ ref('stg_accounts') }}
