#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# build-review-agents.sh — thin wrapper around build-composed-agents.sh for the "reviewer" namespace.
# Backward-compatible: existing CLI flags (--base, --deltas, --output, --expect-count) still work.
# All composition logic lives in build-composed-agents.sh; reviewer-specific metadata is in
# docs/workflows/prompts/reviewer-meta.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/build-composed-agents.sh" \
    --namespace reviewer \
    --generator-name "build-review-agents.sh" \
    "$@"
