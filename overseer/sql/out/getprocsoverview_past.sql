-- gets information required for "Process Overview"

SELECT
    COUNT(*) AS processes_seen,
    (
        SELECT
            COUNT(*)
        FROM procs
        WHERE first_seen_ts_s > :min_ts
          AND first_seen_ts_s <= :max_ts
    ) AS spawns_seen,
    (
        COUNT(*) - (
            SELECT COUNT(*)
            FROM procs
            WHERE first_seen_ts_s > :min_ts
              AND first_seen_ts_s <= :max_ts
        )
    ) AS preexisting,
    (
        SELECT
            COUNT(*)
        FROM procs
        WHERE last_seen_ts_s >= :min_ts
          AND last_seen_ts_s <= :max_ts
    ) AS deaths_seen
FROM procs
WHERE
    first_seen_ts_s >= :min_ts AND
    first_seen_ts_s <= :max_ts;
