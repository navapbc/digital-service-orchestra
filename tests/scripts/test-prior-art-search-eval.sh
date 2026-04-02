#!/usr/bin/env bash
# tests/scripts/test-prior-art-search-eval.sh
# TDD RED phase: structural validation for the prior-art search promptfoo eval config.
# (plugins/dso/skills/shared/evals/promptfooconfig.yaml)
#
# All tests are expected to FAIL until the eval config is created.
#
# Usage: bash tests/scripts/test-prior-art-search-eval.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-prior-art-search-eval.sh ==="

EVAL_CONFIG="$PLUGIN_ROOT/plugins/dso/skills/shared/evals/promptfooconfig.yaml"

# ── test_eval_config_exists ───────────────────────────────────────────────────
# MUST be the first test function — RED marker anchors here.
# The eval config must exist and be non-empty.
test_eval_config_exists() {
    _snapshot_fail
    local actual
    if [ -f "$EVAL_CONFIG" ] && [ -s "$EVAL_CONFIG" ]; then
        actual="exists_nonempty"
    elif [ -f "$EVAL_CONFIG" ]; then
        actual="exists_empty"
    else
        actual="missing"
    fi
    assert_eq "test_eval_config_exists: file exists and non-empty" "exists_nonempty" "$actual"
    assert_pass_if_clean "test_eval_config_exists"
}

# ── test_eval_has_boundary_scenarios ─────────────────────────────────────────
# Config must contain at least 3 test entries with boundary/search/no-search
# decision keywords to validate the core trigger/no-trigger scenarios.
test_eval_has_boundary_scenarios() {
    _snapshot_fail
    local count actual
    count=0
    if [ -f "$EVAL_CONFIG" ]; then
        count=$(grep -ciE "search|no.search|boundary|trigger|should.search|skip.search|must.search" "$EVAL_CONFIG" || true)
    fi
    if [ "$count" -ge 3 ]; then
        actual="has_boundary_scenarios"
    else
        actual="insufficient (count=$count, need>=3)"
    fi
    assert_eq "test_eval_has_boundary_scenarios: at least 3 boundary scenario keywords" "has_boundary_scenarios" "$actual"
    assert_pass_if_clean "test_eval_has_boundary_scenarios"
}

# ── test_eval_has_false_positive_exclusions ───────────────────────────────────
# Config must contain test entries for routine modifications that should NOT
# trigger a prior-art search (single-file, formatting, lint).
test_eval_has_false_positive_exclusions() {
    _snapshot_fail
    local has_single_file has_formatting has_lint actual
    has_single_file="no"
    has_formatting="no"
    has_lint="no"
    if [ -f "$EVAL_CONFIG" ]; then
        if grep -qi "single.file\|single file" "$EVAL_CONFIG"; then
            has_single_file="yes"
        fi
        if grep -qiE "formatting|format" "$EVAL_CONFIG"; then
            has_formatting="yes"
        fi
        if grep -qi "lint" "$EVAL_CONFIG"; then
            has_lint="yes"
        fi
    fi
    if [ "$has_single_file" = "yes" ] && [ "$has_formatting" = "yes" ] && [ "$has_lint" = "yes" ]; then
        actual="has_all_exclusions"
    else
        actual="missing (single_file=$has_single_file formatting=$has_formatting lint=$has_lint)"
    fi
    assert_eq "test_eval_has_false_positive_exclusions: single-file, formatting, and lint exclusions present" "has_all_exclusions" "$actual"
    assert_pass_if_clean "test_eval_has_false_positive_exclusions"
}

# ── test_eval_has_incident_replay ─────────────────────────────────────────────
# Config must contain at least 3 test entries referencing known incidents
# (ACLI, bash, confident-ignorance keywords) to replay historical failures.
test_eval_has_incident_replay() {
    _snapshot_fail
    local count actual
    count=0
    if [ -f "$EVAL_CONFIG" ]; then
        count=$(grep -ciE "ACLI|bash|confident.ignorance|confident ignorance|incident|replay" "$EVAL_CONFIG" || true)
    fi
    if [ "$count" -ge 3 ]; then
        actual="has_incident_replay"
    else
        actual="insufficient (count=$count, need>=3)"
    fi
    assert_eq "test_eval_has_incident_replay: at least 3 incident-replay keywords" "has_incident_replay" "$actual"
    assert_pass_if_clean "test_eval_has_incident_replay"
}

# ── test_eval_discoverable_by_runner ─────────────────────────────────────────
# The run-skill-evals.sh --all discovery (find .../evals/promptfooconfig.yaml)
# must locate the shared/ eval config. Uses a dry-run find to avoid running npx.
test_eval_discoverable_by_runner() {
    _snapshot_fail
    local actual
    if find "$PLUGIN_ROOT/plugins/dso/skills" -path '*/evals/promptfooconfig.yaml' | grep -q "shared"; then
        actual="discoverable"
    else
        actual="not_discoverable"
    fi
    assert_eq "test_eval_discoverable_by_runner: shared eval config found by runner discovery" "discoverable" "$actual"
    assert_pass_if_clean "test_eval_discoverable_by_runner"
}

# ── test_is_executable ────────────────────────────────────────────────────────
# This test file itself must be executable.
test_is_executable() {
    _snapshot_fail
    local self actual
    self="${BASH_SOURCE[0]}"
    if [ -x "$self" ]; then
        actual="executable"
    else
        actual="not_executable"
    fi
    assert_eq "test_is_executable: test file is executable" "executable" "$actual"
    assert_pass_if_clean "test_is_executable"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_eval_config_exists
test_eval_has_boundary_scenarios
test_eval_has_false_positive_exclusions
test_eval_has_incident_replay
test_eval_discoverable_by_runner
test_is_executable

print_summary
