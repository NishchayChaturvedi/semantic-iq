-- Asserts each of the four orphaned accounts has exactly one row
-- with ancestor_id = 'UNKNOWN' in dim_account_hierarchy.
-- Returns rows for any orphaned account where the count ≠ 1.
-- Test passes when this query returns 0 rows.

WITH expected AS (
    SELECT account_id
    FROM (
        SELECT 'ACC-0026' AS account_id UNION ALL
        SELECT 'ACC-0034'               UNION ALL
        SELECT 'ACC-0048'               UNION ALL
        SELECT 'ACC-0063'
    )
),

actual AS (
    SELECT
        account_id,
        COUNT(*) AS unknown_row_count
    FROM {{ ref('dim_account_hierarchy') }}
    WHERE ancestor_id = 'UNKNOWN'
    GROUP BY account_id
)

SELECT
    e.account_id,
    COALESCE(a.unknown_row_count, 0)    AS unknown_row_count

FROM expected e
LEFT JOIN actual a USING (account_id)
WHERE COALESCE(a.unknown_row_count, 0) != 1
