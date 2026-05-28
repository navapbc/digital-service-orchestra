#!/usr/bin/env bash
# tests/scripts/test-bug-classification-audit.sh
# Behavioral tests for plugins/dso/scripts/bug-classification-audit.sh.
#
# NOTE: The audit script does NOT exist yet. All tests are expected to FAIL (RED phase).
#
# Interface assumption:
#   The audit script accepts an optional positional argument to override the
#   registry file path:
#     bug-classification-audit.sh [registry-file]
#   When no argument is given it defaults to the canonical registry at
#   plugins/dso/docs/bug-classification-registry.json relative to the repo root.
#   The --verify-registry flag is also accepted (Test 2).
#
# Tests:
#   1. Happy path — exit 0 on valid registry (default path)
#   2. Explicit --verify-registry flag — exit 0
#   3. Count mismatch — exit non-zero with count/total indicator in output
#   4. Missing required field (empty slug) — exit non-zero
#   5. Broken defense_artifact_ref — exit non-zero
#   6. Mutation test — broken-ref entry's slug appears in output
#
# Usage: bash tests/scripts/test-bug-classification-audit.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bug-classification-audit.sh ==="

AUDIT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/bug-classification-audit.sh"
REGISTRY="$REPO_ROOT/plugins/dso/docs/bug-classification-registry.json"

# ── test_happy_path ───────────────────────────────────────────────────────────
# Test 1: The audit script exits 0 when run against the real, valid registry.
test_happy_path() {
    local exit_code=0
    bash "$AUDIT_SCRIPT" "$REGISTRY" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_happy_path: exit 0 on valid registry" "0" "$exit_code"
}

# ── test_verify_registry_flag ─────────────────────────────────────────────────
# Test 2: The --verify-registry flag is accepted and exits 0 on valid registry.
test_verify_registry_flag() {
    local exit_code=0
    bash "$AUDIT_SCRIPT" --verify-registry "$REGISTRY" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_verify_registry_flag: --verify-registry exits 0" "0" "$exit_code"
}

# ── test_count_mismatch ───────────────────────────────────────────────────────
# Test 3: A registry with one entry removed causes a non-zero exit and the
# combined output references the expected count (27), "count", or "total".
test_count_mismatch() {
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-audit-count.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
# Remove the last entry to create a count mismatch
data['entries'] = data['entries'][:-1]
print(json.dumps(data, indent=2))
" "$REGISTRY" > "$tmpfile"

    local exit_code=0
    local combined_output
    combined_output=$(bash "$AUDIT_SCRIPT" "$tmpfile" 2>&1) || exit_code=$?

    assert_ne "test_count_mismatch: exit non-zero on count mismatch" "0" "$exit_code"

    # Output must mention the expected count (27), or the words "count" or "total"
    local contains_indicator=0
    if [[ "$combined_output" == *"27"* ]] || \
       [[ "$combined_output" == *"count"* ]] || \
       [[ "$combined_output" == *"total"* ]]; then
        contains_indicator=1
    fi
    assert_eq "test_count_mismatch: output contains count indicator (27/count/total)" "1" "$contains_indicator"
}

# ── test_missing_required_field ───────────────────────────────────────────────
# Test 4: An entry with an empty slug causes a non-zero exit.
test_missing_required_field() {
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-audit-missing-field.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
# Set the first entry's slug to empty string
data['entries'][0]['slug'] = ''
print(json.dumps(data, indent=2))
" "$REGISTRY" > "$tmpfile"

    local exit_code=0
    bash "$AUDIT_SCRIPT" "$tmpfile" >/dev/null 2>&1 || exit_code=$?

    assert_ne "test_missing_required_field: exit non-zero when slug is empty" "0" "$exit_code"
}

# ── test_broken_defense_artifact_ref ─────────────────────────────────────────
# Test 5: An entry with an invalid/nonexistent defense_artifact_ref causes
# a non-zero exit.
test_broken_defense_artifact_ref() {
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-audit-broken-ref.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
# Replace scope-drift's defense_artifact_ref with a path that does not exist
for entry in data['entries']:
    if entry['slug'] == 'scope-drift':
        entry['defense_artifact_ref'] = 'repo:definitely/does/not/exist/path.md'
        break
print(json.dumps(data, indent=2))
" "$REGISTRY" > "$tmpfile"

    local exit_code=0
    bash "$AUDIT_SCRIPT" "$tmpfile" >/dev/null 2>&1 || exit_code=$?

    assert_ne "test_broken_defense_artifact_ref: exit non-zero on broken defense_artifact_ref" "0" "$exit_code"
}

# ── test_broken_ref_names_slug ────────────────────────────────────────────────
# Test 6: When the broken-ref entry has slug "scope-drift", the audit output
# must mention "scope-drift" so engineers know which entry failed.
test_broken_ref_names_slug() {
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-audit-broken-ref-slug.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
# Same mutation as Test 5 — scope-drift gets the nonexistent ref
for entry in data['entries']:
    if entry['slug'] == 'scope-drift':
        entry['defense_artifact_ref'] = 'repo:definitely/does/not/exist/path.md'
        break
print(json.dumps(data, indent=2))
" "$REGISTRY" > "$tmpfile"

    local combined_output
    combined_output=$(bash "$AUDIT_SCRIPT" "$tmpfile" 2>&1) || true

    assert_contains "test_broken_ref_names_slug: output contains 'scope-drift'" "scope-drift" "$combined_output"
}

# ── helpers ───────────────────────────────────────────────────────────────────

# _make_mock_ticket_cmd <json-string>
# Creates a temp executable that prints the given JSON to stdout when called as
# `<cmd> list --status=closed`.  Sets MOCK_CMD to the path and registers a
# cleanup trap on RETURN so callers don't need to clean up manually.
_make_mock_ticket_cmd() {
    local json_payload="$1"
    local tmpscript
    tmpscript=$(mktemp "${TMPDIR:-/tmp}/test-audit-mock-ticket.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpscript'" RETURN
    # Write a minimal script: ignore all arguments, just print the JSON.
    printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' %s\n' \
        "$(printf '%q' "$json_payload")" > "$tmpscript"
    chmod +x "$tmpscript"
    MOCK_CMD="$tmpscript"
}

# ── test_check_tags_unknown_slug_fails ────────────────────────────────────────
# Test 7 (RED): --check-tags exits non-zero when a ticket has an unrecognised
# bug-type-* tag slug, AND the bad slug appears in the output (so engineers can
# identify which tag failed — not just any non-zero exit).
test_check_tags_unknown_slug_fails() {
    local json_payload
    json_payload='[{"ticket_id":"test-0001","ticket_type":"bug","title":"Test bug","status":"closed","tags":["bug-type-definitely-nonexistent-slug"],"priority":2,"author":"Test","created_at":1779000000000000000,"env_id":"00000000-0000-0000-0000-000000000000","parent_id":null,"alias":"test-alias","description":"","comments":[],"deps":[],"bridge_alerts":[],"reverts":[],"file_impact":[],"preconditions_summary":{"status":"pre-manifest"}}]'

    local tmpscript
    tmpscript=$(mktemp "${TMPDIR:-/tmp}/test-audit-mock-ticket.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpscript'" RETURN

    printf '#!/usr/bin/env bash\necho %s\n' "$(printf '%q' "$json_payload")" > "$tmpscript"
    chmod +x "$tmpscript"

    local exit_code=0
    local combined_output
    combined_output=$(TICKET_CMD="$tmpscript" bash "$AUDIT_SCRIPT" --check-tags 2>&1) || exit_code=$?

    assert_ne "test_check_tags_unknown_slug_fails: exit non-zero on unknown slug" "0" "$exit_code"
    # The bad slug must appear in the output (not just any non-zero exit from a
    # different failure mode such as "registry file not found").
    assert_contains "test_check_tags_unknown_slug_fails: output names the bad slug on failure" \
        "definitely-nonexistent-slug" "$combined_output"
}

# ── test_check_tags_valid_slug_passes ─────────────────────────────────────────
# Test 8 (RED): --check-tags exits 0 when a ticket has a known bug-type-* tag.
test_check_tags_valid_slug_passes() {
    local json_payload
    json_payload='[{"ticket_id":"test-0002","ticket_type":"bug","title":"Test bug","status":"closed","tags":["bug-type-scope-drift"],"priority":2,"author":"Test","created_at":1779000000000000000,"env_id":"00000000-0000-0000-0000-000000000000","parent_id":null,"alias":"test-alias2","description":"","comments":[],"deps":[],"bridge_alerts":[],"reverts":[],"file_impact":[],"preconditions_summary":{"status":"pre-manifest"}}]'

    local tmpscript
    tmpscript=$(mktemp "${TMPDIR:-/tmp}/test-audit-mock-ticket.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpscript'" RETURN

    printf '#!/usr/bin/env bash\necho %s\n' "$(printf '%q' "$json_payload")" > "$tmpscript"
    chmod +x "$tmpscript"

    local exit_code=0
    TICKET_CMD="$tmpscript" bash "$AUDIT_SCRIPT" --check-tags >/dev/null 2>&1 || exit_code=$?

    assert_eq "test_check_tags_valid_slug_passes: exit 0 on valid bug-type tag" "0" "$exit_code"
}

# ── test_check_tags_no_bug_type_tags_passes ───────────────────────────────────
# Test 9 (RED): --check-tags exits 0 when a ticket has no bug-type-* tags at
# all (other tags are ignored).
test_check_tags_no_bug_type_tags_passes() {
    local json_payload
    json_payload='[{"ticket_id":"test-0003","ticket_type":"bug","title":"Test bug","status":"closed","tags":["review:complete"],"priority":2,"author":"Test","created_at":1779000000000000000,"env_id":"00000000-0000-0000-0000-000000000000","parent_id":null,"alias":"test-alias3","description":"","comments":[],"deps":[],"bridge_alerts":[],"reverts":[],"file_impact":[],"preconditions_summary":{"status":"pre-manifest"}}]'

    local tmpscript
    tmpscript=$(mktemp "${TMPDIR:-/tmp}/test-audit-mock-ticket.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpscript'" RETURN

    printf '#!/usr/bin/env bash\necho %s\n' "$(printf '%q' "$json_payload")" > "$tmpscript"
    chmod +x "$tmpscript"

    local exit_code=0
    TICKET_CMD="$tmpscript" bash "$AUDIT_SCRIPT" --check-tags >/dev/null 2>&1 || exit_code=$?

    assert_eq "test_check_tags_no_bug_type_tags_passes: exit 0 when no bug-type tags" "0" "$exit_code"
}

# ── test_check_tags_unknown_slug_named_in_output ──────────────────────────────
# Test 10 (RED): --check-tags output (stdout+stderr) contains the bad slug name
# so engineers know which tag failed.
test_check_tags_unknown_slug_named_in_output() {
    local json_payload
    json_payload='[{"ticket_id":"test-0004","ticket_type":"bug","title":"Test bug","status":"closed","tags":["bug-type-definitely-nonexistent-slug"],"priority":2,"author":"Test","created_at":1779000000000000000,"env_id":"00000000-0000-0000-0000-000000000000","parent_id":null,"alias":"test-alias4","description":"","comments":[],"deps":[],"bridge_alerts":[],"reverts":[],"file_impact":[],"preconditions_summary":{"status":"pre-manifest"}}]'

    local tmpscript
    tmpscript=$(mktemp "${TMPDIR:-/tmp}/test-audit-mock-ticket.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmpscript'" RETURN

    printf '#!/usr/bin/env bash\necho %s\n' "$(printf '%q' "$json_payload")" > "$tmpscript"
    chmod +x "$tmpscript"

    local combined_output
    combined_output=$(TICKET_CMD="$tmpscript" bash "$AUDIT_SCRIPT" --check-tags 2>&1) || true

    assert_contains "test_check_tags_unknown_slug_named_in_output: output names the bad slug" \
        "definitely-nonexistent-slug" "$combined_output"
}

# ── run all tests ─────────────────────────────────────────────────────────────
test_happy_path
test_verify_registry_flag
test_count_mismatch
test_missing_required_field
test_broken_defense_artifact_ref
test_broken_ref_names_slug
test_check_tags_unknown_slug_fails
test_check_tags_valid_slug_passes
test_check_tags_no_bug_type_tags_passes
test_check_tags_unknown_slug_named_in_output

print_summary
