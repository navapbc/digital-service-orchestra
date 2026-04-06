#!/usr/bin/env bash
# tests/scripts/test-emit-review-result.sh
# RED tests for plugins/dso/scripts/emit-review-result.sh (does NOT exist yet).
#
# Covers: all fields present, missing test-gate-status, missing findings,
# pass scenario, fail with resolution, overlay triggered, tier escalation.
#
# Usage: bash tests/scripts/test-emit-review-result.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
EMIT_RESULT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/emit-review-result.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-emit-review-result.sh ==="

# ── Shared fixtures ────────────────────────────────────────────────────────────

# Reviewer-findings.json fixture: 2 critical, 1 minor finding
_FINDINGS_JSON='{
  "scores": {
    "correctness": 3,
    "verification": 4,
    "hygiene": 5,
    "design": 3,
    "maintainability": 4
  },
  "findings": [
    {
      "severity": "critical",
      "category": "correctness",
      "description": "Missing null check on user input",
      "file": "src/handler.py"
    },
    {
      "severity": "critical",
      "category": "design",
      "description": "Circular dependency between modules",
      "file": "src/core.py"
    },
    {
      "severity": "minor",
      "category": "hygiene",
      "description": "Unused import statement",
      "file": "src/utils.py"
    }
  ],
  "summary": "Two critical issues and one minor hygiene issue found."
}'

# Pass-scenario findings fixture (no critical/important findings)
_PASS_FINDINGS_JSON='{
  "scores": {
    "correctness": 5,
    "verification": 5,
    "hygiene": 5,
    "design": 5,
    "maintainability": 5
  },
  "findings": [
    {
      "severity": "suggestion",
      "category": "maintainability",
      "description": "Consider extracting helper",
      "file": "src/utils.py"
    }
  ],
  "summary": "Clean review, only minor suggestions."
}'

# Fail-scenario findings fixture (critical findings present)
_FAIL_FINDINGS_JSON='{
  "scores": {
    "correctness": 2,
    "verification": 3,
    "hygiene": 4,
    "design": 2,
    "maintainability": 3
  },
  "findings": [
    {
      "severity": "critical",
      "category": "correctness",
      "description": "SQL injection vulnerability",
      "file": "src/db.py"
    },
    {
      "severity": "important",
      "category": "design",
      "description": "Missing error boundary",
      "file": "src/api.py"
    }
  ],
  "summary": "Critical security issue and missing error handling."
}'

# ── Helper: set up a temp dir with fixtures ────────────────────────────────────
_CLEANUP_DIRS=()

_cleanup() {
    for d in "${_CLEANUP_DIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup EXIT

_make_test_dir() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-emit-review-result-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# Write the standard fixture files into a temp dir.
# Args: $1 = temp dir, $2 = findings JSON (optional, defaults to _FINDINGS_JSON)
# Also writes test-gate-status unless $3 is "no-gate-status".
_write_fixtures() {
    local dir="$1"
    local findings="${2:-$_FINDINGS_JSON}"
    local gate_status="${3:-write}"

    echo "$findings" > "$dir/reviewer-findings.json"

    if [[ "$gate_status" != "no-gate-status" ]]; then
        printf "passed\ndiff_hash=abc123\n" > "$dir/test-gate-status"
    fi
}

# ── Test 1: all fields present ─────────────────────────────────────────────────
echo "Test 1: emit-review-result.sh produces JSONL with all expected fields"
test_emit_review_result_all_fields_present() {
    if [[ ! -f "$EMIT_RESULT_SCRIPT" ]]; then
        assert_eq "emit-review-result.sh exists" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    _write_fixtures "$tmpdir"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local output exit_code=0
    output=$(bash "$EMIT_RESULT_SCRIPT" \
        --pass-fail=failed \
        --tier-original=standard \
        --tier-final=standard \
        --revision-cycles=1 \
        --resolution-code-changes=0 \
        --resolution-defenses=0 \
        --overlay-security=false \
        --overlay-performance=false \
        2>/dev/null) || exit_code=$?

    assert_eq "exits zero" "0" "$exit_code"

    # Parse output and check all expected fields exist
    local field_check
    field_check=$(python3 -c "
import json, sys
line = sys.argv[1].strip()
data = json.loads(line)
required = [
    'pass_fail', 'tier_original', 'tier_final',
    'revision_cycles', 'resolution_code_changes', 'resolution_defenses',
    'overlay_security_triggered', 'overlay_performance_triggered',
    'test_gate_status', 'finding_count', 'critical_count'
]
missing = [f for f in required if f not in data]
if missing:
    print('missing:' + ','.join(missing))
else:
    print('all_present')
" "$output" 2>/dev/null || echo "parse_error")

    assert_eq "all required fields present" "all_present" "$field_check"
}
test_emit_review_result_all_fields_present

# ── Test 2: missing test-gate-status ───────────────────────────────────────────
echo "Test 2: emit-review-result.sh handles missing test-gate-status gracefully"
test_emit_review_result_missing_test_gate_status() {
    if [[ ! -f "$EMIT_RESULT_SCRIPT" ]]; then
        assert_eq "emit-review-result.sh exists for missing-gate-status test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    _write_fixtures "$tmpdir" "$_FINDINGS_JSON" "no-gate-status"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local output exit_code=0
    output=$(bash "$EMIT_RESULT_SCRIPT" \
        --pass-fail=failed \
        --tier-original=standard \
        --tier-final=standard \
        --revision-cycles=0 \
        2>/dev/null) || exit_code=$?

    assert_eq "exits zero even without test-gate-status" "0" "$exit_code"

    # test_gate_status should default to "unknown"
    local gate_val
    gate_val=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('test_gate_status', 'MISSING'))
" "$output" 2>/dev/null || echo "parse_error")

    assert_eq "test_gate_status defaults to unknown" "unknown" "$gate_val"
}
test_emit_review_result_missing_test_gate_status

# ── Test 3: missing findings fails ─────────────────────────────────────────────
echo "Test 3: emit-review-result.sh fails when reviewer-findings.json is missing"
test_emit_review_result_missing_findings_fails() {
    if [[ ! -f "$EMIT_RESULT_SCRIPT" ]]; then
        assert_eq "emit-review-result.sh exists for missing-findings test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    # Do NOT write reviewer-findings.json — only test-gate-status
    printf "passed\ndiff_hash=abc123\n" > "$tmpdir/test-gate-status"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local exit_code=0
    bash "$EMIT_RESULT_SCRIPT" \
        --pass-fail=failed \
        --tier-original=standard \
        --tier-final=standard \
        --revision-cycles=0 \
        2>/dev/null || exit_code=$?

    assert_eq "exits non-zero without reviewer-findings.json" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"
}
test_emit_review_result_missing_findings_fails

# ── Test 4: pass scenario ──────────────────────────────────────────────────────
echo "Test 4: emit-review-result.sh emits correct values for a pass scenario"
test_emit_review_result_pass_scenario() {
    if [[ ! -f "$EMIT_RESULT_SCRIPT" ]]; then
        assert_eq "emit-review-result.sh exists for pass-scenario test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    _write_fixtures "$tmpdir" "$_PASS_FINDINGS_JSON"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local output exit_code=0
    output=$(bash "$EMIT_RESULT_SCRIPT" \
        --pass-fail=passed \
        --tier-original=light \
        --tier-final=light \
        --revision-cycles=0 \
        2>/dev/null) || exit_code=$?

    assert_eq "pass scenario exits zero" "0" "$exit_code"

    # Verify pass_fail=passed and revision_cycles=0
    local pass_val cycles_val
    pass_val=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('pass_fail', 'MISSING'))
" "$output" 2>/dev/null || echo "parse_error")

    cycles_val=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('revision_cycles', 'MISSING'))
" "$output" 2>/dev/null || echo "parse_error")

    assert_eq "pass_fail is passed" "passed" "$pass_val"
    assert_eq "revision_cycles is 0" "0" "$cycles_val"
}
test_emit_review_result_pass_scenario

# ── Test 5: fail with resolution ───────────────────────────────────────────────
echo "Test 5: emit-review-result.sh emits correct resolution counts on failure"
test_emit_review_result_fail_with_resolution() {
    if [[ ! -f "$EMIT_RESULT_SCRIPT" ]]; then
        assert_eq "emit-review-result.sh exists for fail-with-resolution test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    _write_fixtures "$tmpdir" "$_FAIL_FINDINGS_JSON"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local output exit_code=0
    output=$(bash "$EMIT_RESULT_SCRIPT" \
        --pass-fail=failed \
        --tier-original=standard \
        --tier-final=deep \
        --revision-cycles=2 \
        --resolution-code-changes=3 \
        --resolution-defenses=1 \
        2>/dev/null) || exit_code=$?

    assert_eq "fail-with-resolution exits zero" "0" "$exit_code"

    # Verify resolution counts
    local code_changes defenses cycles
    code_changes=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('resolution_code_changes', 'MISSING'))
" "$output" 2>/dev/null || echo "parse_error")

    defenses=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('resolution_defenses', 'MISSING'))
" "$output" 2>/dev/null || echo "parse_error")

    cycles=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('revision_cycles', 'MISSING'))
" "$output" 2>/dev/null || echo "parse_error")

    assert_eq "resolution_code_changes is 3" "3" "$code_changes"
    assert_eq "resolution_defenses is 1" "1" "$defenses"
    assert_eq "revision_cycles is 2" "2" "$cycles"
}
test_emit_review_result_fail_with_resolution

# ── Test 6: overlay triggered ──────────────────────────────────────────────────
echo "Test 6: emit-review-result.sh records overlay flags correctly"
test_emit_review_result_overlay_triggered() {
    if [[ ! -f "$EMIT_RESULT_SCRIPT" ]]; then
        assert_eq "emit-review-result.sh exists for overlay-triggered test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    _write_fixtures "$tmpdir"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local output exit_code=0
    output=$(bash "$EMIT_RESULT_SCRIPT" \
        --pass-fail=passed \
        --tier-original=deep \
        --tier-final=deep \
        --revision-cycles=0 \
        --overlay-security=true \
        --overlay-performance=true \
        2>/dev/null) || exit_code=$?

    assert_eq "overlay test exits zero" "0" "$exit_code"

    # Verify overlay flags
    local sec_overlay perf_overlay
    sec_overlay=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(str(data.get('overlay_security_triggered', 'MISSING')).lower())
" "$output" 2>/dev/null || echo "parse_error")

    perf_overlay=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(str(data.get('overlay_performance_triggered', 'MISSING')).lower())
" "$output" 2>/dev/null || echo "parse_error")

    assert_eq "overlay_security_triggered is true" "true" "$sec_overlay"
    assert_eq "overlay_performance_triggered is true" "true" "$perf_overlay"
}
test_emit_review_result_overlay_triggered

# ── Test 7: tier escalation ────────────────────────────────────────────────────
echo "Test 7: emit-review-result.sh records tier escalation correctly"
test_emit_review_result_tier_escalation() {
    if [[ ! -f "$EMIT_RESULT_SCRIPT" ]]; then
        assert_eq "emit-review-result.sh exists for tier-escalation test" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(_make_test_dir)
    _write_fixtures "$tmpdir"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local output exit_code=0
    output=$(bash "$EMIT_RESULT_SCRIPT" \
        --pass-fail=failed \
        --tier-original=light \
        --tier-final=standard \
        --revision-cycles=1 \
        2>/dev/null) || exit_code=$?

    assert_eq "tier escalation test exits zero" "0" "$exit_code"

    # Verify tier fields
    local tier_orig tier_final
    tier_orig=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('tier_original', 'MISSING'))
" "$output" 2>/dev/null || echo "parse_error")

    tier_final=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1].strip())
print(data.get('tier_final', 'MISSING'))
" "$output" 2>/dev/null || echo "parse_error")

    assert_eq "tier_original is light" "light" "$tier_orig"
    assert_eq "tier_final is standard" "standard" "$tier_final"
}
test_emit_review_result_tier_escalation

print_summary
