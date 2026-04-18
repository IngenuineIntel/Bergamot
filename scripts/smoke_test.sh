#!/usr/bin/env bash
# scripts/smoke_test.sh — end-to-end smoke test for All-Seer
#
# Requires: the kernel module to be built (make build).
# Must be run as root (insmod + reading /proc/all_seer requires root).
#
# Exit codes: 0 = all checks passed, 1 = a check failed.

set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS() { echo -e "${GREEN}[PASS]${NC} $*"; }
FAIL() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

KO="allseer/all_seer_kmod.ko"
PROC="/proc/all_seer"
CTL="/proc/all_seer_ctl"

# ── 1. Module must be built ────────────────────────────────────────────────────
[[ -f "$KO" ]] || FAIL "Module not built — run: make build"
PASS "Module binary exists: $KO"

# ── 2. Load the module ────────────────────────────────────────────────────────
if lsmod | grep -q all_seer_kmod; then
    echo "[info] Module already loaded, unloading first..."
    sudo rmmod all_seer_kmod
fi

sudo insmod "$KO"
sleep 0.2  # let init complete

dmesg | tail -10 | grep -q "all_seer: loaded" \
    || FAIL "dmesg does not show 'all_seer: loaded'"
PASS "Module loaded and init message present in dmesg"

# ── 3. Proc files exist ────────────────────────────────────────────────────────
[[ -e "$PROC" ]] || FAIL "$PROC not created"
PASS "$PROC exists"
[[ -e "$CTL" ]]  || FAIL "$CTL not created"
PASS "$CTL exists"

# ── 4. Trigger an open event and read it back ─────────────────────────────────
# Touch a unique temp file so we can grep for it specifically.
TMPFILE=$(mktemp /tmp/bergamot_smoke_XXXX)
cat "$TMPFILE" > /dev/null  # force an open() syscall

EVENTS=$(sudo cat "$PROC")
echo "$EVENTS" | grep -q "open" \
    || FAIL "No 'open' events found in $PROC after touching $TMPFILE"
PASS "open events present in $PROC"

# ── 5. Buffer should be empty immediately after draining ──────────────────────
EVENTS2=$(sudo cat "$PROC")
[[ -z "$EVENTS2" ]] \
    || FAIL "Buffer not empty after drain — found: $(echo "$EVENTS2" | head -1)"
PASS "Buffer drained correctly"

# ── 6. Non-owner cannot read the buffer ───────────────────────────────────────
# Claim ownership as root first, then try reading as a different uid.
cat "$TMPFILE" > /dev/null   # owner = current shell (root)

# Attempt a read as nobody — should return empty.
NONOWNER=$(sudo -u nobody cat "$PROC" 2>/dev/null || true)
[[ -z "$NONOWNER" ]] \
    || FAIL "Non-owner read returned data: $NONOWNER"
PASS "Non-owner read correctly returned empty"

# ── 7. /proc/all_seer_ctl stop/start/reset ────────────────────────────────────
echo "stop" | sudo tee "$CTL" > /dev/null
STATUS=$(sudo cat "$CTL")
[[ "$STATUS" == "stopped" ]] || FAIL "ctl status after 'stop' is '$STATUS', expected 'stopped'"
PASS "ctl stop: status = stopped"

echo "start" | sudo tee "$CTL" > /dev/null
STATUS=$(sudo cat "$CTL")
[[ "$STATUS" == "running" ]] || FAIL "ctl status after 'start' is '$STATUS', expected 'running'"
PASS "ctl start: status = running"

echo "reset" | sudo tee "$CTL" > /dev/null
PASS "ctl reset: accepted"

# ── 8. Hook compile-flag override ────────────────────────────────────────────
# Quick check: rebuild with fork disabled; module should still load cleanly.
echo "[info] Rebuilding with AS_HOOK_FORK=0..."
sudo rmmod all_seer_kmod
make -C allseer clean > /dev/null
make -C allseer CFLAGS_EXTRA="-DAS_HOOK_FORK=0" > /dev/null
sudo insmod "$KO"
dmesg | tail -5 | grep -q "all_seer: loaded" \
    || FAIL "Module with AS_HOOK_FORK=0 did not load cleanly"
PASS "Module loads with AS_HOOK_FORK=0"

# ── Cleanup ────────────────────────────────────────────────────────────────────
sudo rmmod all_seer_kmod
rm -f "$TMPFILE"

# Restore full build
make -C allseer clean > /dev/null
make -C allseer > /dev/null

echo ""
PASS "All smoke tests passed."
