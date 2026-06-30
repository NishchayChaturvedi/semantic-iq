{{ config(materialized='view') }}

-- Role-playing alias of dim_date for the completed_date role.
-- Registered in saas_revenue_model as dim_date_milestone PRIMARY KEY (date_day).
-- Relationship: fact_services_milestones (completed_date) REFERENCES dim_date_milestone (date_day).
-- Activated in Complexity 5 (multi-grain fact integration) alongside fact_services_milestones.

SELECT * FROM {{ ref('dim_date') }}
