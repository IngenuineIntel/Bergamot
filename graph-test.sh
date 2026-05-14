#!/usr/bin/env bash
# graph-test.sh — Integration smoke test for Bergamot Overseer graph endpoints.
#
# Starts the frozen Agent and the Overseer, waits for events to accumulate,
# then verifies each graph page (HTTP 200) and the data-bearing API endpoints
# (non-empty JSON array).  Low-traffic or rarely-triggered endpoints
# (network, ptrace, dead-processes, events-per-sec) are tested as optional
# soft checks that report a warning on failure rather than failing the suite.

set -euo pipefail

HTTP_PORT=27960
HTTP_BASE="http://127.0.0.1:$HTTP_PORT"

PASS=0
FAIL=0
WARN=0

# ── Colour helpers ─────────────────────────────────────────────────────────
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
ok()   { printf "${GREEN}[PASS]${RESET} %s\n" "$*"; PASS=$((PASS+1)); }
fail() { printf "${RED}[FAIL]${RESET} %s\n" "$*"; FAIL=$((FAIL+1)); }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; WARN=$((WARN+1)); }

# ── Helpers ────────────────────────────────────────────────────────────────

# check_graph_page <path>  — expect HTTP 200 with HTML body
check_graph_page() {
    local path="$1"
    local status body
    status=$(curl -sf -o /dev/null -w "%{http_code}" "$HTTP_BASE$path" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        ok "graph page $path → HTTP $status"
    else
        fail "graph page $path → HTTP $status"
    fi
}

# check_api_data <path> [required|optional]
# Fetches a JSON-array endpoint and checks the array is non-empty.
check_api_data() {
    local path="$1"
    local mode="${2:-required}"
    local body count
    body=$(curl -sf "$HTTP_BASE$path" 2>/dev/null || echo "null")
    if echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, list) and len(data) > 0:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        ok "api data $path → non-empty"
    else
        if [[ "$mode" == "optional" ]]; then
            warn "api data $path → empty or no data (optional)"
        else
            fail "api data $path → empty or no data"
        fi
    fi
}

# ── Graph page tests (all must return 200) ─────────────────────────────────
echo ""
echo "─── Graph page tests ───────────────────────────────────────────────"
check_graph_page "/"
check_graph_page "/graph/events-per-sec"
check_graph_page "/graph/processes"
check_graph_page "/graph/file-opens"
check_graph_page "/graph/network"
check_graph_page "/graph/syscalls"
check_graph_page "/graph/fork"
check_graph_page "/graph/fork-exec"
check_graph_page "/graph/lifecycle"
check_graph_page "/graph/overview"
check_graph_page "/graph/dead-processes"

# ── API data tests ─────────────────────────────────────────────────────────
echo ""
echo "─── API data tests ─────────────────────────────────────────────────"

# Core events – these must have data after warmup.
check_api_data "/api/events"          required
check_api_data "/api/file_opens"      required
check_api_data "/api/fork"            required
check_api_data "/api/execve"          optional
check_api_data "/api/fork-exec"       required
check_api_data "/api/processes"       required
check_api_data "/api/lifecycle"       required

# Low-traffic / rarely-triggered – soft warnings only.
check_api_data "/api/network"         optional
check_api_data "/api/events/db"       optional

# Overview requires an agent handshake to populate.
check_api_data "/api/overview"        optional

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "─── Results ────────────────────────────────────────────────────────"
printf "  ${GREEN}PASS${RESET}: %d\n" "$PASS"
printf "  ${YELLOW}WARN${RESET}: %d\n" "$WARN"
printf "  ${RED}FAIL${RESET}: %d\n"   "$FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

echo "All required tests passed."
