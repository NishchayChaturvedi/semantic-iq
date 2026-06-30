{{ config(materialized='view') }}

-- Role-playing alias of dim_date for the subscription created_date role.
-- Registered in saas_revenue_model as dim_date_created PRIMARY KEY (date_day).
-- Relationship: fact_subscriptions (created_date) REFERENCES dim_date_created (date_day).
-- created_date is pre-computed in fact_subscriptions as created_at::date.

SELECT * FROM {{ ref('dim_date') }}
