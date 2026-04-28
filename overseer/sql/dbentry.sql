-- dbentry.sql
-- adding a new event

INSERT INTO events (
    pid, ppid, uid, type, comm, arg1
) VALUES (
    %s,
    %s,
    %s,
    %s,
    %s,
    %s,
);
