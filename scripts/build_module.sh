#!/usr/bin/env bash
# scripts/build_module.sh — build the All-Seer kernel module
#
# Usage:
#   ./scripts/build_module.sh
#   CFLAGS_EXTRA="-DAS_HOOK_FORK=0" ./scripts/build_module.sh

set -euo pipefail
cd "$(dirname "$0")/.."

echo "[build] Compiling All-Seer kernel module..."
make -C allseer CFLAGS_EXTRA="${CFLAGS_EXTRA:-}"
echo "[build] Done: allseer/all_seer_kmod.ko"
