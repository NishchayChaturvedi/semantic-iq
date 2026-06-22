-- Grain: one row per bridge_id (account + product combination).
-- Many-to-many bridge with discount and bundling metadata.

SELECT
    bridge_id                                   AS bridge_id,
    account_id                                  AS account_id,
    product_id                                  AS product_id,
    TRY_TO_DATE(start_date)                     AS start_date,
    TRY_TO_DATE(end_date)                       AS end_date,
    TRY_TO_DECIMAL(discount_pct, 5, 2)          AS discount_pct,
    is_bundled::BOOLEAN                         AS is_bundled,
    TRY_TO_DATE(created_at)                     AS created_at

FROM {{ source('raw', 'account_products') }}
