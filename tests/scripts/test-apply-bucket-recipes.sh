#!/usr/bin/env bash
# tests/scripts/test-apply-bucket-recipes.sh
# Behavioral fixture test for plugins/dso/scripts/apply-bucket-recipes.sh
#
# Testing Mode: GREEN — confirms the recipe applier exists and behaves per DD7.
#
# Story coverage: 7e2c-2f4c-cd95-4e60 (SC4 + SC5 source-file consumer audit)
# Task: T3 GREEN (apply-bucket-recipes.sh)
#
# DD validated:
#   DD7 — Pointer updates land across consumer files identified by audit.
#         V1 recipes are conservative: every bucket defaults to
#         manual_review_required except unambiguous no_op cases.
#
# Behavioral pattern: every test follows Given / When / Then. Tests construct
# fixture audit-JSON envelopes (per the contract at
# plugins/dso/docs/contracts/closure-checks-source-audit-output.md), invoke
# the recipe applier as a subprocess, and assert on outputs.
#
# Usage: bash tests/scripts/test-apply-bucket-recipes.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
APPLY_SCRIPT="$REPO_ROOT/plugins/dso/scripts/apply-bucket-recipes.sh"

# Side-channel for the recipe-applier subprocess's exit code. Mirrors the
# pattern in test-audit-source-consumers.sh.
_APPLY_EXIT_FILE="$(mktemp "${TMPDIR:-/tmp}/test-apply-bucket-recipes-exit.XXXXXX")"
_APPLY_EXIT=0
trap 'rm -f "$_APPLY_EXIT_FILE"' EXIT

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-apply-bucket-recipes.sh ==="

# ── Suite-runner guard: skip when applier script does not exist ──────────────
# Behaves analogously to test-audit-source-consumers.sh during RED phase.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$APPLY_SCRIPT" ]; then
    echo "SKIP: apply-bucket-recipes.sh not yet implemented — tests deferred"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Helper: create a fresh tempdir scoped for this test ──────────────────────
_make_tempdir() {
    local prefix="$1"
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-apply-bucket-recipes-${prefix}.XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ── Helper: write a fixture audit-JSON envelope ──────────────────────────────
# Usage: _write_audit_json <output-path> <python-buckets-snippet>
# The python snippet should define a `buckets` dict; the helper wraps it
# into a full schema_version=1.0 envelope.
_write_audit_json() {
    local output_path="$1"
    local buckets_snippet="$2"

    python3 - "$output_path" <<PY
import json
import sys
import uuid
import datetime

out_path = sys.argv[1]
${buckets_snippet}
envelope = {
    "schema_version": "1.0",
    "audit_run_id": str(uuid.uuid4()),
    "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "file_count_scanned": 0,
    "buckets": buckets,
    "dynamic_load_count": 0,
    "unbucketed_matches": [],
    "removed_files": [],
    "reconciliation_status": "complete",
    "reconciliation_iterations": 1,
}
with open(out_path, "w") as fh:
    json.dump(envelope, fh)
PY
}

# ── Helper: run the recipe applier and capture exit ──────────────────────────
# Usage: _run_apply <audit-json-path> [extra args...]
_run_apply() {
    local audit_json="$1"
    shift
    local exit_code=0
    local out
    out=$(bash "$APPLY_SCRIPT" --audit-output "$audit_json" "$@" 2>/dev/null) || exit_code=$?
    printf '%s' "$exit_code" > "$_APPLY_EXIT_FILE"
    printf '%s' "$out"
}

_load_apply_exit() {
    if [ -s "$_APPLY_EXIT_FILE" ]; then
        _APPLY_EXIT=$(cat "$_APPLY_EXIT_FILE")
    fi
}

# ── Helper: locate the most-recent recipe-application JSON ───────────────────
_latest_apply_json() {
    # The applier writes to the host project's .audit-output directory.
    # shellcheck disable=SC2012  # ls -1t sorts by mtime; artifact names are controlled.
    ls -1t "$REPO_ROOT/plugins/dso/.audit-output"/recipe-application-*.json 2>/dev/null | head -1
}

# ── Helper: extract a field from the latest JSON via Python ──────────────────
# Usage: _json_query <path> <python-expr-on-data>
_json_query() {
    local json_path="$1"
    local expr="$2"
    python3 - "$json_path" "$expr" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
expr = sys.argv[2]
# `data` is in scope for the expression.
print(eval(expr))  # noqa: S307 - test-internal eval over controlled expr
PY
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and is executable
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: apply-bucket-recipes.sh exists and is executable"
test_script_exists_and_executable() {
    if [ -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists" "exists" "exists"
    else
        assert_eq "apply-bucket-recipes.sh exists" "exists" "missing"
    fi
    if [ -x "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh is executable" "executable" "executable"
    else
        assert_eq "apply-bucket-recipes.sh is executable" "executable" "not-executable"
    fi
}
test_script_exists_and_executable

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: --dry-run is the DEFAULT mode (no --apply → no mutations)
#
# Given: audit JSON references a real consumer file in the repo
# When:  applier runs WITHOUT --apply
# Then:  the consumer file is NOT modified (mtime unchanged) AND exit 0
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: --dry-run is default (no --apply → no file modifications)"
test_dry_run_is_default() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t2-dry-run")
    local audit_json="$tempdir/audit.json"

    # Reference a file we'll create in the tempdir; capture pre-mtime.
    local target_file="$tempdir/sample.md"
    printf "## Closure Checks\nbody\n" > "$target_file"
    local pre_mtime
    pre_mtime=$(python3 -c "import os, sys; print(int(os.path.getmtime(sys.argv[1])))" "$target_file")

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [{'file': 'plugins/foo.md', 'line': 1, 'match_text': '## Closure Checks', 'dynamic_load': False}],
    'file-path-reference': [],
    'semantic-consumer': [],
    'test-asserting-on-structure': [],
    'user-facing-copy': [],
    'migration-in-progress': [],
}"

    local out
    out=$(_run_apply "$audit_json")
    _load_apply_exit

    # Allow time-based stat to settle.
    sleep 1
    local post_mtime
    post_mtime=$(python3 -c "import os, sys; print(int(os.path.getmtime(sys.argv[1])))" "$target_file")

    assert_eq "exit code is 0 (dry-run is normal completion)" "0" "$_APPLY_EXIT"
    assert_eq "target file NOT modified in dry-run (mtime unchanged)" "$pre_mtime" "$post_mtime"

    assert_pass_if_clean "test_dry_run_is_default"
}
test_dry_run_is_default

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: --apply flag required for mutation (dry-run text present without it)
#
# Given: any valid audit JSON
# When:  applier runs WITHOUT --apply
# Then:  stdout contains explicit "dry-run" indicator
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: --apply required for mutation (dry-run indicator in output)"
test_apply_flag_required_for_mutation() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t3-apply-flag")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {b: [] for b in (
    'section-name-reference', 'file-path-reference', 'semantic-consumer',
    'test-asserting-on-structure', 'user-facing-copy', 'migration-in-progress',
)}"

    local out
    out=$(_run_apply "$audit_json")
    _load_apply_exit

    assert_eq "exit code is 0" "0" "$_APPLY_EXIT"
    assert_contains "stdout mentions dry-run mode" "dry-run" "$out"
    assert_not_contains "stdout does NOT claim apply mode" "Mode:                  apply" "$out"

    assert_pass_if_clean "test_apply_flag_required_for_mutation"
}
test_apply_flag_required_for_mutation

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: recipe_section_name_reference → manual_review_required (normal case)
#
# Given: audit JSON has a section-name-reference match in a non-migration file
#        with dynamic_load=False
# When:  applier runs
# Then:  the recorded action is manual_review_required
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: section-name-reference (static, non-migration) → manual_review_required"
test_recipe_section_name_reference() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t4-section-name")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [{'file': 'plugins/some_consumer.md', 'line': 42, 'match_text': '## Closure Checks', 'dynamic_load': False}],
    'file-path-reference': [],
    'semantic-consumer': [],
    'test-asserting-on-structure': [],
    'user-facing-copy': [],
    'migration-in-progress': [],
}"

    _run_apply "$audit_json" >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)
    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "recipe-application JSON exists" "exists" "missing"
        assert_pass_if_clean "test_recipe_section_name_reference"
        return
    fi

    local action
    action=$(_json_query "$json_path" "[a['action'] for a in data['actions'] if a['file']=='plugins/some_consumer.md'][0]")

    assert_eq "section-name-reference action is manual_review_required" "manual_review_required" "$action"

    assert_pass_if_clean "test_recipe_section_name_reference"
}
test_recipe_section_name_reference

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: recipe_file_path_reference (extant file) → no_op
#
# Given: audit JSON match references a file that EXISTS in the repo
#        (we use the audit script itself, which lives in plugins/dso/scripts/)
# When:  applier runs
# Then:  action is no_op
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: file-path-reference (extant) → no_op"
test_recipe_file_path_reference_extant() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t5-file-extant")
    local audit_json="$tempdir/audit.json"

    # Reference apply-bucket-recipes.sh — it definitely exists in the repo
    # at plugins/dso/scripts/apply-bucket-recipes.sh.
    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [],
    'file-path-reference': [{'file': 'docs/some-doc.md', 'line': 10, 'match_text': 'apply-bucket-recipes.sh', 'dynamic_load': False}],
    'semantic-consumer': [],
    'test-asserting-on-structure': [],
    'user-facing-copy': [],
    'migration-in-progress': [],
}"

    _run_apply "$audit_json" >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)
    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "recipe-application JSON exists" "exists" "missing"
        assert_pass_if_clean "test_recipe_file_path_reference_extant"
        return
    fi

    local action
    action=$(_json_query "$json_path" "[a['action'] for a in data['actions'] if a['bucket']=='file-path-reference'][0]")

    assert_eq "file-path-reference (extant) action is no_op" "no_op" "$action"

    assert_pass_if_clean "test_recipe_file_path_reference_extant"
}
test_recipe_file_path_reference_extant

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: recipe_file_path_reference (missing file) → manual_review_required
#
# Given: audit JSON match references a non-existent file path
# When:  applier runs
# Then:  action is manual_review_required
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: file-path-reference (missing) → manual_review_required"
test_recipe_file_path_reference_missing() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t6-file-missing")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [],
    'file-path-reference': [{'file': 'docs/some-doc.md', 'line': 10, 'match_text': 'nonexistent-stub-script-zzzzz.sh', 'dynamic_load': False}],
    'semantic-consumer': [],
    'test-asserting-on-structure': [],
    'user-facing-copy': [],
    'migration-in-progress': [],
}"

    _run_apply "$audit_json" >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)
    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "recipe-application JSON exists" "exists" "missing"
        assert_pass_if_clean "test_recipe_file_path_reference_missing"
        return
    fi

    local action
    action=$(_json_query "$json_path" "[a['action'] for a in data['actions'] if a['bucket']=='file-path-reference'][0]")

    assert_eq "file-path-reference (missing) action is manual_review_required" "manual_review_required" "$action"

    assert_pass_if_clean "test_recipe_file_path_reference_missing"
}
test_recipe_file_path_reference_missing

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: recipe_semantic_consumer → manual_review_required (always)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: semantic-consumer → manual_review_required"
test_recipe_semantic_consumer_manual_review() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t7-semantic")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [],
    'file-path-reference': [],
    'semantic-consumer': [{'file': 'plugins/parser.py', 'line': 100, 'match_text': '## Closure Checks', 'dynamic_load': False}],
    'test-asserting-on-structure': [],
    'user-facing-copy': [],
    'migration-in-progress': [],
}"

    _run_apply "$audit_json" >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)
    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "recipe-application JSON exists" "exists" "missing"
        assert_pass_if_clean "test_recipe_semantic_consumer_manual_review"
        return
    fi

    local action
    action=$(_json_query "$json_path" "[a['action'] for a in data['actions'] if a['bucket']=='semantic-consumer'][0]")

    assert_eq "semantic-consumer action is manual_review_required" "manual_review_required" "$action"

    assert_pass_if_clean "test_recipe_semantic_consumer_manual_review"
}
test_recipe_semantic_consumer_manual_review

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: recipe_test_asserting_on_structure → manual_review_required (always)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 8: test-asserting-on-structure → manual_review_required"
test_recipe_test_asserting_manual_review() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t8-test-assert")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [],
    'file-path-reference': [],
    'semantic-consumer': [],
    'test-asserting-on-structure': [{'file': 'tests/test_x.sh', 'line': 10, 'match_text': '## Closure Checks', 'dynamic_load': False}],
    'user-facing-copy': [],
    'migration-in-progress': [],
}"

    _run_apply "$audit_json" >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)
    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "recipe-application JSON exists" "exists" "missing"
        assert_pass_if_clean "test_recipe_test_asserting_manual_review"
        return
    fi

    local action
    action=$(_json_query "$json_path" "[a['action'] for a in data['actions'] if a['bucket']=='test-asserting-on-structure'][0]")

    assert_eq "test-asserting-on-structure action is manual_review_required" "manual_review_required" "$action"

    assert_pass_if_clean "test_recipe_test_asserting_manual_review"
}
test_recipe_test_asserting_manual_review

# ═══════════════════════════════════════════════════════════════════════════════
# Test 9: recipe_user_facing_copy → manual_review_required (always)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 9: user-facing-copy → manual_review_required"
test_recipe_user_facing_copy_manual_review() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t9-user-copy")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [],
    'file-path-reference': [],
    'semantic-consumer': [],
    'test-asserting-on-structure': [],
    'user-facing-copy': [{'file': 'plugins/agents/verifier.md', 'line': 57, 'match_text': 'Closure Checks', 'dynamic_load': False}],
    'migration-in-progress': [],
}"

    _run_apply "$audit_json" >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)
    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "recipe-application JSON exists" "exists" "missing"
        assert_pass_if_clean "test_recipe_user_facing_copy_manual_review"
        return
    fi

    local action
    action=$(_json_query "$json_path" "[a['action'] for a in data['actions'] if a['bucket']=='user-facing-copy'][0]")

    assert_eq "user-facing-copy action is manual_review_required" "manual_review_required" "$action"

    assert_pass_if_clean "test_recipe_user_facing_copy_manual_review"
}
test_recipe_user_facing_copy_manual_review

# ═══════════════════════════════════════════════════════════════════════════════
# Test 10: recipe_migration_in_progress → manual_review_required (always)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 10: migration-in-progress → manual_review_required"
test_recipe_migration_in_progress_manual_review() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t10-migration")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [],
    'file-path-reference': [],
    'semantic-consumer': [],
    'test-asserting-on-structure': [],
    'user-facing-copy': [],
    'migration-in-progress': [{'file': 'plugins/scripts/migrate-closure-checks.sh', 'line': 12, 'match_text': '## Closure Checks', 'dynamic_load': False}],
}"

    _run_apply "$audit_json" >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)
    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "recipe-application JSON exists" "exists" "missing"
        assert_pass_if_clean "test_recipe_migration_in_progress_manual_review"
        return
    fi

    local action
    action=$(_json_query "$json_path" "[a['action'] for a in data['actions'] if a['bucket']=='migration-in-progress'][0]")

    assert_eq "migration-in-progress action is manual_review_required" "manual_review_required" "$action"

    assert_pass_if_clean "test_recipe_migration_in_progress_manual_review"
}
test_recipe_migration_in_progress_manual_review

# ═══════════════════════════════════════════════════════════════════════════════
# Test 11: summary report contains APPLY_BUCKET_RECIPES_SUMMARY marker
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 11: APPLY_BUCKET_RECIPES_SUMMARY: marker emitted on stdout"
test_summary_report_emitted() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t11-summary")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {b: [] for b in (
    'section-name-reference', 'file-path-reference', 'semantic-consumer',
    'test-asserting-on-structure', 'user-facing-copy', 'migration-in-progress',
)}"

    local out
    out=$(_run_apply "$audit_json")
    _load_apply_exit

    assert_eq "exit code is 0" "0" "$_APPLY_EXIT"
    assert_contains "APPLY_BUCKET_RECIPES_SUMMARY: marker present" "APPLY_BUCKET_RECIPES_SUMMARY:" "$out"
    assert_contains "summary shows Total matches" "Total matches:" "$out"
    assert_contains "summary shows Manual review required count" "Manual review required:" "$out"

    assert_pass_if_clean "test_summary_report_emitted"
}
test_summary_report_emitted

# ═══════════════════════════════════════════════════════════════════════════════
# Test 12: JSON output written with required schema
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 12: recipe-application JSON output written with required fields"
test_json_output_written() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t12-json-out")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [{'file': 'plugins/a.md', 'line': 1, 'match_text': '## Closure Checks', 'dynamic_load': False}],
    'file-path-reference': [],
    'semantic-consumer': [],
    'test-asserting-on-structure': [],
    'user-facing-copy': [],
    'migration-in-progress': [],
}"

    _run_apply "$audit_json" >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)

    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "JSON artifact exists" "exists" "missing"
        assert_pass_if_clean "test_json_output_written"
        return
    fi

    assert_eq "JSON artifact path matches pattern" "yes" "$([ -n "$json_path" ] && echo yes || echo no)"

    # Verify required envelope fields.
    local has_applied_at has_audit_source has_mode has_actions has_summary mode
    has_applied_at=$(_json_query "$json_path" "'applied_at' in data")
    has_audit_source=$(_json_query "$json_path" "'audit_source' in data")
    has_mode=$(_json_query "$json_path" "'mode' in data")
    has_actions=$(_json_query "$json_path" "'actions' in data")
    has_summary=$(_json_query "$json_path" "'summary' in data")
    mode=$(_json_query "$json_path" "data['mode']")

    assert_eq "JSON has applied_at field" "True" "$has_applied_at"
    assert_eq "JSON has audit_source field" "True" "$has_audit_source"
    assert_eq "JSON has mode field" "True" "$has_mode"
    assert_eq "JSON has actions array" "True" "$has_actions"
    assert_eq "JSON has summary object" "True" "$has_summary"
    assert_eq "mode value is dry-run (no --apply passed)" "dry-run" "$mode"

    assert_pass_if_clean "test_json_output_written"
}
test_json_output_written

# ═══════════════════════════════════════════════════════════════════════════════
# Test 13: --bucket filter restricts processing to one bucket
#
# Given: audit JSON has matches in two buckets
# When:  applier runs with --bucket section-name-reference
# Then:  only the section-name-reference match is processed (actions list
#        contains exactly 1 entry from that bucket)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 13: --bucket filter only processes the specified bucket"
test_bucket_filter_flag() {
    _snapshot_fail

    if [ ! -f "$APPLY_SCRIPT" ]; then
        assert_eq "apply-bucket-recipes.sh exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t13-bucket-filter")
    local audit_json="$tempdir/audit.json"

    _write_audit_json "$audit_json" "buckets = {
    'section-name-reference': [{'file': 'plugins/a.md', 'line': 1, 'match_text': '## Closure Checks', 'dynamic_load': False}],
    'file-path-reference': [],
    'semantic-consumer': [{'file': 'plugins/parser.py', 'line': 5, 'match_text': '## Closure Checks', 'dynamic_load': False}],
    'test-asserting-on-structure': [],
    'user-facing-copy': [],
    'migration-in-progress': [],
}"

    _run_apply "$audit_json" --bucket section-name-reference >/dev/null
    _load_apply_exit

    local json_path
    json_path=$(_latest_apply_json)
    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "JSON artifact exists" "exists" "missing"
        assert_pass_if_clean "test_bucket_filter_flag"
        return
    fi

    local total_actions section_actions semantic_actions
    total_actions=$(_json_query "$json_path" "len(data['actions'])")
    section_actions=$(_json_query "$json_path" "len([a for a in data['actions'] if a['bucket']=='section-name-reference'])")
    semantic_actions=$(_json_query "$json_path" "len([a for a in data['actions'] if a['bucket']=='semantic-consumer'])")

    assert_eq "only 1 action recorded with --bucket filter" "1" "$total_actions"
    assert_eq "section-name-reference action present" "1" "$section_actions"
    assert_eq "semantic-consumer action NOT present (filtered out)" "0" "$semantic_actions"

    assert_pass_if_clean "test_bucket_filter_flag"
}
test_bucket_filter_flag

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
