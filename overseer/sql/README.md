# `overseer/sql/` - An Overview

Every 'session' the Overseer has (it starts a new one every startup) gets its
own database file in the format of `{uuid}-{salt}-{UNIX timestamp}`. They all
are initialized and used the same way, and the SQL code is separated into files
that the Overseer reads before database initialization. The session database is
created lazily on the first successful Underseer `system_info` handshake so the
overview row can be populated from the remote host metadata.

IN THIS DIR
---

 - `newdb.sql` - Initializes the database
 - `evententry.sql` - Inserts events
 - `procentry.sql` - Inserts and updates process lifecycle rows

##### TODO
