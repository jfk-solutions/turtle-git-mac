#!/bin/bash
# Native transport check; no GUI app or Finder instance is launched.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/verify-browser-item-provider.py "$@"
