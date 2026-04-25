# CONTRIBUTING TO THIS CODE
**is greatly encouraged.** However, please follow the instructions below so
that code organization remains consistent and as easy to navigate as possible.
 - Please read all documentation petaining to the contribution you want to make
before development.
 - Please ask questions regarding where things should be placed and/or use your
best judgement when adding new features that don't have a place already.
 - If you are adding a new feature, please document how it works in this file
and the ways it can be added to/enhanced.
 - If applicable (for novel features (use best judgement)), write a test for
your contribution (see checklist below)
 - Lastly, thank you for your contribution!

## BEFORE YOU BEGIN - A Primer on What Everything Does

##### `allseer.c`
Is the core of the program. It contains/defines:
 - Procfile logic
 - Kprobes logic
 - Log buffer logic
 - Procfile ownership logic

##### `allseer.h`
Holds miscellaneous code for procfs interfacing.

##### `switches.h`
Holds compile-time options to enable-disable different features/hooks/etc.

##### `hooks.c`
Holds a the logic for every individual hook.

### BEHAVIORS

##### TODO

## CODE CONFORMITY

When writing contributions, please make sure you:
 - Use spaces, not tabs
 - Indent 2 spaces, not 4
 - Space out unrelated lines of code, but not with multiple line breaks

### STEPS FOR ADDING SYSCALL HOOKS
 - Add a macro switch to `switches.h`
 - Add to the `as_event_type` enum in `allseer.h`
 - Add code utilizing the additon to the enum in `allseer.c` directly under
 `PROCFS INTERFACE`
 - Create a function for the hook in `hooks.c` in a way that mimicks the
 preexisting hooks
 - Create entries in `allseer.c` under `KPROBE DECLARATIONS`, both an extern
 to your hook function and an entry in `as_kprobes`, both mimicking the
 preexisting code

##### NOTE
**Please keep all hook-related code in the canonical order of the syscalls
referenced.** It makes code easier to find.