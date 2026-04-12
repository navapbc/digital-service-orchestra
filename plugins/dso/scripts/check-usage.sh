#!/usr/bin/env bash
# check-usage.sh
# Thin bash wrapper around check_usage.py.
# Exit codes: 0=unlimited, 1=throttled, 2=paused.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check_usage.py" "$@"
