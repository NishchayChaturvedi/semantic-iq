-- Grain: one row per product_id (static, no versioning).

SELECT
    product_id                                  AS product_id,
    TRIM(product_name)                          AS product_name,
    product_type                                AS product_type,
    TRY_TO_NUMBER(base_mrr_usd)                AS base_mrr_usd,
    TRY_TO_DATE(created_at)                     AS created_at

FROM {{ source('raw', 'products') }}
