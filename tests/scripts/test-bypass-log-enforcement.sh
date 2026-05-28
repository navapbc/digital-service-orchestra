#!/usr/bin/env bash
# tests/scripts/test-bypass-log-enforcement.sh
# RED test suite for plugins/dso/scripts/bypass-log-check.sh
# These tests validate that the bypass-log-check.sh script enforces
# structured bypass log entries on gate overrides.
#
# Interface tested:
#   bypass-log-check.sh --artifact-file=<path>
#   gate_overrides array: [{gate_name, bypass_log: {rationale, caller_context}}]
#
# Usage: bash tests/scripts/test-bypass-log-enforcement.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/bypass-log-check.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bypass-log-enforcement.sh ==="

# Helper: write JSON to a temp file and return its path
make_artifact() {
    local json="$1"
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/bypass-log-test-artifact.XXXXXX")
    printf '%s' "$json" > "$tmpfile"
    echo "$tmpfile"
}

# ── TC1: override with valid bypass_log → exit 0 ────────────────────────────
test_override_with_valid_bypass_log_exits_0() {
    local artifact
    artifact=$(make_artifact '{
        "gate_overrides": [
            {
                "gate_name": "test-gate",
                "bypass_log": {
                    "rationale": "Manual override approved by team lead",
                    "caller_context": "sprint orchestrator Phase I"
                }
            }
        ]
    }')
    local exit_code
    bash "$SCRIPT" "--artifact-file=$artifact" >/dev/null 2>&1
    exit_code=$?
    rm -f "$artifact"
    assert_eq "TC1: override with valid bypass_log exits 0" "0" "$exit_code"
}

# ── TC2: override with NO bypass_log field → exit 1 ─────────────────────────
test_override_with_no_bypass_log_exits_1() {
    local artifact
    artifact=$(make_artifact '{
        "gate_overrides": [
            {
                "gate_name": "test-gate"
            }
        ]
    }')
    local exit_code
    bash "$SCRIPT" "--artifact-file=$artifact" >/dev/null 2>&1
    exit_code=$?
    rm -f "$artifact"
    assert_eq "TC2: override without bypass_log exits 1" "1" "$exit_code"
}

# ── TC3: override + bypass_log but missing rationale → exit 1 ───────────────
test_override_bypass_log_missing_rationale_exits_1() {
    local artifact
    artifact=$(make_artifact '{
        "gate_overrides": [
            {
                "gate_name": "test-gate",
                "bypass_log": {
                    "caller_context": "sprint orchestrator Phase I"
                }
            }
        ]
    }')
    local exit_code
    bash "$SCRIPT" "--artifact-file=$artifact" >/dev/null 2>&1
    exit_code=$?
    rm -f "$artifact"
    assert_eq "TC3: bypass_log missing rationale exits 1" "1" "$exit_code"
}

# ── TC4: override + bypass_log but missing caller_context → exit 1 ──────────
test_override_bypass_log_missing_caller_context_exits_1() {
    local artifact
    artifact=$(make_artifact '{
        "gate_overrides": [
            {
                "gate_name": "test-gate",
                "bypass_log": {
                    "rationale": "Approved override for emergency fix"
                }
            }
        ]
    }')
    local exit_code
    bash "$SCRIPT" "--artifact-file=$artifact" >/dev/null 2>&1
    exit_code=$?
    rm -f "$artifact"
    assert_eq "TC4: bypass_log missing caller_context exits 1" "1" "$exit_code"
}

# ── TC5: artifact with NO overrides → exit 0 (no-op) ────────────────────────
test_no_overrides_exits_0() {
    local artifact
    artifact=$(make_artifact '{
        "gate_overrides": []
    }')
    local exit_code
    bash "$SCRIPT" "--artifact-file=$artifact" >/dev/null 2>&1
    exit_code=$?
    rm -f "$artifact"
    assert_eq "TC5: no gate_overrides exits 0" "0" "$exit_code"
}

# ── TC5b: artifact with no gate_overrides key at all → exit 0 (no-op) ───────
test_no_overrides_key_exits_0() {
    local artifact
    artifact=$(make_artifact '{
        "other_field": "some value"
    }')
    local exit_code
    bash "$SCRIPT" "--artifact-file=$artifact" >/dev/null 2>&1
    exit_code=$?
    rm -f "$artifact"
    assert_eq "TC5b: missing gate_overrides key exits 0" "0" "$exit_code"
}

# ── Run tests ────────────────────────────────────────────────────────────────
test_override_with_valid_bypass_log_exits_0
test_override_with_no_bypass_log_exits_1
test_override_bypass_log_missing_rationale_exits_1
test_override_bypass_log_missing_caller_context_exits_1
test_no_overrides_exits_0
test_no_overrides_key_exits_0

print_summary
