-- Grain: one row per (account_id, product_id, effective_from).
--
-- Many-to-many bridge with time-range attributes.
-- account_key is intentionally NOT resolved here. A product assignment can span
-- multiple SCD2 versions of an account; resolving to one account_key at build
-- time would require picking a version arbitrarily. Fact queries align this
-- bridge with dim_accounts at query time using the event date, not the bridge range.
--
-- effective_to_effective uses 9999-12-31 sentinel for active assignments.
-- discount_pct and is_bundled are relationship-level attributes (not on either dim).

SELECT
    bridge_id,
    account_id,
    product_id,
    start_date                                      AS effective_from,
    end_date                                        AS effective_to,
    COALESCE(end_date, '9999-12-31'::DATE)          AS effective_to_effective,
    end_date IS NULL                                AS is_active,
    discount_pct,
    is_bundled

FROM {{ ref('stg_account_products') }}
