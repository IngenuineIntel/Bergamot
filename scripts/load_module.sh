#!/usr/bin/env bash
# scripts/load_module.sh — insert the All-Seer kernel module

set -euo pipefail
cd "$(dirname "$0")/.."

KO="allseer/all_seer_kmod.ko"

if [ ! -f "$KO" ]; then
  echo "[load] Module not built yet. Run scripts/build_module.sh first."
  exit 1
fi

echo "[load] Inserting $KO..."
sudo insmod "$KO"
echo "[load] Module loaded. Check dmesg for confirmation:"
dmesg | tail -5
