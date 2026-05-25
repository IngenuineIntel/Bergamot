# CONTRIBUTIONS

## Table of Contents
- [Overview](#overview)
- [Implementation Procedure](#implementation-procedure)
- [Navigating The Code](#navigating-the-code)
    - [The Engine](#the-engine)
    - [The Agent](#the-agent)
    - [The Overseer](#the-overseer)
- [Code Formatting](#code-formatting)
    - [Universal](#universal)
    - [Python/Cython](#pythoncython)
    - [C](#c)
    - [JavaScript](#javascript)
    - [HTML](#html)
    - [CSS](#css)
    - [SQL](#sql)

## Overview

Contribution is welcome. Blah Blah Blah **TODO**.

## Implementation Procedure

Feature requests, bugs, etc. are ideally brought to light via opening an issue.
Pull requests for notable changes need to have an issue associated with them
first. Smaller pull requests (suppressing a compiler warning, etc.) do not need
this. Blah Blah Blah **TODO**.

## Navigating The Code

Here's a rundown of every program, its functionality, and its source files, in
order of data flow

### The Engine

The Engine is a Linux kernel module, nothing more. It registers KProbe hooks
into various syscalls, and syscall return values. It also registers a procfile,
`/proc/begamot-pipe`, through whom it exfiltrates data. The Engine keeps a ring
buffer in kernel memory of the events it captures, and upon the procfile being
read, the information is dumped and the buffer cleared.

Only one program can read from the file, and it's whichever program tries. In
order for another program to read the file after another program's read it, the
module has to be reloaded. Perhaps in the future this will be a little more
graceful, but this has all the security necessary for the program to function
correctly.

Note that:

- If the reading program doesn't get information from the file often
enough, the ring buffer will overflow and data will be lost silently.
- If another program tries to read the file, it gets a permission error, but
the file is still visible.
- If the lease for the procfile is open, but if EUID != 0, the lease will not
be given and a permission error will be shown

#### Files

- `engine.c`: procfile logic, syscall hooks, entry point
- `hooks.c`: internal hook logic
- `engine.h`: data types used by both `engine.c` and `hooks.c`
- `switches.h`: compile-time options in the form of macros

### The Agent

The Agent is written in Cython. It claims the procfile and reads its contents
at a set frequency. It simultaneously gathers CPU and RAM performance and
diagnostic information, as well as getting information about every process. It
takes all of this information and compresses it into a custom binary protocol
and sends it to a specified network location.

Note that:

- The program is designed to be run from the command line, but can be
configured from environment variables, too.
- The program will exit gracefully if not run as root.
- If the program fails to read the procfile, it will assume the module is
installed in the kernel and try to reload it itself.
- The program gives logs in stdout

#### Files

- `agent.pyx`: entry point, most logic
- `interface.pyx`: logging and command line interfacing
- `procurement.pyx`: grabs performance and process information
- `protocol.pyx`: binary protocol logic
- `net.pyx`: networking
- `workers.pyx`: multithreading entry points
- `setup.py`: Cython entry point

### The Overseer

##### TODO

## Code Formatting

### Universal

 - no tabs (except makefiles)
 - avoid going over 80 characters in a line, unless its generally infeasible
due to indentation.
 - separate imports/includes/cimports/etc. into groups of stdlib, dependencies,
 and local sources, and sorting every group in alphabetical order. As an example:
```python
import os
import sys
import sqlite3
from threading import Lock # sorted by threading, not Lock
from threading import Thread # sorted by Thread, not threading

from bs4 import BeautifulSoup
import requests

import baz
from foo import bar
```
 - more TODOS and FIXMEs is better than less
 - if you find a file getting too multifaceted and unorganized, consider
 putting code into another file and keeping the first file organized

 - thin code is better than thick code
 - **comment your shit**
 - comments can be funny

### Python/Cython

- 4 space indents
- assume Python >= 3.11 is being used, and obey all deprecations (allowing
`match`/`case`, not allowing `distutils`, etc.)
- separate sections like the following, making sure the separator comment is 80
characters long, and is preceeded by 2 newlines:
```python
prev_section_code()


# ── NEXT SECTION ─────────────────────────────────────────────────────────── #
next_section_code()
```
- obey standardized Python styling and naming conventions (PascalCase for class
definitions, snake_case for everything else, etc.)

### C

- 2 space indents
- `enum`s are favorable, as they improve readability
- use header files
- compilation warnings are unacceptable in most cases
- aim for compatibility (duh), even if you fail
- separate sections like the following, making sure the separator comment is 80
characters long, and is preceeded by 2 newlines:
```C
prev_section_code();


/* ── NEXT SECTION ───────────────────────────────────────────────────────── */
next_section_code();
```
- obey standard C styling and naming conventions (snake_case for everything,
macros are CAPS, etc.)

### JavaScript

<sub>Note: some of these rules exist because I'm rather an amateur at
programming Javascript and hate the stuff. Some of them are generally worse for
the codebase and are very prone to change. Examples of this are italicized.
</sub>

- 2 space indents
- _lots of tiny files is preferable to a few big files_
- comment _everything_
- _every functionality gets its own file_
- obey standard JavaScript styling and naming conventions (camelCase for just
about everything, etc.)

### HTML

- 2 space indents
- use `id=` instead of `class=` where you can
- obey standard HTML styling and naming conventions

### CSS

- 2 space indents
- comment why everything _is_, because CSS gets really convoluted otherwise
- separate sections like the following, making sure the separator comment is 80
characters of width, that the words are centered to 40 characters, and the
comment preceeded by at least 1 newline:
```css
--SNIP--
}

/******************************************************************************
                                     NEXT
******************************************************************************/

--SNIP--
```

### SQL

- 4 space indents
- more lines, not less
- commas become part of the indentation instead of going after a field
- don't use deprecated stuff
<!--
- keywords are always CAPS, and nothing else is
- user defined values are always snake_case or occasionally scriptiocontinua
for really superfluous stuff
- anywhere where there can be multiple expressions in a series (after `SELECT`,
`WHERE`, etc.) every expression gets its own line
- however, where there can only be one item (`FROM`, `LIMIT`, etc.) it shares
the line with the preceeding keyword, and this applies to `WHERE` as well if
there is only one conditional expression after the `WHERE`
- operators between expressions go on the next line with the latter expression
unless preceeding a subquery
- commas go before fields and become part of the indent
- `* JOIN` field concatenations all get their own lines
-->

Instead of writing bullet points for every single typing convention I happen to
follow, here's code examples to follow the vibe of. Whatever looks best _is_
best.

##### A Simple Example:

```sql
SELECT
    id
  , name
  , CAST(number AS FLOAT)
  , CASE
        WHERE has_door_lock = "no" THEN TRUE
        ELSE FALSE
    END AS exposed
  , street_address
  , nr_cricket_bats_under_bed
FROM people
WHERE exposed IS TRUE;

```

##### A Really Not Simple Example:

```sql
SELECT
    COUNT(*)
  , COUNT(col_not_not_null) - (
        SELECT
            COUNT(col_not_not_null)
        FROM big_table
        WHERE
            yet_another_val >= you_never_expect_the_third_value
            AND even_this_val IS this_one
            AND i_think_thats_wild IS NOT NULL
    ) AS a_maths_happened
FROM tbl1
WHERE col0 >= col1
    OR col2 <= col3
INNER JOIN tbl2 ON
    tbl1.id = tbl2.id
ORDER BY id DESC;
```
