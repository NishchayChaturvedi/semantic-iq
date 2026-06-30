{{ config(materialized='view') }}

-- Role-playing alias of dim_date for the billing_month date role.
-- Registered in saas_revenue_model as dim_date_billing PRIMARY KEY (date_day).
-- Relationship: fact_subscriptions (billing_month) REFERENCES dim_date_billing (date_day).
-- Required because Snowflake Semantic View TABLES clause derives alias from object name
-- and rejects duplicate aliases — the same physical table cannot be registered twice.

SELECT * FROM {{ ref('dim_date') }}
