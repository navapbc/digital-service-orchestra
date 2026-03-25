#!/usr/bin/env bash
# tests/agents/test-reviewer-dimension-names.sh
# Asserts that all code-reviewer agent definitions use the canonical dimension names
# expected by record-review.sh: hygiene, design, maintainability, correctness, verification.
#
# Usage: bash tests/agents/test-reviewer-dimension-names.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/plugins/dso/agents"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reviewer-dimension-names.sh ==="
echo ""

REVIEWER_AGENTS=(
    "$AGENTS_DIR/code-reviewer-light.md"
    "$AGENTS_DIR/code-reviewer-standard.md"
    "$AGENTS_DIR/code-reviewer-deep-arch.md"
    "$AGENTS_DIR/code-reviewer-deep-correctness.md"
    "$AGENTS_DIR/code-reviewer-deep-hygiene.md"
    "$AGENTS_DIR/code-reviewer-deep-verification.md"
)

CORRECT_DIMS=("hygiene" "design" "maintainability" "correctness" "verification")

for agent_file in "${REVIEWER_AGENTS[@]}"; do
    agent_name=$(basename "$agent_file" .md)
    echo "--- ${agent_name}: uses all correct dimension names ---"
    _snapshot_fail

    _missing_correct=0
    for correct_dim in "${CORRECT_DIMS[@]}"; do
        if ! grep -qF "\"${correct_dim}\"" "$agent_file"; then
            _missing_correct=1
            break
        fi
    done
    assert_eq "${agent_name}: must use all correct dimension names (hygiene/design/maintainability/correctness/verification)" \
        "0" "$_missing_correct"
    assert_pass_if_clean "${agent_name}_correct_dims"
    echo ""
done

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
