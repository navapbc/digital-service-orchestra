#!/usr/bin/env bash
# tests/hooks/test-review-gate.sh
# Tests for the review gate hook.
#
# The PreToolUse review gate was removed in Story 1idf (migration to two-layer review gate).
# The review gate has been replaced by:
#   - Layer 1: hooks/pre-commit-review-gate.sh (git pre-commit)
#   - Layer 2: hooks/lib/review-gate-bypass-sentinel.sh (PreToolUse)
# Tests for the new two-layer gate live in test-two-layer-review-gate.sh.
# is_formatting_only_change() unit tests live in test-review-gate-self-healing.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

print_summary
