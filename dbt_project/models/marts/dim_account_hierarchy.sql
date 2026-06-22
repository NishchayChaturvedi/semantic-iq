{{ config(materialized='table') }}

-- Grain: one row per (account_id, ancestor_id) pair.
-- Built from dim_accounts WHERE is_current = TRUE only.
-- Historical hierarchy is not tracked — explicitly documented in ARCHITECTURE.md
-- as linked to the bi-temporal Future Consideration in design.md.
--
-- UNKNOWN sentinel rows added post-CTE for the four accounts whose
-- parent_account_id was deliberately NULLed in the raw data
-- (ACC-0026, ACC-0034, ACC-0048, ACC-0063 — all confirmed L1 band,
--  0-indexed positions 25/33/47/62 in the data generator).
-- These are distinct from true L0 roots (indices 0–19) which have NULL
-- parent by design, not by data quality failure.
--
-- path_string: root-first, leaf-last, slash-delimited (e.g. ACC-0003/ACC-0041/ACC-0099).
-- full_path_string: same complete path, repeated on every row for the same account_id.

WITH RECURSIVE recursive_hierarchy AS (

    -- Anchor: every account is its own ancestor at depth 0
    SELECT
        account_id::VARCHAR             AS account_id,
        account_id::VARCHAR             AS ancestor_id,
        0                               AS depth,
        account_id::VARCHAR             AS path_string,
        parent_account_id::VARCHAR      AS parent_account_id

    FROM {{ ref('dim_accounts') }}
    WHERE is_current = TRUE

    UNION ALL

    -- Step up: parent of the current ancestor becomes the new ancestor
    SELECT
        rh.account_id::VARCHAR,
        ca.account_id::VARCHAR                          AS ancestor_id,
        rh.depth + 1                                    AS depth,
        ca.account_id || '/' || rh.path_string          AS path_string,
        ca.parent_account_id::VARCHAR                   AS parent_account_id

    FROM recursive_hierarchy rh
    JOIN {{ ref('dim_accounts') }} ca
        ON  ca.account_id  = rh.parent_account_id
        AND ca.is_current  = TRUE
    WHERE rh.parent_account_id IS NOT NULL

),

-- True L0 roots: NULL parent AND not one of the four known orphaned accounts.
-- Used to populate is_root correctly in the final output.
true_roots AS (
    SELECT account_id
    FROM {{ ref('dim_accounts') }}
    WHERE is_current        = TRUE
      AND parent_account_id IS NULL
      AND account_id NOT IN ('ACC-0026', 'ACC-0034', 'ACC-0048', 'ACC-0063')
),

-- Synthetic UNKNOWN ancestor rows — one per orphaned account.
-- depth = 1 (UNKNOWN is the missing parent, one level above the orphan's self-row).
-- path_string follows root-first convention: UNKNOWN/<account_id>.
unknown_rows AS (
    SELECT
        t.account_id::VARCHAR           AS account_id,
        'UNKNOWN'::VARCHAR              AS ancestor_id,
        1                               AS depth,
        'UNKNOWN/' || t.account_id      AS path_string,
        NULL::VARCHAR                   AS parent_account_id
    FROM (
        SELECT 'ACC-0026' AS account_id UNION ALL
        SELECT 'ACC-0034'               UNION ALL
        SELECT 'ACC-0048'               UNION ALL
        SELECT 'ACC-0063'
    ) t
),

combined AS (
    SELECT * FROM recursive_hierarchy
    UNION ALL
    SELECT * FROM unknown_rows
)

SELECT
    c.account_id,
    c.ancestor_id,
    c.depth,
    c.account_id = c.ancestor_id                    AS is_self,

    -- is_root: TRUE for UNKNOWN synthetic rows and for rows whose ancestor
    -- is a confirmed L0 root (NULL parent, not in the orphaned set)
    tr.account_id IS NOT NULL
        OR c.ancestor_id = 'UNKNOWN'                AS is_root,

    c.path_string,

    -- Complete root-to-leaf path, repeated on every row for the same account_id.
    -- The deepest ancestor's path_string is the full path — propagate it down.
    FIRST_VALUE(c.path_string) OVER (
        PARTITION BY c.account_id
        ORDER BY c.depth DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    )                                               AS full_path_string

FROM combined c
LEFT JOIN true_roots tr
    ON tr.account_id = c.ancestor_id
