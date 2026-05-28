#!/usr/bin/env bash
# tests/scripts/test-pil-handoff-integration.sh
# RED integration tests for plugins/dso/scripts/validate-pil-handoff.sh
#
# Tests cover the brainstorm-emit → preplanning-consume PIL handoff boundary:
#   1. Valid PIL JSON with all required fields → exits 0
#   2. PIL JSON missing required field (no epicId) → exits 1 with JSON error
#   3. PIL JSON with schema_version mismatch (schema_version=99 is valid; this
#      tests schema_version=0, which is < 1 and should fail)
#   4. PIL JSON with all required fields + extra optional fields → exits 0
#      (forward-compat: unknown fields must not cause failure)
#
# Interface under test:
#   validate-pil-handoff.sh  [--pil-file=<path>]  (also accepts JSON via stdin)
#   Required fields: schema_version (integer >= 1), generatedAt (non-empty string),
#                    epicId (non-empty string)
#   Exit 0: valid; Exit 1: JSON error on stderr
#
# Usage: bash tests/scripts/test-pil-handoff-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: RED:5f83-058f-eae6-4047

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/validate-pil-handoff.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-pil-handoff-integration.sh ==="

# ── test_valid_pil_with_all_required_fields_exits_0 ──────────────────────────
# A PIL payload with all three required fields (schema_version, generatedAt, epicId)
# must exit 0 (valid).
test_valid_pil_with_all_required_fields_exits_0() {
    _snapshot_fail
    local rc=0
    local payload='{"schema_version":2,"generatedAt":"2026-05-18T17:40:00Z","epicId":"f9de-b7d9-c23e-4f5b"}'
    echo "$payload" | bash "$VALIDATE_SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_valid_pil_with_all_required_fields_exits_0: exit code is 0 for valid payload" \
        "0" "$rc"
    assert_pass_if_clean "test_valid_pil_with_all_required_fields_exits_0"
}

# ── test_missing_epicId_exits_1_with_json_error ───────────────────────────────
# A PIL payload missing the epicId field must exit 1 and write a JSON error to
# stderr (contract: required field absent).
test_missing_epicId_exits_1_with_json_error() {
    _snapshot_fail
    local rc=0
    local payload='{"schema_version":2,"generatedAt":"2026-05-18T17:40:00Z"}'
    local stderr_out
    stderr_out=$(echo "$payload" | bash "$VALIDATE_SCRIPT" 2>&1) || rc=$?
    assert_eq "test_missing_epicId_exits_1_with_json_error: exit code is 1 for missing epicId" \
        "1" "$rc"
    assert_contains "test_missing_epicId_exits_1_with_json_error: stderr contains 'error'" \
        '"error"' "$stderr_out"
    assert_contains "test_missing_epicId_exits_1_with_json_error: stderr mentions epicId" \
        "epicId" "$stderr_out"
    assert_pass_if_clean "test_missing_epicId_exits_1_with_json_error"
}

# ── test_invalid_schema_version_exits_1 ──────────────────────────────────────
# A PIL payload with schema_version=0 (< 1) must exit 1 — version 0 is below
# the minimum supported version.
test_invalid_schema_version_exits_1() {
    _snapshot_fail
    local rc=0
    local payload='{"schema_version":0,"generatedAt":"2026-05-18T17:40:00Z","epicId":"f9de-b7d9-c23e-4f5b"}'
    local stderr_out
    stderr_out=$(echo "$payload" | bash "$VALIDATE_SCRIPT" 2>&1) || rc=$?
    assert_eq "test_invalid_schema_version_exits_1: exit code is 1 for schema_version=0" \
        "1" "$rc"
    assert_contains "test_invalid_schema_version_exits_1: stderr contains 'error'" \
        '"error"' "$stderr_out"
    assert_contains "test_invalid_schema_version_exits_1: stderr mentions schema_version" \
        "schema_version" "$stderr_out"
    assert_pass_if_clean "test_invalid_schema_version_exits_1"
}

# ── test_extra_optional_fields_exits_0 ───────────────────────────────────────
# A PIL payload with all required fields PLUS extra optional fields must exit 0.
# Forward-compat contract: unknown fields must not cause failure.
test_extra_optional_fields_exits_0() {
    _snapshot_fail
    local rc=0
    local payload
    payload=$(cat <<'PAYLOAD'
{
  "schema_version": 2,
  "generatedAt": "2026-05-18T17:40:00Z",
  "epicId": "f9de-b7d9-c23e-4f5b",
  "version": 1,
  "generatedBy": "preplanning",
  "unknownFutureField": "should be ignored",
  "epic": {"title": "Test epic", "successCriteria": ["SC1"]},
  "stories": [],
  "storyDashboard": {"totalStories": 0, "uiStories": 0, "criticalPath": []}
}
PAYLOAD
)
    echo "$payload" | bash "$VALIDATE_SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_extra_optional_fields_exits_0: exit code is 0 with extra fields (forward-compat)" \
        "0" "$rc"
    assert_pass_if_clean "test_extra_optional_fields_exits_0"
}

# ── test_pil_file_flag_exits_0 ────────────────────────────────────────────────
# Validate that the --pil-file=<path> interface works in addition to stdin.
test_pil_file_flag_exits_0() {
    _snapshot_fail
    local rc=0
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-pil-handoff.XXXXXX")
    printf '{"schema_version":1,"generatedAt":"2026-05-18T17:40:00Z","epicId":"abc-123"}' > "$tmpfile"
    bash "$VALIDATE_SCRIPT" --pil-file="$tmpfile" 2>/dev/null || rc=$?
    rm -f "$tmpfile"
    assert_eq "test_pil_file_flag_exits_0: --pil-file flag works; exit code is 0" \
        "0" "$rc"
    assert_pass_if_clean "test_pil_file_flag_exits_0"
}

# ── test_missing_generatedAt_exits_1 ─────────────────────────────────────────
# A PIL payload missing the generatedAt field must exit 1.
test_missing_generatedAt_exits_1() {
    _snapshot_fail
    local rc=0
    local payload='{"schema_version":2,"epicId":"f9de-b7d9-c23e-4f5b"}'
    local stderr_out
    stderr_out=$(echo "$payload" | bash "$VALIDATE_SCRIPT" 2>&1) || rc=$?
    assert_eq "test_missing_generatedAt_exits_1: exit code is 1 for missing generatedAt" \
        "1" "$rc"
    assert_contains "test_missing_generatedAt_exits_1: stderr contains 'error'" \
        '"error"' "$stderr_out"
    assert_contains "test_missing_generatedAt_exits_1: stderr mentions generatedAt" \
        "generatedAt" "$stderr_out"
    assert_pass_if_clean "test_missing_generatedAt_exits_1"
}

# ── test_missing_schema_version_exits_1 ──────────────────────────────────────
# A PIL payload missing the schema_version field must exit 1.
test_missing_schema_version_exits_1() {
    _snapshot_fail
    local rc=0
    local payload='{"generatedAt":"2026-05-18T17:40:00Z","epicId":"f9de-b7d9-c23e-4f5b"}'
    local stderr_out
    stderr_out=$(echo "$payload" | bash "$VALIDATE_SCRIPT" 2>&1) || rc=$?
    assert_eq "test_missing_schema_version_exits_1: exit code is 1 for missing schema_version" \
        "1" "$rc"
    assert_contains "test_missing_schema_version_exits_1: stderr contains 'error'" \
        '"error"' "$stderr_out"
    assert_contains "test_missing_schema_version_exits_1: stderr mentions schema_version" \
        "schema_version" "$stderr_out"
    assert_pass_if_clean "test_missing_schema_version_exits_1"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_valid_pil_with_all_required_fields_exits_0
test_missing_epicId_exits_1_with_json_error
test_invalid_schema_version_exits_1
test_extra_optional_fields_exits_0
test_pil_file_flag_exits_0
test_missing_generatedAt_exits_1
test_missing_schema_version_exits_1

print_summary
