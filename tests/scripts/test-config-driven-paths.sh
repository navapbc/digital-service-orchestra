#!/usr/bin/env bash
# tests/scripts/test-config-driven-paths.sh
# Tests that validation/review/impact scripts use config-paths.sh
# instead of hardcoded app/src, app/tests, and snapshot paths.
#
# Covers:
#   - validate-phase.sh sources config-paths.sh (no hardcoded app/src or app/tests)
#   - enrich-file-impact.sh has no hardcoded app/src or app/tests
#   - skip-review-check.sh has no hardcoded app/tests/e2e/snapshots
#   - pre-bash-functions.sh has no hardcoded app/tests/e2e/snapshots
#   - All 4 scripts source config-paths.sh
#
# Usage: bash tests/scripts/test-config-driven-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-config-driven-paths.sh ==="

VALIDATE_PHASE="$PLUGIN_ROOT/scripts/validate-phase.sh"
ENRICH_IMPACT="$PLUGIN_ROOT/scripts/enrich-file-impact.sh"
SKIP_REVIEW="$PLUGIN_ROOT/scripts/skip-review-check.sh"
PRE_BASH_FUNCS="$PLUGIN_ROOT/hooks/lib/pre-bash-functions.sh"

# ── test_validate_phase_no_hardcoded_app_src ─────────────────────────────────
# validate-phase.sh must not contain hardcoded "$REPO_ROOT/app/src" or "$REPO_ROOT/app/tests".
_snapshot_fail
hardcoded_found=0
# Check for hardcoded "$REPO_ROOT/app/src" or "$REPO_ROOT/app/tests" outside of comments and fallback defaults
grep -n '"$REPO_ROOT/app/src"\|"$REPO_ROOT/app/tests"' "$VALIDATE_PHASE" 2>/dev/null && hardcoded_found=1
assert_eq "test_validate_phase_no_hardcoded_app_src: no hardcoded app/src or app/tests" "0" "$hardcoded_found"
assert_pass_if_clean "test_validate_phase_no_hardcoded_app_src"

# ── test_enrich_file_impact_no_hardcoded_paths ───────────────────────────────
# enrich-file-impact.sh must not contain hardcoded app/src or app/tests.
_snapshot_fail
enrich_hardcoded=0
grep -q 'app/src\|app/tests' "$ENRICH_IMPACT" 2>/dev/null && enrich_hardcoded=1
assert_eq "test_enrich_file_impact_no_hardcoded_paths: no hardcoded app/src or app/tests" "0" "$enrich_hardcoded"
assert_pass_if_clean "test_enrich_file_impact_no_hardcoded_paths"

# ── test_skip_review_no_hardcoded_e2e_snapshots ──────────────────────────────
# skip-review-check.sh must not contain hardcoded app/tests/e2e/snapshots.
_snapshot_fail
skip_hardcoded=0
grep -q 'app/tests/e2e/snapshots' "$SKIP_REVIEW" 2>/dev/null && skip_hardcoded=1
assert_eq "test_skip_review_no_hardcoded_e2e_snapshots: no hardcoded e2e snapshot path" "0" "$skip_hardcoded"
assert_pass_if_clean "test_skip_review_no_hardcoded_e2e_snapshots"

# ── test_pre_bash_no_hardcoded_e2e_snapshots ─────────────────────────────────
# pre-bash-functions.sh must not contain hardcoded app/tests/e2e/snapshots.
_snapshot_fail
prebash_hardcoded=0
grep -q 'app/tests/e2e/snapshots' "$PRE_BASH_FUNCS" 2>/dev/null && prebash_hardcoded=1
assert_eq "test_pre_bash_no_hardcoded_e2e_snapshots: no hardcoded e2e snapshot path" "0" "$prebash_hardcoded"
assert_pass_if_clean "test_pre_bash_no_hardcoded_e2e_snapshots"

# ── test_all_four_scripts_source_config_paths ────────────────────────────────
# All 4 scripts must source config-paths.sh.
_snapshot_fail
source_count=0
for f in "$VALIDATE_PHASE" "$ENRICH_IMPACT" "$SKIP_REVIEW" "$PRE_BASH_FUNCS"; do
    grep -q 'config-paths.sh' "$f" 2>/dev/null && source_count=$((source_count + 1))
done
assert_eq "test_all_four_scripts_source_config_paths: all 4 source config-paths.sh" "4" "$source_count"
assert_pass_if_clean "test_all_four_scripts_source_config_paths"

# ── test_skip_review_no_hardcoded_unit_snapshots ─────────────────────────────
# skip-review-check.sh must not contain hardcoded app/tests/unit/templates/snapshots.
_snapshot_fail
skip_unit_hardcoded=0
grep -q 'app/tests/unit/templates/snapshots' "$SKIP_REVIEW" 2>/dev/null && skip_unit_hardcoded=1
assert_eq "test_skip_review_no_hardcoded_unit_snapshots: no hardcoded unit snapshot path" "0" "$skip_unit_hardcoded"
assert_pass_if_clean "test_skip_review_no_hardcoded_unit_snapshots"

# ── test_pre_bash_no_hardcoded_unit_snapshots ────────────────────────────────
# pre-bash-functions.sh must not contain hardcoded app/tests/unit/templates/snapshots.
_snapshot_fail
prebash_unit_hardcoded=0
grep -q 'app/tests/unit/templates/snapshots' "$PRE_BASH_FUNCS" 2>/dev/null && prebash_unit_hardcoded=1
assert_eq "test_pre_bash_no_hardcoded_unit_snapshots: no hardcoded unit snapshot path" "0" "$prebash_unit_hardcoded"
assert_pass_if_clean "test_pre_bash_no_hardcoded_unit_snapshots"

print_summary
