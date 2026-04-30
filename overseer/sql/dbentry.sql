-- dbentry.sql
-- adding a new event

INSERT INTO events (
    ts_s, ts_ms, pid, ppid, uid, type, comm, arg1
) VALUES (
    %s,
    %s
    %s,
    %s,
    %s,
    %s,
    %s,
    %s,
);
