#!/usr/bin/env bash
# tests/scripts/test-part-c-smoke-behavioral-testing-standard.sh
# Smoke test: Part C consumer discovery for behavioral-testing-standard.md.
#
# Verifies that a codebase scan for references to behavioral-testing-standard.md
# (the motivating artifact from epic 8df3-61d0) finds at least 7 consumer files
# outside the standard's own directory. This is the scan mechanism Part C executes
# when given an epic that creates or modifies a shared artifact.
#
# Rule 5 compliance: behavioral-testing-standard.md is an LLM instruction file.
# This test exercises an observable referential integrity property — whether 7+
# consumer files reference the artifact — not the content of the instruction file.
#
# Usage: bash tests/scripts/test-part-c-smoke-behavioral-testing-standard.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-part-c-smoke-behavioral-testing-standard.sh ==="

ARTIFACT_BASENAME="behavioral-testing-standard"
ARTIFACT_FILE="$REPO_ROOT/plugins/dso/skills/shared/prompts/behavioral-testing-standard.md"
THIS_TEST_FILE="$(basename "${BASH_SOURCE[0]}")"

# Baseline consumer files established when this threshold was set (2026-04-08).
# These are the files that reference behavioral-testing-standard outside its own directory.
# If this test fails, verify: plugins/dso/agents/red-test-writer.md,
# plugins/dso/agents/red-test-evaluator.md, plugins/dso/agents/code-reviewer-test-quality.md,
# plugins/dso/docs/workflows/REVIEW-WORKFLOW.md, plugins/dso/hooks/pre-commit-test-quality-gate.sh,
# plugins/dso/skills/fix-bug/SKILL.md, plugins/dso/skills/implementation-plan/SKILL.md,
# and additional consumers in skills/, docs/, tests/.
# REVIEW-DEFENSE: The threshold uses >= (lower bound) rather than == (exact count) per story
# e644-9a50 Considerations: "the exact count of files referencing behavioral-testing-standard.md
# may change as the codebase evolves — assert >= 7 rather than an exact count." The lower bound
# prevents test breakage when new consumers are added and avoids the change-detector failure mode
# of exact-count assertions. With 20+ consumers at baseline, the 7-file threshold has significant
# headroom and would only fail if 13+ consumer files were simultaneously removed.
MIN_CONSUMERS=7

# ── test_part_c_scan_finds_min_7_consumers ────────────────────────────────────
# Simulates the Part C scan: grep for all files referencing behavioral-testing-standard.md
# in the codebase, excluding the artifact itself, this test file, and bookkeeping directories.
#
# Behavioral assertion: if Part C ran on an epic modifying behavioral-testing-standard.md,
# it must surface >= 7 consumer files — enough to block epics that cover only a subset
# (as 8df3-61d0 did, covering 4 out of 7+).
test_part_c_scan_finds_min_7_consumers() {
    local consumer_count

    # Grep for references; exclude the standard file itself, this test file, .git/, .tickets-tracker/
    consumer_count=$(grep -rl "$ARTIFACT_BASENAME" "$REPO_ROOT" \
        --include="*.md" \
        --include="*.sh" \
        --include="*.py" \
        --include="*.yaml" \
        --include="*.yml" \
        --include="*.json" \
        2>/dev/null \
        | grep -v ".git/" \
        | grep -v ".tickets-tracker/" \
        | grep -v "$(basename "$ARTIFACT_FILE")" \
        | grep -v "$THIS_TEST_FILE" \
        | wc -l \
        | tr -d ' ')

    if [[ "$consumer_count" -ge "$MIN_CONSUMERS" ]]; then
        assert_eq \
            "test_part_c_scan_finds_min_7_consumers: found $consumer_count consumers (need >= $MIN_CONSUMERS)" \
            "pass" "pass"
    else
        assert_eq \
            "test_part_c_scan_finds_min_7_consumers: found $consumer_count consumers (need >= $MIN_CONSUMERS)" \
            "pass" "fail"
    fi
}

test_part_c_scan_finds_min_7_consumers
print_summary
