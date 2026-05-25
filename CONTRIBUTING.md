# CONTRIBUTIONS

## Table of Contents
- [Overview](#overview)
- [Implementation Procedure](#implementation-procedure)
- [Navigating The Code](#navigating-the-code)
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

This will take a long time **TODO**.

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
- separare sections like the following, making sure the separator comment is 80
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

- more lines is better than large width
- keywords are always CAPS, and nothing else is
- avoid deprecated or non-universal funcitonalities
- obey standard SQL styling and naming conventions
