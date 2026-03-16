#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-review-gate.sh
# Tests for the review gate hook.
#
# The PreToolUse review gate was removed in Story 1idf (migration to two-layer review gate).
# The review gate has been replaced by:
#   - Layer 1: lockpick-workflow/hooks/pre-commit-review-gate.sh (git pre-commit)
#   - Layer 2: lockpick-workflow/hooks/lib/review-gate-bypass-sentinel.sh (PreToolUse)
# Tests for the new two-layer gate live in test-two-layer-review-gate.sh.
# is_formatting_only_change() unit tests live in test-review-gate-self-healing.sh.

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

print_summary
