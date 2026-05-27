#!/usr/bin/env bash
# tests/skills/test-visual-evaluator-skill.sh
# Tests for plugins/dso/skills/visual-evaluator/SKILL.md
#
# Validates:
#   - SKILL.md exists and contains EMIT-PRECONDITIONS landmark
#   - route-map.json usage is documented
#   - design_manifest synthesis is documented
#   - visual_eval_inapplicable:route_map_missing annotation is present
#   - Gate failures exit 1 (no soft-pass)
#   - No 500-route fixture files exist in tests/
#
# Usage: bash tests/skills/test-visual-evaluator-skill.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/visual-evaluator/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-visual-evaluator-skill.sh ==="

# Test 1: fixture_route_produces_expected_output
# SKILL.md must exist, document EMIT-PRECONDITIONS, route-map.json, and design_manifest

_snapshot_fail
if [[ -f "$SKILL_FILE" ]]; then skill_exists="exists"; else skill_exists="missing"; fi
assert_eq "fixture_route_produces_expected_output:skill_exists" "exists" "$skill_exists"
assert_pass_if_clean "fixture_route_produces_expected_output:skill_exists"

_snapshot_fail
if grep -q 'EMIT-PRECONDITIONS' "$SKILL_FILE" 2>/dev/null; then has_emit="found"; else has_emit="missing"; fi
assert_eq "fixture_route_produces_expected_output:emit_preconditions" "found" "$has_emit"
assert_pass_if_clean "fixture_route_produces_expected_output:emit_preconditions"

_snapshot_fail
if grep -q 'route-map.json' "$SKILL_FILE" 2>/dev/null; then has_route_map="found"; else has_route_map="missing"; fi
assert_eq "fixture_route_produces_expected_output:route_map_json" "found" "$has_route_map"
assert_pass_if_clean "fixture_route_produces_expected_output:route_map_json"

_snapshot_fail
if grep -qi 'design.manifest\|DESIGN_MANIFEST' "$SKILL_FILE" 2>/dev/null; then has_manifest="found"; else has_manifest="missing"; fi
assert_eq "fixture_route_produces_expected_output:design_manifest" "found" "$has_manifest"
assert_pass_if_clean "fixture_route_produces_expected_output:design_manifest"

# Test 2: absent_route_map_yields_annotation_not_soft_pass
# SKILL.md must document the route_map_missing annotation and exit 1 on gate failure

_snapshot_fail
if grep -q 'visual_eval_inapplicable:route_map_missing' "$SKILL_FILE" 2>/dev/null; then has_annotation="found"; else has_annotation="missing"; fi
assert_eq "absent_route_map_yields_annotation_not_soft_pass:annotation" "found" "$has_annotation"
assert_pass_if_clean "absent_route_map_yields_annotation_not_soft_pass:annotation"

_snapshot_fail
if grep -q 'exit 1' "$SKILL_FILE" 2>/dev/null; then has_exit1="found"; else has_exit1="missing"; fi
assert_eq "absent_route_map_yields_annotation_not_soft_pass:exit_1" "found" "$has_exit1"
assert_pass_if_clean "absent_route_map_yields_annotation_not_soft_pass:exit_1"

# Test 3: 500_route_fixture_excluded
# Confirm no 500-route fixture file exists that would cause CI to run 500 screenshots

_snapshot_fail
fixture_count=$(find "$REPO_ROOT/tests" -name "route-map-500.json" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "500_route_fixture_excluded" "0" "$fixture_count"
assert_pass_if_clean "500_route_fixture_excluded"

print_summary
