-- Asserts no overlapping ownership date ranges for the same account_id.
-- An overlap would silently assign the same account to two reps simultaneously,
-- breaking RLS joins and double-counting revenue in per-rep reports.
-- Returns one row per overlapping pair — test passes only when this returns 0 rows.

WITH ownership AS (
    SELECT
        account_id,
        ownership_id,
        valid_from,
        COALESCE(valid_to, '9999-12-31'::DATE)  AS valid_to_effective
    FROM {{ ref('dim_account_ownership') }}
)

SELECT
    a.account_id,
    a.ownership_id                              AS ownership_a,
    b.ownership_id                              AS ownership_b,
    a.valid_from                                AS a_valid_from,
    a.valid_to_effective                        AS a_valid_to,
    b.valid_from                                AS b_valid_from,
    b.valid_to_effective                        AS b_valid_to

FROM ownership a
JOIN ownership b
    ON  a.account_id        = b.account_id
    AND a.ownership_id      < b.ownership_id        -- avoid self-match and duplicate pairs
    AND b.valid_from        < a.valid_to_effective  -- b starts before a ends → overlap
    AND a.valid_from        < b.valid_to_effective  -- a starts before b ends → overlap
