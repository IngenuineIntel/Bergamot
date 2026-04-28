-- newdb.sql
-- script for starting a new database

CREATE TABLE metadata (
    db_name TEXT,
    db_time TEXT,
    overseer_ver TEXT
);

INSERT INTO metadata (
    db_name, db_time, overseer_ver
) VALUES (
    %s, %s, %s
);

CREATE TABLE events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER DEFAULT (unixepoch()), -- UNIX time
    pid INTEGER, -- PID
    ppid INTEGER, -- PPID
    uid INTEGER, -- UID
    type TEXT, -- syscall in question
    comm TEXT, -- process command
    arg1 TEXT, -- syscall argument (usually *rdi)
    -- No other implementation of the protocol has `arg2` - but one
    -- day they might
    arg2 TEXT -- syscall argument (usually *rsi)
);
