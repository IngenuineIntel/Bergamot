# `overseer/sql/` - An Overview

Every 'session' the Overseer has (it starts a new one every startup) gets its
own database file in the format of `{uuid}-{salt}-{UNIX timestamp}`. They all
are initialized and used the same way, and the SQL code is separated into files
that the Overseer reads at startup before database initialization. The reason
for separating information into sessions is for a history mechanism to be
implemented later for reanalysis.

IN THIS DIR
---

 - `newdb.sql` - Initializes the database
 - `dbentry.sql` - Inserts events

##### TODO
