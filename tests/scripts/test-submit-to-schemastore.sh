#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-submit-to-schemastore.sh
# Tests for lockpick-workflow/scripts/submit-to-schemastore.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-submit-to-schemastore.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$PLUGIN_ROOT/scripts/submit-to-schemastore.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-submit-to-schemastore.sh ==="

# ── test_schemastore_script_exists ────────────────────────────────────────────
if [[ -f "$SCRIPT" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_schemastore_script_exists" "exists" "$actual"

# ── test_schemastore_no_syntax_errors ─────────────────────────────────────────
if bash -n "$SCRIPT" 2>/dev/null; then
    actual="valid"
else
    actual="syntax_error"
fi
assert_eq "test_schemastore_no_syntax_errors" "valid" "$actual"

# ── test_schemastore_rejects_missing_file ─────────────────────────────────────
exit_code=0
bash "$SCRIPT" "/tmp/nonexistent-schema-$$.json" 2>/dev/null || exit_code=$?
assert_eq "test_schemastore_rejects_missing_file" "1" "$exit_code"

# ── test_schemastore_rejects_invalid_json ─────────────────────────────────────
TEMP_BAD_JSON=$(mktemp)
_CLEANUP_DIRS+=("$TEMP_BAD_JSON")
echo "not json {{{" > "$TEMP_BAD_JSON"
exit_code=0
bash "$SCRIPT" "$TEMP_BAD_JSON" 2>/dev/null || exit_code=$?
rm -f "$TEMP_BAD_JSON"
assert_eq "test_schemastore_rejects_invalid_json" "1" "$exit_code"

# ── test_schemastore_rejects_missing_id ───────────────────────────────────────
TEMP_NO_ID=$(mktemp)
_CLEANUP_DIRS+=("$TEMP_NO_ID")
echo '{"type": "object"}' > "$TEMP_NO_ID"
exit_code=0
bash "$SCRIPT" "$TEMP_NO_ID" 2>/dev/null || exit_code=$?
rm -f "$TEMP_NO_ID"
assert_eq "test_schemastore_rejects_missing_id" "1" "$exit_code"

# ── test_schemastore_rejects_localhost_id ──────────────────────────────────────
TEMP_LOCALHOST=$(mktemp)
_CLEANUP_DIRS+=("$TEMP_LOCALHOST")
cat > "$TEMP_LOCALHOST" <<'EOF'
{"$id": "http://localhost:8080/schema.json", "$schema": "http://json-schema.org/draft-07/schema#"}
EOF
exit_code=0
bash "$SCRIPT" "$TEMP_LOCALHOST" 2>/dev/null || exit_code=$?
rm -f "$TEMP_LOCALHOST"
assert_eq "test_schemastore_rejects_localhost_id" "1" "$exit_code"

# ── test_schemastore_accepts_valid_schema ─────────────────────────────────────
TEMP_VALID=$(mktemp)
_CLEANUP_DIRS+=("$TEMP_VALID")
cat > "$TEMP_VALID" <<'EOF'
{"$id": "https://raw.githubusercontent.com/lockpick/lockpick-workflow/main/docs/workflow-config-schema.json", "$schema": "http://json-schema.org/draft-07/schema#", "type": "object"}
EOF
exit_code=0
output=$(bash "$SCRIPT" "$TEMP_VALID" 2>&1) || exit_code=$?
rm -f "$TEMP_VALID"
assert_eq "test_schemastore_accepts_valid_schema" "0" "$exit_code"

# ── test_schemastore_output_contains_catalog_entry ────────────────────────────
if echo "$output" | grep -q "catalog.json"; then
    actual="contains_catalog"
else
    actual="missing_catalog"
fi
assert_eq "test_schemastore_output_contains_catalog_entry" "contains_catalog" "$actual"

print_summary
