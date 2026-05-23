-- processing_getprocs.sql
-- gets information required for "Process Overview"

SELECT
    COUNT(*) AS processes_seen,
    (
        SELECT
            COUNT(*)
        FROM procs
        WHERE fist_seen_ts_s > :min_ts
    ) AS spawns_seen,
    (
        processes_seen - spawns_seen
    ) AS preexisting,
    (
        SELECT
            COUNT(*)
        FROM procs
        WHERE last_seen_ts_s <= :max_ts
    ) AS deaths_seen
FROM procs
WHERE
    first_seen_ts_s >= :min_ts AND
    first_seen_ts_s <= :max_ts;
