-- Grain: one row per product_id (static, no versioning).

SELECT
    product_id,
    product_name,
    product_type,
    base_mrr_usd,
    created_at

FROM {{ ref('stg_products') }}
