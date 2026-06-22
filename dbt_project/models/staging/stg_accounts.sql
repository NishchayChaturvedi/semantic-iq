-- Grain: one row per account_key (SCD2 surrogate).
-- Point-in-time: WHERE valid_from <= :date AND (valid_to >= :date OR valid_to IS NULL)
-- Current state:  WHERE is_current = TRUE

SELECT
    account_key::INTEGER                        AS account_key,
    account_id                                  AS account_id,
    TRIM(account_name)                          AS account_name,
    segment                                     AS segment,
    industry                                    AS industry,
    NULLIF(TRIM(parent_account_id), '')         AS parent_account_id,
    contract_currency                           AS contract_currency,
    TRY_TO_DATE(valid_from)                     AS valid_from,
    TRY_TO_DATE(valid_to)                       AS valid_to,
    TRY_TO_DATE(valid_to) IS NULL               AS is_current,
    TRY_TO_DATE(_source_updated_at)             AS source_updated_at,
    TRY_TO_DATE(_loaded_at)                     AS loaded_at

FROM {{ source('raw', 'accounts') }}
