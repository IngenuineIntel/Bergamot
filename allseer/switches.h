// switches.h
// compile-time breaker
// 1 is on, 0 is off

#ifndef HOOKS_CONFIG_H
#define HOOKS_CONFIG_H

/* ── HOOK SWITCHES ──────────────────────────────────────────────────────── */
#define AS_HOOK_OPEN 1
#define AS_HOOK_FORK 1
#define AS_HOOK_CONNECT 1
#define AS_HOOK_EXECVE 1
#define AS_HOOK_ACCEPT 0
#define AS_HOOK_UNLINK 0
#define AS_HOOK_RENAME 0
#define AS_HOOK_SETUID 0
#define AS_HOOK_SETGID 0
#define AS_HOOK_SETREUID 0
#define AS_HOOK_CAPSET 0
#define AS_HOOK_KEYCTL 0

#endif /* HOOKS_CONFIG_H */
