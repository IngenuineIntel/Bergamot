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
#define AS_HOOK_ACCEPT 1
#define AS_HOOK_UNLINK 1
#define AS_HOOK_RENAME 1
#define AS_HOOK_SETUID 1
#define AS_HOOK_SETGID 1
#define AS_HOOK_SETREUID 1
#define AS_HOOK_CAPSET 1
#define AS_HOOK_KEYCTL 1
#define AS_HOOK_GETUID_FAMILY 1
#define AS_HOOK_GETPID_FAMILY 0 // particularly noisy

#endif /* HOOKS_CONFIG_H */
