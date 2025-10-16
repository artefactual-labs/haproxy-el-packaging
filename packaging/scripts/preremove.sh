#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "0" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl stop haproxy.service >/dev/null 2>&1 || true
  systemctl disable haproxy.service >/dev/null 2>&1 || true
fi
