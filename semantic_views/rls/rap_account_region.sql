-- =============================================================================
-- rap_account_region  ·  Row Access Policy
-- =============================================================================
-- Filters rows in SEMANTIC_LAYER fact views by the session role's assigned region.
-- Applied to FACT_SUBSCRIPTIONS, FACT_SERVICES_MILESTONES, FACT_USAGE_DAILY (on
-- account_id) and FACT_HIERARCHY_ROLLUP (on ancestor_id).
--
-- Enforcement logic:
--   1. Finance/global bypass: CURRENT_ROLE() IN (...) → TRUE for all rows
--   2. Regional rep: join CURRENT_ROLE() to rap_role_region_map to find the
--      rep's assigned region, then EXISTS match against dim_account_ownership
--   3. Implicit safe-fail: any role absent from the mapping AND not in the bypass
--      list returns FALSE → zero rows (not all rows)
--
-- SYSTEM$GET_USER_CONTEXT is unavailable on this Snowflake account version.
-- Role-based mapping (rap_role_region_map) is used instead — no per-session
-- context setup required; region is determined automatically at login.
--
-- The RAP function runs under owner (definer) rights — SYSADMIN can query
-- dim_account_ownership regardless of the session user's role grants.
-- See ARCHITECTURE.md DR9.
-- =============================================================================

CREATE OR REPLACE ROW ACCESS POLICY SEMANTIC_IQ.MARTS.rap_account_region
  AS (p_account_id VARCHAR) RETURNS BOOLEAN ->

  -- Finance/global bypass: role-based, automatic on login
  CURRENT_ROLE() IN ('SEMANTIC_IQ_GLOBAL_ROLE', 'SYSADMIN', 'ACCOUNTADMIN')

  OR

  -- Regional rep: look up CURRENT_ROLE() in the mapping table, then filter to
  -- accounts owned by someone in that region (current ownership only)
  EXISTS (
      SELECT 1
      FROM SEMANTIC_IQ.MARTS.DIM_ACCOUNT_OWNERSHIP o
      JOIN SEMANTIC_IQ.MARTS.RAP_ROLE_REGION_MAP m
          ON  m.region        = o.region
          AND m.snowflake_role = CURRENT_ROLE()
      WHERE o.account_id  = p_account_id
        AND o.is_current  = TRUE
  )
;
