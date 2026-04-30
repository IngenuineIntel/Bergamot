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

Upon being loaded, the module first registers `/proc/all_seer`. After this, it
registers Kprobe hooks. If _any_ hooks fail, it prints an error specifying
which hook failed, unregisters the proc file and all registered Kprobe hooks,
and returns the error code it was given. Assuming this doesn't happen, it logs
success, marks the module as ready, and returns success.

##### Proc File Security System

The first program to successfully open `/proc/all_seer` claims it for its
parent process. After that, only programs with that same PPID may open or read
the file, and that ownership stays in place until the module is unloaded or
reloaded.

##### TODO

More elaborations here...


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
Holds the logic for every individual hook.

## CODE CONFORMITY

When writing contributions, please make sure you:
 - Use spaces, not tabs
 - Indent 2 spaces, not 4
 - Space out unrelated lines of code, but not with multiple line breaks

## INSTRUCTIONS PERTAINING TO CERTAIN CONTRIBUTIONS

### STEPS FOR ADDING SYSCALL HOOKS
 - Add a macro switch to `switches.h` for disabling the hook
 - Add to the `as_event_type` enum in `allseer.h` as `AS_TYPE_<syscall>
 - Add to `as_type_str` array in `allseer.c` an entry for your
 `AS_TYPE_<syscall>`
 - Create a function for the hook in `hooks.c` as `as_probe_<syscall>(struct
 kprobe *p, struct pt_regs *regs)`, always at the end of the file, guarded by
 the macro switch
 - Create entries in `allseer.c` under `KPROBE DECLARATIONS`, both an extern
 to your hook function and a `struct kprobe` entry in `as_kprobes`, both guarded by your macro switch

##### NOTE
**Please keep all hook-related code in the canonical order of the syscalls
referenced.** It makes code easier to find.
