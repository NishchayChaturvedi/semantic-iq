{{ config(materialized='view') }}

-- Role-playing alias of dim_date for the usage_date role.
-- Registered in saas_revenue_model as dim_date_usage PRIMARY KEY (date_day).
-- Relationship: fact_usage_daily (usage_date) REFERENCES dim_date_usage (date_day).
-- Kept distinct from dim_date_billing so Sigma exposes billing month and usage date
-- as separate time axes — surfacing the grain mismatch (Complexity 5 showcase).

SELECT * FROM {{ ref('dim_date') }}
