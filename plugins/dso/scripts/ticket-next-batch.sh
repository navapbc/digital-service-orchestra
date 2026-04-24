#!/usr/bin/env bash
# ticket-next-batch.sh — Thin-delegate shim for 'ticket next-batch'.
# Delegates to sprint-next-batch.sh to guarantee byte-for-byte output equivalence.
# See: 958a-66ac Proposal A (approach-decision-maker selection).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/sprint-next-batch.sh" "$@"
