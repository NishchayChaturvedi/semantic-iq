-- Grain: one row per (account_id, product_id, billing_month).
-- MRR stored in account's contract_currency — convert to USD in the mart layer
-- using dim_fx_rates with CONTRACT rate type.

SELECT
    subscription_id                             AS subscription_id,
    account_id                                  AS account_id,
    product_id                                  AS product_id,
    TRY_TO_DATE(billing_month)                  AS billing_month,
    TRY_TO_DECIMAL(mrr_amount, 12, 2)           AS mrr_amount,
    currency                                    AS currency,
    billing_type                                AS billing_type,
    status                                      AS status,
    TRY_TO_DATE(created_at)                     AS created_at

FROM {{ source('raw', 'subscriptions') }}
