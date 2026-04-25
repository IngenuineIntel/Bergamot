// switches.h
// compile-time breaker
// 1 is on, 0 is off

#ifndef HOOKS_CONFIG_H
#define HOOKS_CONFIG_H

/* ── HOOK SWITCHES ──────────────────────────────────────────────────────── */
#define AS_HOOK_OPEN 1
#define AS_HOOK_FORK 1
#define AS_HOOK_EXEC 1
#define AS_HOOK_CONNECT 1

/*
 * In the event of testing all of the software on the same machine, one can
 * filter out syscalls made by the overseer. This way of doing this - that is,
 * filtering out the syscalls by the name of the process that called them -
 * isn't scalable, secure, or notably stable in any way, so this is just for
 * testing.
 */
#define AS_DEBUG_IGNORE_COMM 1
#define AS_DEBUG_IGNORE_COMM_NAME "overseer"

#endif /* HOOKS_CONFIG_H */
