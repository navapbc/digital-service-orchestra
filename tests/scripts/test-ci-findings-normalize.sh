#!/usr/bin/env bash
# tests/scripts/test-ci-findings-normalize.sh
# RED tests for plugins/dso/scripts/lib/ci-findings-normalize.sh
#
# Tests 1-5 (Tier 1) are GREEN. Tests 6-13 (Tier 2/3/4 + _fetch_ci_log) are RED
# because _normalize_tier2/3/4 and _fetch_ci_log are not yet implemented.
# They turn GREEN once those functions are added to ci-findings-normalize.sh.
#
# Tests:
#   1. t_normalize_tier1_output_schema              — output has schema_version=1, tier, findings
#   2. t_normalize_tier1_schema_conformance         — findings entries have severity/description/file
#   3. t_normalize_tier1_missing_findings_key_returns_nonzero — missing findings key → non-zero exit
#   4. t_normalize_tier1_empty_findings_array_emits_valid_schema — empty findings → valid JSON
#   5. t_lib_mode_guard                             — CI_FINDINGS_LIB_MODE=1 defines func, no stdout
#   6. t_normalize_tier2_output_schema              — tier2 output: schema_version=1, tier=test
#   7. t_normalize_tier2_missing_input_exits_3      — empty input → exit 3 (ARTIFACT_MISSING)
#   8. t_normalize_tier2_log_parses_pytest_output   — pytest FAILED line → findings entry
#   9. t_normalize_tier3_output_schema              — tier3 output: schema_version=1, tier=lint
#  10. t_normalize_tier3_missing_input_exits_3      — empty input → exit 3
#  11. t_normalize_tier4_output_schema              — tier4 output: schema_version=1, tier=other
#  12. t_normalize_tier4_missing_input_exits_3      — empty input → exit 3
#  13. t_fetch_ci_log_calls_gh_run_view             — _fetch_ci_log writes gh output to file
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

    _input="$(mktemp "${TMPDIR:-/tmp}/findings-input.XXXXXX")"
    _output="$(mktemp "${TMPDIR:-/tmp}/findings-output.XXXXXX")"
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

    _input="$(mktemp "${TMPDIR:-/tmp}/findings-input.XXXXXX")"
    _output="$(mktemp "${TMPDIR:-/tmp}/findings-output.XXXXXX")"
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

    _tmpf="$(mktemp "${TMPDIR:-/tmp}/no-findings.XXXXXX")"
    _tmpout="$(mktemp "${TMPDIR:-/tmp}/out.XXXXXX")"
    _ec_file="$(mktemp "${TMPDIR:-/tmp}/ec.XXXXXX")"
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

    _input="$(mktemp "${TMPDIR:-/tmp}/findings-empty.XXXXXX")"
    _output="$(mktemp "${TMPDIR:-/tmp}/findings-out.XXXXXX")"
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
# Test 6: t_normalize_tier2_output_schema
# Given: pytest failure text in a fixture file
# When:  _normalize_tier2 is called
# Then:  output JSON has schema_version=1, tier="test", findings array
# ---------------------------------------------------------------------------
t_normalize_tier2_output_schema() {
    local _input _output _result _check

    _input="$(mktemp "${TMPDIR:-/tmp}/tier2-input.XXXXXX")"
    _output="$(mktemp "${TMPDIR:-/tmp}/tier2-output.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_input' '$_output'" RETURN

    printf 'FAILED tests/foo.py::test_bar - AssertionError: expected 1, got 2\n' > "$_input"

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT"
        _normalize_tier2 "$_input" "$_output"
    ) 2>/dev/null || true

    _result="$(cat "$_output" 2>/dev/null || echo '')"

    _check="$(echo "$_result" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ok = (
        d.get("schema_version") == 1 and
        d.get("tier") == "test" and
        isinstance(d.get("findings"), list)
    )
    print("ok" if ok else "fail:schema_version=%s tier=%s findings=%s" % (d.get("schema_version"), d.get("tier"), type(d.get("findings")).__name__))
except Exception as e:
    print("invalid-json:" + str(e))
' 2>/dev/null || echo 'parse-error')"

    assert_eq "t_normalize_tier2_output_schema: schema_version=1 tier=test findings=[]" "ok" "$_check"
}
t_normalize_tier2_output_schema

# ---------------------------------------------------------------------------
# Test 6b: t_normalize_tier1_missing_input_exits_3
# Given: empty string passed as input (and a non-existent file path)
# When:  _normalize_tier1 "" "$_output" is called
# Then:  exit code is 3 (ARTIFACT_MISSING) — parity with tiers 2/3/4
# ---------------------------------------------------------------------------
t_normalize_tier1_missing_input_exits_3() {
    local _output _ec_file _exit_code
    _output="$(mktemp "${TMPDIR:-/tmp}/tier1-out.XXXXXX")"
    _ec_file="$(mktemp "${TMPDIR:-/tmp}/tier1-ec.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_output' '$_ec_file'" RETURN

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT" 2>/dev/null || { echo "source-failed" > "$_ec_file"; exit 0; }
        _normalize_tier1 "" "$_output" 2>/dev/null
        echo "$?" > "$_ec_file"
    ) 2>/dev/null || true

    _exit_code="$(cat "$_ec_file" 2>/dev/null || echo 'unset')"
    assert_eq "t_normalize_tier1_missing_input_exits_3: empty input → exit 3" "3" "$_exit_code"
}
t_normalize_tier1_missing_input_exits_3

# ---------------------------------------------------------------------------
# Test 7: t_normalize_tier2_missing_input_exits_3
# Given: empty string passed as input
# When:  _normalize_tier2 "" "$_output" is called
# Then:  exit code is 3 (ARTIFACT_MISSING)
# ---------------------------------------------------------------------------
t_normalize_tier2_missing_input_exits_3() {
    local _output _ec_file _exit_code

    _output="$(mktemp "${TMPDIR:-/tmp}/tier2-out.XXXXXX")"
    _ec_file="$(mktemp "${TMPDIR:-/tmp}/tier2-ec.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_output' '$_ec_file'" RETURN

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT" 2>/dev/null || { echo "source-failed" > "$_ec_file"; exit 0; }
        _normalize_tier2 "" "$_output" 2>/dev/null
        echo "$?" > "$_ec_file"
    ) 2>/dev/null || true

    _exit_code="$(cat "$_ec_file" 2>/dev/null || echo 'unset')"

    assert_eq "t_normalize_tier2_missing_input_exits_3: empty input → exit 3" "3" "$_exit_code"
}
t_normalize_tier2_missing_input_exits_3

# ---------------------------------------------------------------------------
# Test 8: t_normalize_tier2_log_parses_pytest_output
# Given: pytest failure text with path tests/foo.py
# When:  _normalize_tier2 is called
# Then:  at least one findings entry has file containing "tests/foo.py"
# ---------------------------------------------------------------------------
t_normalize_tier2_log_parses_pytest_output() {
    local _input _output _result _found

    _input="$(mktemp "${TMPDIR:-/tmp}/tier2-pytest.XXXXXX")"
    _output="$(mktemp "${TMPDIR:-/tmp}/tier2-pytest-out.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_input' '$_output'" RETURN

    printf 'FAILED tests/foo.py::test_bar - AssertionError: expected 1, got 2\n' > "$_input"

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT"
        _normalize_tier2 "$_input" "$_output"
    ) 2>/dev/null || true

    _result="$(cat "$_output" 2>/dev/null || echo '')"

    _found="$(echo "$_result" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    findings = d.get("findings", [])
    if any("tests/foo.py" in str(f.get("file", "")) for f in findings):
        print("found")
    else:
        print("not-found:findings=%s" % json.dumps(findings))
except Exception as e:
    print("invalid-json:" + str(e))
' 2>/dev/null || echo 'parse-error')"

    assert_eq "t_normalize_tier2_log_parses_pytest_output: findings entry contains tests/foo.py" "found" "$_found"
}
t_normalize_tier2_log_parses_pytest_output

# ---------------------------------------------------------------------------
# Test 9: t_normalize_tier3_output_schema
# Given: ruff lint output in a fixture file
# When:  _normalize_tier3 is called
# Then:  output JSON has schema_version=1, tier="lint", findings array
# ---------------------------------------------------------------------------
t_normalize_tier3_output_schema() {
    local _input _output _result _check

    _input="$(mktemp "${TMPDIR:-/tmp}/tier3-input.XXXXXX")"
    _output="$(mktemp "${TMPDIR:-/tmp}/tier3-output.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_input' '$_output'" RETURN

    printf 'src/auth.py:42:5: E501 line too long (90 > 88 characters)\n' > "$_input"

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT"
        _normalize_tier3 "$_input" "$_output"
    ) 2>/dev/null || true

    _result="$(cat "$_output" 2>/dev/null || echo '')"

    _check="$(echo "$_result" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ok = (
        d.get("schema_version") == 1 and
        d.get("tier") == "lint" and
        isinstance(d.get("findings"), list)
    )
    print("ok" if ok else "fail:schema_version=%s tier=%s findings=%s" % (d.get("schema_version"), d.get("tier"), type(d.get("findings")).__name__))
except Exception as e:
    print("invalid-json:" + str(e))
' 2>/dev/null || echo 'parse-error')"

    assert_eq "t_normalize_tier3_output_schema: schema_version=1 tier=lint findings=[]" "ok" "$_check"
}
t_normalize_tier3_output_schema

# ---------------------------------------------------------------------------
# Test 10: t_normalize_tier3_missing_input_exits_3
# Given: empty string passed as input
# When:  _normalize_tier3 "" "$_output" is called
# Then:  exit code is 3 (ARTIFACT_MISSING)
# ---------------------------------------------------------------------------
t_normalize_tier3_missing_input_exits_3() {
    local _output _ec_file _exit_code

    _output="$(mktemp "${TMPDIR:-/tmp}/tier3-out.XXXXXX")"
    _ec_file="$(mktemp "${TMPDIR:-/tmp}/tier3-ec.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_output' '$_ec_file'" RETURN

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT" 2>/dev/null || { echo "source-failed" > "$_ec_file"; exit 0; }
        _normalize_tier3 "" "$_output" 2>/dev/null
        echo "$?" > "$_ec_file"
    ) 2>/dev/null || true

    _exit_code="$(cat "$_ec_file" 2>/dev/null || echo 'unset')"

    assert_eq "t_normalize_tier3_missing_input_exits_3: empty input → exit 3" "3" "$_exit_code"
}
t_normalize_tier3_missing_input_exits_3

# ---------------------------------------------------------------------------
# Test 11: t_normalize_tier4_output_schema
# Given: any plain text in a fixture file
# When:  _normalize_tier4 is called
# Then:  output JSON has schema_version=1, tier="other", findings array
# ---------------------------------------------------------------------------
t_normalize_tier4_output_schema() {
    local _input _output _result _check

    _input="$(mktemp "${TMPDIR:-/tmp}/tier4-input.XXXXXX")"
    _output="$(mktemp "${TMPDIR:-/tmp}/tier4-output.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_input' '$_output'" RETURN

    printf 'Error: something failed\n' > "$_input"

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT"
        _normalize_tier4 "$_input" "$_output"
    ) 2>/dev/null || true

    _result="$(cat "$_output" 2>/dev/null || echo '')"

    _check="$(echo "$_result" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ok = (
        d.get("schema_version") == 1 and
        d.get("tier") == "other" and
        isinstance(d.get("findings"), list)
    )
    print("ok" if ok else "fail:schema_version=%s tier=%s findings=%s" % (d.get("schema_version"), d.get("tier"), type(d.get("findings")).__name__))
except Exception as e:
    print("invalid-json:" + str(e))
' 2>/dev/null || echo 'parse-error')"

    assert_eq "t_normalize_tier4_output_schema: schema_version=1 tier=other findings=[]" "ok" "$_check"
}
t_normalize_tier4_output_schema

# ---------------------------------------------------------------------------
# Test 12: t_normalize_tier4_missing_input_exits_3
# Given: empty string passed as input
# When:  _normalize_tier4 "" "$_output" is called
# Then:  exit code is 3 (ARTIFACT_MISSING)
# ---------------------------------------------------------------------------
t_normalize_tier4_missing_input_exits_3() {
    local _output _ec_file _exit_code

    _output="$(mktemp "${TMPDIR:-/tmp}/tier4-out.XXXXXX")"
    _ec_file="$(mktemp "${TMPDIR:-/tmp}/tier4-ec.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_output' '$_ec_file'" RETURN

    (
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT" 2>/dev/null || { echo "source-failed" > "$_ec_file"; exit 0; }
        _normalize_tier4 "" "$_output" 2>/dev/null
        echo "$?" > "$_ec_file"
    ) 2>/dev/null || true

    _exit_code="$(cat "$_ec_file" 2>/dev/null || echo 'unset')"

    assert_eq "t_normalize_tier4_missing_input_exits_3: empty input → exit 3" "3" "$_exit_code"
}
t_normalize_tier4_missing_input_exits_3

# ---------------------------------------------------------------------------
# Test 13: t_fetch_ci_log_calls_gh_run_view
# Given: gh overridden as a bash function that echoes "SIMULATED LOG"
# When:  _fetch_ci_log "12345" "$_output" is called
# Then:  output file contains "SIMULATED LOG" and exit code is 0
# ---------------------------------------------------------------------------
t_fetch_ci_log_calls_gh_run_view() {
    local _output _ec_file _exit_code _content

    _output="$(mktemp "${TMPDIR:-/tmp}/fetch-ci-out.XXXXXX")"
    _ec_file="$(mktemp "${TMPDIR:-/tmp}/fetch-ci-ec.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$_output' '$_ec_file'" RETURN

    # Export a stub gh function that writes predictable output and exits 0.
    # The stub must be visible inside the subshell that sources the lib.
    (
        # shellcheck disable=SC2329  # invoked indirectly by _fetch_ci_log inside the sourced lib
        gh() { echo "SIMULATED LOG"; return 0; }
        export -f gh
        CI_FINDINGS_LIB_MODE=1 source "$LIB_SCRIPT" 2>/dev/null || { echo "source-failed" > "$_ec_file"; exit 0; }
        _fetch_ci_log "12345" "$_output" 2>/dev/null
        echo "$?" > "$_ec_file"
    ) 2>/dev/null || true

    _exit_code="$(cat "$_ec_file" 2>/dev/null || echo 'unset')"
    _content="$(cat "$_output" 2>/dev/null || echo '')"

    assert_eq "t_fetch_ci_log_calls_gh_run_view: exit code 0 on gh success" "0" "$_exit_code"
    assert_contains "t_fetch_ci_log_calls_gh_run_view: output file contains SIMULATED LOG" "SIMULATED LOG" "$_content"
}
t_fetch_ci_log_calls_gh_run_view

# ---------------------------------------------------------------------------
print_summary
