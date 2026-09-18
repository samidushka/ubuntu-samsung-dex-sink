#!/usr/bin/env bash
# Prompt sudo via a GUI dialog. Used as SUDO_ASKPASS — never stores a password.
set -euo pipefail
if command -v zenity >/dev/null 2>&1; then
  zenity --password --title="DeX sink (sudo)" 2>/dev/null || true
elif command -v pkexec >/dev/null 2>&1; then
  # pkexec cannot print a password; caller should use sudo in a terminal.
  exit 1
else
  exit 1
fi
