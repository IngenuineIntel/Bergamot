-- gets information required for an overview of the processes within a specific
-- timestamp

-- TODO make this work

SELECT
    (
        SELECT
            COUNT(*)
        FROM procs
        WHERE first_seen_ts_s >= :min_ts
            AND first_seen_ts_s <= :max_ts
    ) AS processes_seen
  , (
        SELECT
            COUNT(*)
        FROM procs
        WHERE first_seen_ts_s > :min_ts
            AND first_seen_ts_s <= :max_ts
    ) AS spawns_seen
  , processes_seen - spawn_seen AS preexisting
  , (
        SELECT
            COUNT(*)
        FROM procs
        WHERE last_seen_ts_s >= :min_ts
            AND last_seen_ts_s <= :max_ts
    ) AS deaths_seen
FROM procs;
