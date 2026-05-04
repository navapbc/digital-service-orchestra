#!/usr/bin/env bash
# tests/scripts/test-ci-findings-normalize.sh
# RED tests for plugins/dso/scripts/lib/ci-findings-normalize.sh
#
# All 5 tests fail in RED phase because ci-findings-normalize.sh does not
# yet exist. They turn GREEN once the library is implemented.
#
# Tests:
#   1. t_normalize_tier1_output_schema              — output has schema_version=1, tier, findings
#   2. t_normalize_tier1_schema_conformance         — findings entries have severity/description/file
#   3. t_normalize_tier1_missing_findings_key_returns_nonzero — missing findings key → non-zero exit
#   4. t_normalize_tier1_empty_findings_array_emits_valid_schema — empty findings → valid JSON
#   5. t_lib_mode_guard                             — CI_FINDINGS_LIB_MODE=1 defines func, no stdout
#
# Usage: bash tests/scripts/test-ci-findings-normalize.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB_SCRIPT="$REPO_ROOT/plugins/dso/scripts/lib/ci-findings-normalize.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Shared fixture: a minimal valid reviewer-findings.json
# ---------------------------------------------------------------------------
_build_findings_fixture() {
    local outfile="$1"
    cat > "$outfile" <<'JSON'
{
  "findings": [
    {
      "severity": "critical",
      "description": "Unchecked return value in auth path",
      "file": "src/auth.sh",
      "line": 42
    },
    {
      "severity": "important",
      "description": "Missing error handling for network timeout",
      "file": "src/net.sh",
      "line": 17
    }
  ]
}
JSON
}

# ---------------------------------------------------------------------------
# Test 1: t_normalize_tier1_output_schema
# Given: valid reviewer-findings.json
# When: _normalize_tier1 is called
# Then: output JSON contains schema_version=1, tier="llm-review", findings array
# ---------------------------------------------------------------------------
t_normalize_tier1_output_schema() {
    local _input _output _result _check

    _input="$(mktemp /tmp/findings-input.XXXXXX)"
    _output="$(mktemp /tmp/findings-output.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$_input' '$_output'" RETURN

    _build_findings_fixture "$_input"

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT"
        _normalize_tier1 "$_input" "$_output"
    ) 2>/dev/null || true

    _result="$(cat "$_output" 2>/dev/null || echo '')"

    # Validate all three fields in one python call — emit "ok" only if all pass
    _check="$(echo "$_result" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ok = (
        d.get("schema_version") == 1 and
        d.get("tier") == "llm-review" and
        isinstance(d.get("findings"), list)
    )
    print("ok" if ok else "fail:schema_version=%s tier=%s findings=%s" % (d.get("schema_version"), d.get("tier"), type(d.get("findings")).__name__))
except Exception as e:
    print("invalid-json:" + str(e))
' 2>/dev/null || echo 'parse-error')"

    assert_eq "t_normalize_tier1_output_schema: schema_version=1 tier=llm-review findings=[]" "ok" "$_check"
}
t_normalize_tier1_output_schema

# ---------------------------------------------------------------------------
# Test 2: t_normalize_tier1_schema_conformance
# Given: valid reviewer-findings.json with 2 entries
# When: _normalize_tier1 is called
# Then: each findings entry contains severity, description, and file fields
# ---------------------------------------------------------------------------
t_normalize_tier1_schema_conformance() {
    local _input _output _result _conformant

    _input="$(mktemp /tmp/findings-input.XXXXXX)"
    _output="$(mktemp /tmp/findings-output.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$_input' '$_output'" RETURN

    _build_findings_fixture "$_input"

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT"
        _normalize_tier1 "$_input" "$_output"
    ) 2>/dev/null || true

    _result="$(cat "$_output" 2>/dev/null || echo '')"

    _conformant="$(echo "$_result" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    findings = d.get("findings", [])
    if not findings:
        print("no-findings")
    elif all("severity" in f and "description" in f and "file" in f for f in findings):
        print("conformant")
    else:
        print("missing-fields")
except Exception as e:
    print("invalid-json")
' 2>/dev/null || echo 'parse-error')"

    assert_eq "t_normalize_tier1_schema_conformance: all entries have required fields" "conformant" "$_conformant"
}
t_normalize_tier1_schema_conformance

# ---------------------------------------------------------------------------
# Test 3: t_normalize_tier1_missing_findings_key_returns_nonzero
# Given: input JSON has no "findings" key
# When: _normalize_tier1 is called
# Then: exit code is non-zero (strictly ≥ 1 and ≤ 125, not a signal or source-fail code)
# ---------------------------------------------------------------------------
t_normalize_tier1_missing_findings_key_returns_nonzero() {
    local _tmpf _tmpout _exit_code _is_domain_nonzero _ec_file

    _tmpf="$(mktemp /tmp/no-findings.XXXXXX)"
    _tmpout="$(mktemp /tmp/out.XXXXXX)"
    _ec_file="$(mktemp /tmp/ec.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$_tmpf' '$_tmpout' '$_ec_file'" RETURN

    printf '{"other":1}' > "$_tmpf"

    # Capture the exit code from _normalize_tier1 only (not from source failure).
    # The subshell writes the exit code to a temp file so we can distinguish
    # "source failed (lib missing)" from "_normalize_tier1 exited non-zero".
    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT" 2>/dev/null || { echo "source-failed" > "$_ec_file"; exit 0; }
        _normalize_tier1 "$_tmpf" "$_tmpout" 2>/dev/null
        echo "$?" > "$_ec_file"
    ) 2>/dev/null || true
    _exit_code="$(cat "$_ec_file" 2>/dev/null || echo 'unset')"

    # In GREEN phase: _exit_code should be a non-zero integer (1-125).
    # In RED phase: _exit_code is "source-failed" because the lib doesn't exist.
    # We assert it equals a valid domain non-zero code (1-125); "source-failed" fails this.
    if [[ "$_exit_code" =~ ^[1-9][0-9]*$ ]] && [[ "$_exit_code" -le 125 ]]; then
        _is_domain_nonzero="yes"
    else
        _is_domain_nonzero="no"
    fi

    assert_eq "t_normalize_tier1_missing_findings_key_returns_nonzero: _normalize_tier1 exits non-zero for missing findings key" "yes" "$_is_domain_nonzero"
}
t_normalize_tier1_missing_findings_key_returns_nonzero

# ---------------------------------------------------------------------------
# Test 4: t_normalize_tier1_empty_findings_array_emits_valid_schema
# Given: input JSON has "findings": []
# When: _normalize_tier1 is called
# Then: output is valid JSON with findings key present and value []
# ---------------------------------------------------------------------------
t_normalize_tier1_empty_findings_array_emits_valid_schema() {
    local _input _output _result _findings_val

    _input="$(mktemp /tmp/findings-empty.XXXXXX)"
    _output="$(mktemp /tmp/findings-out.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$_input' '$_output'" RETURN

    printf '{"findings":[]}' > "$_input"

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT"
        _normalize_tier1 "$_input" "$_output"
    ) 2>/dev/null || true

    _result="$(cat "$_output" 2>/dev/null || echo '')"

    _findings_val="$(echo "$_result" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    findings = d.get("findings", "MISSING")
    if findings == "MISSING":
        print("missing")
    elif findings == []:
        print("empty-array")
    else:
        print("non-empty")
except Exception as e:
    print("invalid-json")
' 2>/dev/null || echo 'parse-error')"

    assert_eq "t_normalize_tier1_empty_findings_array_emits_valid_schema: findings=[]" "empty-array" "$_findings_val"
}
t_normalize_tier1_empty_findings_array_emits_valid_schema

# ---------------------------------------------------------------------------
# Test 5: t_lib_mode_guard
# Given: CI_FINDINGS_LIB_MODE=1 and the library is sourced
# When: the library is loaded
# Then: _normalize_tier1 is defined AND no output is emitted to stdout
# ---------------------------------------------------------------------------
t_lib_mode_guard() {
    local _func_defined _extra_stdout

    # Check: function defined after sourcing with lib mode
    _func_defined="$(CI_FINDINGS_LIB_MODE=1 bash -c "source '$LIB_SCRIPT' 2>/dev/null && declare -f _normalize_tier1 | grep -c '_normalize_tier1'" 2>/dev/null || echo '0')"

    if [[ "$_func_defined" -gt 0 ]] 2>/dev/null; then
        _func_defined="yes"
    else
        _func_defined="no"
    fi
    assert_eq "t_lib_mode_guard: _normalize_tier1 defined after source" "yes" "$_func_defined"

    # Check: no stdout emitted when sourcing in lib mode
    _extra_stdout="$(CI_FINDINGS_LIB_MODE=1 bash -c "source '$LIB_SCRIPT'" 2>/dev/null || echo '')"
    assert_eq "t_lib_mode_guard: no stdout emitted on source" "" "$_extra_stdout"
}
t_lib_mode_guard

# ---------------------------------------------------------------------------
print_summary
