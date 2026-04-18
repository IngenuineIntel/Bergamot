#!/usr/bin/env bash
# scripts/unload_module.sh — remove the All-Seer kernel module

set -euo pipefail

echo "[unload] Removing all_seer_kmod..."
sudo rmmod all_seer_kmod && echo "[unload] Module removed." || echo "[unload] Module was not loaded."
