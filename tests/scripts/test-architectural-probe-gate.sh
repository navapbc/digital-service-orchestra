#!/usr/bin/env bash
# tests/scripts/test-architectural-probe-gate.sh
# Behavioral contract tests for plugins/dso/scripts/run-architectural-probe.sh
#
# Test cases (per S5 story):
#   1. class:architectural + non-empty probe output → gate exits 0
#   2. class:behavioral → probe NOT dispatched → exits 0 immediately (no-op)
#   3. class:architectural + empty probe output → gate exits 1
#   4. class:architectural + probe script exits non-zero (empty DSO_PROBE_TEST_OUTPUT) → gate exits 1
#
# For test control, DSO_PROBE_TEST_OUTPUT env var controls what the probe writes:
#   - non-empty value  → probe writes that content (PASS scenario)
#   - empty string ""  → probe writes empty file (FAIL scenario)
#   - unset            → probe uses default non-empty stub (PASS scenario)
#
# All tests FAIL (RED) until run-architectural-probe.sh is created.
#
# Usage: bash tests/scripts/test-architectural-probe-gate.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/run-architectural-probe.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-architectural-probe-gate.sh ==="

# ── Helper: make a temp output file path ────────────────────────────────────
_make_tmpfile() {
    mktemp "${TMPDIR:-/tmp}/arch-probe-test.XXXXXX"
}

# Deleted: test_gate_script_exists — solo existence/executable check. The
# behavioral tests below invoke $GATE_SCRIPT; if it is missing or not
# executable they fail with a more informative error than a wrapped
# `assert_eq "exists" "missing"`.

# ── test_architectural_class_with_nonempty_output_exits_0 ────────────────────
# Contract: When epic-class is class:architectural and DSO_PROBE_TEST_OUTPUT is
# non-empty, run-architectural-probe.sh must write the probe content to --output-file
# and exit 0 (gate passes).
# RED: script does not exist → exits non-zero or command not found.
test_architectural_class_with_nonempty_output_exits_0() {
    _snapshot_fail
    local tmpfile
    tmpfile=$(_make_tmpfile)
    # Remove the file so the script creates it fresh
    rm -f "$tmpfile"

    local exit_code=0
    if [[ -x "$GATE_SCRIPT" ]]; then
        DSO_PROBE_TEST_OUTPUT="# Architectural Probe: End-to-End Test Scaffold

## Epic Integration Harness

Integration harness content for the architectural epic.

## Self-Use Compatibility

Sprint execution requires only existing infrastructure; no bootstrap gap." \
            bash "$GATE_SCRIPT" \
                --epic-class="class:architectural" \
                --output-file="$tmpfile" \
            && exit_code=0 || exit_code=$?
    else
        exit_code=127
    fi

    assert_eq "test_architectural_class_with_nonempty_output_exits_0: exit code is 0" "0" "$exit_code"

    # Output file must exist and be non-empty
    if [[ -f "$tmpfile" && -s "$tmpfile" ]]; then
        assert_eq "test_architectural_class_with_nonempty_output_exits_0: output file is non-empty" "nonempty" "nonempty"
    else
        assert_eq "test_architectural_class_with_nonempty_output_exits_0: output file must be non-empty" "nonempty" "empty-or-missing"
    fi

    rm -f "$tmpfile"
    assert_pass_if_clean "test_architectural_class_with_nonempty_output_exits_0"
}

# ── test_behavioral_class_is_noop_exits_0 ────────────────────────────────────
# Contract: When epic-class is class:behavioral, the probe is NOT dispatched.
# Script must exit 0 immediately without creating the output file.
# RED: script does not exist → command not found.
test_behavioral_class_is_noop_exits_0() {
    _snapshot_fail
    local tmpfile
    tmpfile=$(_make_tmpfile)
    # Remove so we can detect if it gets created
    rm -f "$tmpfile"

    local exit_code=0
    if [[ -x "$GATE_SCRIPT" ]]; then
        bash "$GATE_SCRIPT" \
            --epic-class="class:behavioral" \
            --output-file="$tmpfile" \
        && exit_code=0 || exit_code=$?
    else
        exit_code=127
    fi

    assert_eq "test_behavioral_class_is_noop_exits_0: exit code is 0" "0" "$exit_code"

    # Output file must NOT be created (no probe dispatch for behavioral)
    if [[ ! -f "$tmpfile" ]]; then
        assert_eq "test_behavioral_class_is_noop_exits_0: output file not created (no-op)" "not_created" "not_created"
    else
        assert_eq "test_behavioral_class_is_noop_exits_0: output file must not be created for behavioral class" "not_created" "created"
        rm -f "$tmpfile"
    fi

    assert_pass_if_clean "test_behavioral_class_is_noop_exits_0"
}

# ── test_architectural_class_with_empty_output_exits_1 ───────────────────────
# Contract: When epic-class is class:architectural but DSO_PROBE_TEST_OUTPUT is
# empty string, the probe writes an empty file and the gate must exit 1.
# RED: script does not exist → command not found.
test_architectural_class_with_empty_output_exits_1() {
    _snapshot_fail
    local tmpfile
    tmpfile=$(_make_tmpfile)
    rm -f "$tmpfile"

    local exit_code=0
    if [[ -x "$GATE_SCRIPT" ]]; then
        DSO_PROBE_TEST_OUTPUT="" \
            bash "$GATE_SCRIPT" \
                --epic-class="class:architectural" \
                --output-file="$tmpfile" \
            && exit_code=0 || exit_code=$?
    else
        exit_code=127
    fi

    assert_eq "test_architectural_class_with_empty_output_exits_1: exit code is 1" "1" "$exit_code"

    rm -f "$tmpfile"
    assert_pass_if_clean "test_architectural_class_with_empty_output_exits_1"
}

# ── test_architectural_class_integration_class_is_noop ───────────────────────
# Contract: When epic-class is class:integration (not class:architectural),
# probe is NOT dispatched and script exits 0 (no-op for non-architectural classes).
# RED: script does not exist → command not found.
test_non_architectural_class_is_noop_exits_0() {
    _snapshot_fail
    local tmpfile
    tmpfile=$(_make_tmpfile)
    rm -f "$tmpfile"

    local exit_code=0
    if [[ -x "$GATE_SCRIPT" ]]; then
        bash "$GATE_SCRIPT" \
            --epic-class="class:integration" \
            --output-file="$tmpfile" \
        && exit_code=0 || exit_code=$?
    else
        exit_code=127
    fi

    assert_eq "test_non_architectural_class_is_noop_exits_0: exit code is 0 for class:integration" "0" "$exit_code"

    # Output file must NOT be created (no-op for non-architectural)
    if [[ ! -f "$tmpfile" ]]; then
        assert_eq "test_non_architectural_class_is_noop_exits_0: output file not created for non-architectural class" "not_created" "not_created"
    else
        assert_eq "test_non_architectural_class_is_noop_exits_0: output file must not be created for class:integration" "not_created" "created"
        rm -f "$tmpfile"
    fi

    assert_pass_if_clean "test_non_architectural_class_is_noop_exits_0"
}

# ── test_default_stub_written_when_env_unset ─────────────────────────────────
# Contract: When epic-class is class:architectural and DSO_PROBE_TEST_OUTPUT is
# NOT set, the script must write a default non-empty scaffold stub to output-file
# and exit 0. This ensures the script produces useful output in real (non-test) usage.
# RED: script does not exist → command not found.
test_default_stub_written_when_env_unset() {
    _snapshot_fail
    local tmpfile
    tmpfile=$(_make_tmpfile)
    rm -f "$tmpfile"

    local exit_code=0
    if [[ -x "$GATE_SCRIPT" ]]; then
        # Explicitly unset the env var so the script uses its built-in default
        env -u DSO_PROBE_TEST_OUTPUT bash "$GATE_SCRIPT" \
            --epic-class="class:architectural" \
            --output-file="$tmpfile" \
        && exit_code=0 || exit_code=$?
    else
        exit_code=127
    fi

    assert_eq "test_default_stub_written_when_env_unset: exit code is 0" "0" "$exit_code"

    if [[ -f "$tmpfile" && -s "$tmpfile" ]]; then
        assert_eq "test_default_stub_written_when_env_unset: output file is non-empty (default stub)" "nonempty" "nonempty"
    else
        assert_eq "test_default_stub_written_when_env_unset: output file must be non-empty with default stub" "nonempty" "empty-or-missing"
    fi

    rm -f "$tmpfile"
    assert_pass_if_clean "test_default_stub_written_when_env_unset"
}

# ── test_probe_output_missing_self_use_section_exits_1 ───────────────────────
# Contract: When epic-class is class:architectural and DSO_PROBE_TEST_OUTPUT is
# non-empty but does NOT contain "## Self-Use Compatibility", the gate must exit 1.
# This ensures the brainstorm content-level validation is enforced — a probe that
# never asks "can this epic's own sprint run on the architecture it delivers?"
# must be rejected before scrutiny.
test_probe_output_missing_self_use_section_exits_1() {
    _snapshot_fail
    local tmpfile
    tmpfile=$(_make_tmpfile)
    rm -f "$tmpfile"

    local exit_code=0
    if [[ -x "$GATE_SCRIPT" ]]; then
        DSO_PROBE_TEST_OUTPUT="# Architectural Probe: Test Scaffold

## Epic Integration Harness

This is a non-empty probe output that lacks the self-use compatibility section.

### End-to-End Test Strategy

- [ ] Identify system boundaries" \
            bash "$GATE_SCRIPT" \
                --epic-class="class:architectural" \
                --output-file="$tmpfile" \
            && exit_code=0 || exit_code=$?
    else
        exit_code=127
    fi

    assert_eq "test_probe_output_missing_self_use_section_exits_1: exit code is 1 when self-use section absent" "1" "$exit_code"

    rm -f "$tmpfile"
    assert_pass_if_clean "test_probe_output_missing_self_use_section_exits_1"
}

# ── test_probe_output_with_self_use_section_exits_0 ──────────────────────────
# Contract: When epic-class is class:architectural and DSO_PROBE_TEST_OUTPUT
# contains "## Self-Use Compatibility", the gate must exit 0.
test_probe_output_with_self_use_section_exits_0() {
    _snapshot_fail
    local tmpfile
    tmpfile=$(_make_tmpfile)
    rm -f "$tmpfile"

    local exit_code=0
    if [[ -x "$GATE_SCRIPT" ]]; then
        DSO_PROBE_TEST_OUTPUT="# Architectural Probe: Test Scaffold

## Epic Integration Harness

Integration harness content here.

## Self-Use Compatibility

Sprint execution requires only existing infrastructure; no bootstrap gap." \
            bash "$GATE_SCRIPT" \
                --epic-class="class:architectural" \
                --output-file="$tmpfile" \
            && exit_code=0 || exit_code=$?
    else
        exit_code=127
    fi

    assert_eq "test_probe_output_with_self_use_section_exits_0: exit code is 0 when self-use section present" "0" "$exit_code"

    rm -f "$tmpfile"
    assert_pass_if_clean "test_probe_output_with_self_use_section_exits_0"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_architectural_class_with_nonempty_output_exits_0
test_behavioral_class_is_noop_exits_0
test_architectural_class_with_empty_output_exits_1
test_non_architectural_class_is_noop_exits_0
test_default_stub_written_when_env_unset
test_probe_output_missing_self_use_section_exits_1
test_probe_output_with_self_use_section_exits_0

print_summary
