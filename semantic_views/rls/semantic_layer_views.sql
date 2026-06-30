-- =============================================================================
-- SEMANTIC_IQ.SEMANTIC_LAYER  ·  Secure Views with Row Access Policy
-- =============================================================================
-- These are transparent pass-through views of the four MARTS fact tables.
-- rap_account_region is attached to each view on the account-grain column.
-- Mart tables (SEMANTIC_IQ.MARTS.*) are left untouched — no policies attached.
--
-- Why this layer exists:
--   Snowflake Semantic Views are metadata objects; ALTER SEMANTIC VIEW ...
--   ADD ROW ACCESS POLICY fails with a syntax error (confirmed by probe —
--   see ARCHITECTURE.md DR9). RAP attachment requires a data object (table or
--   view), not a metadata object. These secure views are the enforcement point.
--
-- The saas_revenue_model Semantic View references SEMANTIC_LAYER fact tables
-- instead of MARTS fact tables. Dimension tables (DIM_ACCOUNTS, DIM_DATE_*)
-- remain referenced from MARTS — they are not row-filtered.
--
-- Demo roles and users (active until Sigma showcase is complete):
--   SEMANTIC_IQ_EMEA_ROLE  / SEMANTIC_IQ_EMEA_REP   → EMEA region, 50 accounts
--   SEMANTIC_IQ_GLOBAL_ROLE / SEMANTIC_IQ_FINANCE     → all accounts (bypass)
--   TO DROP AFTER SHOWCASE:
--     DROP USER SEMANTIC_IQ_EMEA_REP;
--     DROP USER SEMANTIC_IQ_FINANCE;
--     DROP ROLE SEMANTIC_IQ_EMEA_ROLE;
--     DROP ROLE SEMANTIC_IQ_GLOBAL_ROLE;
--
-- Role→region mapping fixture:
--   INSERT INTO SEMANTIC_IQ.MARTS.RAP_ROLE_REGION_MAP VALUES ('SEMANTIC_IQ_EMEA_ROLE', 'EMEA');
--   (Add one row per regional role to extend to other regions)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS SEMANTIC_IQ.SEMANTIC_LAYER;

-- fact_subscriptions: RLS on account_id (subscription billing grain)
CREATE OR REPLACE SECURE VIEW SEMANTIC_IQ.SEMANTIC_LAYER.FACT_SUBSCRIPTIONS AS
  SELECT * FROM SEMANTIC_IQ.MARTS.FACT_SUBSCRIPTIONS;

ALTER VIEW SEMANTIC_IQ.SEMANTIC_LAYER.FACT_SUBSCRIPTIONS
  ADD ROW ACCESS POLICY SEMANTIC_IQ.MARTS.rap_account_region ON (account_id);

-- fact_services_milestones: RLS on account_id (milestone event grain)
CREATE OR REPLACE SECURE VIEW SEMANTIC_IQ.SEMANTIC_LAYER.FACT_SERVICES_MILESTONES AS
  SELECT * FROM SEMANTIC_IQ.MARTS.FACT_SERVICES_MILESTONES;

ALTER VIEW SEMANTIC_IQ.SEMANTIC_LAYER.FACT_SERVICES_MILESTONES
  ADD ROW ACCESS POLICY SEMANTIC_IQ.MARTS.rap_account_region ON (account_id);

-- fact_usage_daily: RLS on account_id (API-key + day grain)
CREATE OR REPLACE SECURE VIEW SEMANTIC_IQ.SEMANTIC_LAYER.FACT_USAGE_DAILY AS
  SELECT * FROM SEMANTIC_IQ.MARTS.FACT_USAGE_DAILY;

ALTER VIEW SEMANTIC_IQ.SEMANTIC_LAYER.FACT_USAGE_DAILY
  ADD ROW ACCESS POLICY SEMANTIC_IQ.MARTS.rap_account_region ON (account_id);

-- fact_hierarchy_rollup: RLS on ancestor_id (ancestor account_id values share
-- the same domain as account_id — same RAP function applies)
CREATE OR REPLACE SECURE VIEW SEMANTIC_IQ.SEMANTIC_LAYER.FACT_HIERARCHY_ROLLUP AS
  SELECT * FROM SEMANTIC_IQ.MARTS.FACT_HIERARCHY_ROLLUP;

ALTER VIEW SEMANTIC_IQ.SEMANTIC_LAYER.FACT_HIERARCHY_ROLLUP
  ADD ROW ACCESS POLICY SEMANTIC_IQ.MARTS.rap_account_region ON (ancestor_id);
