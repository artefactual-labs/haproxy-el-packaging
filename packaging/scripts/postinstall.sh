#!/usr/bin/env bash
set -euo pipefail

if command -v systemd-sysusers >/dev/null 2>&1; then
  systemd-sysusers /usr/lib/sysusers.d/haproxy.conf
fi

if systemctl is-system-running >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl preset haproxy.service >/dev/null 2>&1 || true
fi
