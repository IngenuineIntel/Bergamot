-- gets information reuqires for an overview of all the processes seen within a
-- Bergamot database

-- TODO make this work

SELECT
    (
        SELECT
            COUNT(*)
        FROM procs
        WHERE first_seen_ts_s >= (SELECT MIN(first_seen_ts_s) FROM procs)
            AND first_seen_ts_s <= (SELECT MAX(first_seen_ts_s) FROM procs)
    ) AS processes_seen
  , (
        SELECT
            COUNT(*)
        FROM procs
        WHERE first_seen_ts_s > (SELECT MIN(first_seen_ts_s) FROM procs)
            AND first_seen_ts_s <= (SELECT MAX(first_seen_ts_s) FROM procs)
    ) AS spawns_seen
  , processes_seen - spawn_seen AS preexisting
  , (
        SELECT
            COUNT(*)
        FROM procs
        WHERE last_seen_ts_s >= (SELECT MIN(first_seen_ts_s) FROM procs)
            AND last_seen_ts_s <= (SELECT MAX(first_seen_ts_s) FROM procs)
    ) AS deaths_seen
FROM procs;