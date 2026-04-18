#!/usr/bin/env bash
# scripts/universal_test.sh
# Universal Bergamot component test runner.
#
# What it tests:
#  1) All-Seer kernel module build
#  2) All-Seer kernel runtime checks (required: root or passwordless sudo)
#  3) Over-Seer + Under-Seer + real /proc/all_seer pipeline using separate venvs
#
# Exit codes:
#  0 = all required checks passed
#  1 = required check failed

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UNDER_PY="$ROOT_DIR/venv_underseer/bin/python"
OVER_PY="$ROOT_DIR/venv_overseer/bin/python"

LOG_DIR="/tmp/bergamot_universal_test_$$"
OVER_PID=""
UNDER_PID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
fail() {
  echo -e "${RED}[FAIL]${NC} $*"
  echo ""
  echo "--- Logs ---"
  if [[ -d "$LOG_DIR" ]]; then
    ls -1 "$LOG_DIR" || true
    for f in "$LOG_DIR"/*.log; do
      [[ -f "$f" ]] || continue
      echo ""
      echo "### $(basename "$f")"
      tail -n 60 "$f" || true
    done
  fi
  exit 1
}

cleanup() {
  set +e
  [[ -n "$UNDER_PID" ]] && kill "$UNDER_PID" 2>/dev/null
  [[ -n "$OVER_PID" ]] && kill "$OVER_PID" 2>/dev/null

  [[ -n "$UNDER_PID" ]] && wait "$UNDER_PID" 2>/dev/null
  [[ -n "$OVER_PID" ]] && wait "$OVER_PID" 2>/dev/null

  if grep -q '^all_seer_kmod ' /proc/modules 2>/dev/null; then
    sudo rmmod all_seer_kmod >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

sudo_cmd() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

choose_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_http_ok() {
  local url="$1"
  local timeout_s="${2:-20}"
  local i
  for ((i=0; i<timeout_s*10; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_events() {
  local url="$1"
  local timeout_s="${2:-30}"
  local i json count
  for ((i=0; i<timeout_s; i++)); do
    json="$(curl -fsS "$url" 2>/dev/null || true)"
    if [[ -n "$json" ]]; then
      count="$(python3 - <<'PY' "$json"
import json, sys
try:
    v = json.loads(sys.argv[1])
    print(len(v) if isinstance(v, list) else 0)
except Exception:
    print(0)
PY
)"
      if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

trigger_syscalls() {
  local i
  for ((i=0; i<20; i++)); do
    cat /etc/hosts >/dev/null 2>&1 || true
    ls /tmp >/dev/null 2>&1 || true
    bash -lc 'true' >/dev/null 2>&1 || true
    sleep 0.05
  done
}

mkdir -p "$LOG_DIR"

info "Using project root: $ROOT_DIR"
info "Logs: $LOG_DIR"

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v make >/dev/null 2>&1 || fail "make is required"
[[ -x "$UNDER_PY" ]] || fail "Missing venv python: $UNDER_PY"
[[ -x "$OVER_PY" ]] || fail "Missing venv python: $OVER_PY"
pass "Prerequisites and venv interpreters are available"

if ! ([[ ${EUID:-$(id -u)} -eq 0 ]] || sudo -n true >/dev/null 2>&1); then
  fail "Kernel-module test requires root or passwordless sudo"
fi
pass "Root privileges available for kernel-module testing"

# 1) Kernel module build test
info "Testing kernel module build"
make -C allseer clean >/dev/null
make -C allseer >/dev/null
[[ -f allseer/build/all_seer_kmod.ko ]] || fail "Built module not found"
pass "All-Seer kernel module builds successfully"

# 2) Kernel runtime checks
info "Testing kernel runtime controls"

if grep -q '^all_seer_kmod ' /proc/modules 2>/dev/null; then
  info "all_seer_kmod already loaded; trying to unload for a fresh test"
  sudo rmmod all_seer_kmod || true
fi

if grep -q '^all_seer_kmod ' /proc/modules 2>/dev/null; then
  info "all_seer_kmod still loaded; reusing existing loaded module"
else
  sudo insmod allseer/build/all_seer_kmod.ko
fi
sleep 0.2

[[ -e /proc/all_seer ]] || fail "/proc/all_seer missing after insmod"
[[ -e /proc/all_seer_ctl ]] || fail "/proc/all_seer_ctl missing after insmod"

echo "stop"  | sudo tee /proc/all_seer_ctl >/dev/null
ctl_status="$(sudo cat /proc/all_seer_ctl | head -n1)"
[[ "$ctl_status" == "stopped" ]] || fail "Expected stopped, got: $ctl_status"

echo "start" | sudo tee /proc/all_seer_ctl >/dev/null
ctl_status="$(sudo cat /proc/all_seer_ctl | head -n1)"
[[ "$ctl_status" == "running" ]] || fail "Expected running, got: $ctl_status"

echo "reset" | sudo tee /proc/all_seer_ctl >/dev/null
pass "Kernel proc controls and status checks passed"

# 3) Userspace pipeline test (venv_overseer + venv_underseer + real /proc)
TCP_PORT="$(choose_port)"
FLASK_PORT="$(choose_port)"

info "Testing userspace pipeline on TCP $TCP_PORT and HTTP $FLASK_PORT"

TCP_PORT="$TCP_PORT" FLASK_HOST="127.0.0.1" FLASK_PORT="$FLASK_PORT" \
  "$OVER_PY" overseer/app.py >"$LOG_DIR/overseer.log" 2>&1 &
OVER_PID=$!

wait_http_ok "http://127.0.0.1:${FLASK_PORT}/api/stats" 25 \
  || fail "Over-Seer API did not become ready"
pass "Over-Seer started and API is reachable"

sudo env OVERSEER_HOST="127.0.0.1" OVERSEER_PORT="$TCP_PORT" \
  PROC_PATH="/proc/all_seer" PROC_CTL_PATH="/proc/all_seer_ctl" \
  POLL_INTERVAL_MS="50" \
  "$UNDER_PY" underseer/underseer.py >"$LOG_DIR/underseer.log" 2>&1 &
UNDER_PID=$!

sleep 0.5
trigger_syscalls

wait_for_events "http://127.0.0.1:${FLASK_PORT}/api/events" 30 \
  || fail "No events reached Over-Seer from Under-Seer"
pass "Under-Seer forwarding and Over-Seer ingest are working"

stats_json="$(curl -fsS "http://127.0.0.1:${FLASK_PORT}/api/stats")"
python3 - <<'PY' "$stats_json" >/dev/null
import json, sys
s = json.loads(sys.argv[1])
assert isinstance(s, dict)
assert 'events_per_sec' in s
assert 'agent_count' in s
assert 'uptime_s' in s
PY
pass "Over-Seer stats schema is valid"

# Browser URL for manual dashboard verification.
dashboard_url="http://127.0.0.1:${FLASK_PORT}/"
stream_url="http://127.0.0.1:${FLASK_PORT}/api/stream"
info "Visit dashboard in browser: ${dashboard_url}"
info "(Optional) SSE endpoint URL: ${stream_url}"
pass "Dashboard URLs emitted for manual web validation"

# Keep services running for manual browser verification when invoked from an
# interactive terminal. They are stopped after pressing Enter.
if [[ -t 0 ]]; then
  echo ""
  info "Services are still running for manual checks."
  read -r -p "Press Enter to stop services and finish test... " _
fi

echo ""
pass "Universal component test passed"
