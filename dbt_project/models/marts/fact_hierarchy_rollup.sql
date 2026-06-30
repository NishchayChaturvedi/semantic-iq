-- Grain: one row per (ancestor_id, billing_month).
--
-- Pre-computes hierarchy-aware MRR/ARR rollup by joining fact_subscriptions to
-- dim_account_hierarchy on account_id, aggregating so that each ancestor's row
-- includes revenue from all subsidiary accounts below it in the org tree.
--
-- Why pre-computed here instead of in the semantic view:
--   dim_account_hierarchy is a fan-out bridge (one row per account+ancestor pair).
--   Snowflake Semantic View RELATIONSHIPS requires the dimension side to be unique
--   on the join key — dim_account_hierarchy.account_id is NOT unique (292 rows,
--   134 accounts). Registering it as a dim-side table would either fail DDL
--   validation or silently inflate all flat subscription metrics.
--   Pre-aggregating here resolves the fan-out in dbt; the semantic view sees a
--   clean fact at (ancestor_id, billing_month) grain (see ARCHITECTURE.md DR8).
--
-- subsidiary_count semi-additivity:
--   COUNT(DISTINCT account_id) is computed per billing_month snapshot.
--   It is NOT additive across months — summing subsidiary_count over a date range
--   overcounts accounts that appear in multiple months. Read at a single
--   billing_month, or use MIN/MAX. Same governance pattern as distinct_account_count
--   in fact_subscriptions (ARCHITECTURE.md DR4).

WITH subscriptions AS (
    SELECT * FROM {{ ref('fact_subscriptions') }}
),

hierarchy AS (
    SELECT * FROM {{ ref('dim_account_hierarchy') }}
),

-- Self-rows carry the ancestor's own position in the tree.
-- UNKNOWN is a synthetic placeholder (no self-row exists); treated as a root-level
-- sentinel with NULL depth to signal "position unknown" rather than forcing depth=0.
ancestor_attrs AS (
    SELECT
        account_id   AS ancestor_id,
        depth        AS ancestor_depth,
        is_root      AS is_root_ancestor
    FROM hierarchy
    WHERE is_self = TRUE

    UNION ALL

    SELECT 'UNKNOWN', NULL, TRUE
),

rollup_agg AS (
    SELECT
        h.ancestor_id,
        f.billing_month,
        SUM(f.mrr_amount)            AS mrr_amount_with_subs,
        SUM(f.mrr_amount_usd)        AS mrr_amount_usd_with_subs,
        SUM(f.arr_amount)            AS arr_amount_with_subs,
        SUM(f.arr_amount_usd)        AS arr_amount_usd_with_subs,
        COUNT(DISTINCT f.account_id) AS subsidiary_count

    FROM hierarchy h
    JOIN subscriptions f
        ON f.account_id = h.account_id

    GROUP BY h.ancestor_id, f.billing_month
)

SELECT
    r.ancestor_id,
    r.billing_month,
    r.mrr_amount_with_subs,
    r.mrr_amount_usd_with_subs,
    r.arr_amount_with_subs,
    r.arr_amount_usd_with_subs,
    r.subsidiary_count,
    a.ancestor_depth,
    a.is_root_ancestor

FROM rollup_agg r
LEFT JOIN ancestor_attrs a
    ON a.ancestor_id = r.ancestor_id
