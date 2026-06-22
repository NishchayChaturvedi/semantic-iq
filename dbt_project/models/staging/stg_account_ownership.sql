-- Grain: one row per ownership_id (SCD2).
-- Source of truth for row-level security (rep → region mapping).

SELECT
    ownership_id                                AS ownership_id,
    account_id                                  AS account_id,
    TRIM(owner_name)                            AS owner_name,
    owner_type                                  AS owner_type,
    region                                      AS region,
    TRY_TO_DATE(valid_from)                     AS valid_from,
    TRY_TO_DATE(valid_to)                       AS valid_to,
    TRY_TO_DATE(valid_to) IS NULL               AS is_current

FROM {{ source('raw', 'account_ownership') }}
