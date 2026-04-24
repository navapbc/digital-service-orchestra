#!/usr/bin/env bash
# sprint-list-epics.sh — thin wrapper; canonical implementation in ticket-list-epics.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/ticket-list-epics.sh" "$@"
