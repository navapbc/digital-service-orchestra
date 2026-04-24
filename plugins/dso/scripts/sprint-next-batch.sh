#!/usr/bin/env bash
# sprint-next-batch.sh — thin wrapper; canonical implementation in ticket-next-batch.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/ticket-next-batch.sh" "$@"
