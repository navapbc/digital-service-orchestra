#!/usr/bin/env bash
# tests/scripts/test-validate-config.sh
# TDD tests for validate-config.sh (KNOWN_KEYS validator).
#
# Usage: bash tests/scripts/test-validate-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/validate-config.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-config.sh ==="

# Create temp dir for fixture files
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# -- test_valid_config_exits_0 ------------------------------------------------
# Fixture with all known keys exits 0.
_snapshot_fail
VALID_CONF="$TMPDIR_FIXTURE/valid.conf"
cat > "$VALID_CONF" <<'CONF'
# Valid config with known keys
version=1.0.0
stack=python-poetry
paths.app_dir=app
paths.src_dir=src
paths.test_dir=tests
paths.test_unit_dir=tests/unit
commands.test=make test
commands.lint=make lint
format.extensions=.py
format.source_dirs=app/src
format.source_dirs=app/tests
ci.fast_gate_job=Fast Gate
staging.url=http://example.com
CONF
stderr_out=$(bash "$SCRIPT" "$VALID_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_valid_config_exits_0 exit" "0" "$rc"
assert_pass_if_clean "test_valid_config_exits_0"

# -- test_unknown_key_exits_1 -------------------------------------------------
# Fixture with bogus.key=value exits 1, stderr mentions bogus.key.
_snapshot_fail
UNKNOWN_CONF="$TMPDIR_FIXTURE/unknown.conf"
cat > "$UNKNOWN_CONF" <<'CONF'
version=1.0.0
bogus.key=value
CONF
stderr_out=$(bash "$SCRIPT" "$UNKNOWN_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_unknown_key_exits_1 exit" "1" "$rc"
assert_contains "test_unknown_key_exits_1 stderr" "bogus.key" "$stderr_out"
assert_pass_if_clean "test_unknown_key_exits_1"

# -- test_multiple_unknown_keys ------------------------------------------------
# Fixture with 2 unknown keys exits 1, stderr lists both.
_snapshot_fail
MULTI_UNKNOWN_CONF="$TMPDIR_FIXTURE/multi-unknown.conf"
cat > "$MULTI_UNKNOWN_CONF" <<'CONF'
version=1.0.0
bogus.one=value1
bogus.two=value2
CONF
stderr_out=$(bash "$SCRIPT" "$MULTI_UNKNOWN_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_multiple_unknown_keys exit" "1" "$rc"
assert_contains "test_multiple_unknown_keys stderr bogus.one" "bogus.one" "$stderr_out"
assert_contains "test_multiple_unknown_keys stderr bogus.two" "bogus.two" "$stderr_out"
assert_pass_if_clean "test_multiple_unknown_keys"

# -- test_empty_config_exits_0 ------------------------------------------------
# Empty file exits 0.
_snapshot_fail
EMPTY_CONF="$TMPDIR_FIXTURE/empty.conf"
: > "$EMPTY_CONF"
stderr_out=$(bash "$SCRIPT" "$EMPTY_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_empty_config_exits_0 exit" "0" "$rc"
assert_pass_if_clean "test_empty_config_exits_0"

# -- test_comment_only_config_exits_0 -----------------------------------------
# File with only comments exits 0.
_snapshot_fail
COMMENT_CONF="$TMPDIR_FIXTURE/comment-only.conf"
cat > "$COMMENT_CONF" <<'CONF'
# This is a comment
# Another comment
# And one more
CONF
stderr_out=$(bash "$SCRIPT" "$COMMENT_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_comment_only_config_exits_0 exit" "0" "$rc"
assert_pass_if_clean "test_comment_only_config_exits_0"

# -- test_list_keys_not_flagged_as_duplicate -----------------------------------
# Repeated format.source_dirs (a known list key) exits 0.
_snapshot_fail
LIST_CONF="$TMPDIR_FIXTURE/list-keys.conf"
cat > "$LIST_CONF" <<'CONF'
version=1.0.0
format.source_dirs=app/src
format.source_dirs=app/tests
format.source_dirs=app/scripts
CONF
stderr_out=$(bash "$SCRIPT" "$LIST_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_list_keys_not_flagged_as_duplicate exit" "0" "$rc"
assert_pass_if_clean "test_list_keys_not_flagged_as_duplicate"

# -- test_duplicate_scalar_key_exits_1 ----------------------------------------
# Duplicate scalar key (version appears twice) exits 1.
_snapshot_fail
DUP_CONF="$TMPDIR_FIXTURE/dup-scalar.conf"
cat > "$DUP_CONF" <<'CONF'
version=1.0.0
version=2.0.0
CONF
stderr_out=$(bash "$SCRIPT" "$DUP_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_duplicate_scalar_key_exits_1 exit" "1" "$rc"
assert_contains "test_duplicate_scalar_key_exits_1 stderr" "version" "$stderr_out"
assert_pass_if_clean "test_duplicate_scalar_key_exits_1"

# -- test_blank_key_exits_1 ---------------------------------------------------
# Line with blank key (=value) exits 1.
_snapshot_fail
BLANK_KEY_CONF="$TMPDIR_FIXTURE/blank-key.conf"
cat > "$BLANK_KEY_CONF" <<'CONF'
version=1.0.0
=some_value
CONF
stderr_out=$(bash "$SCRIPT" "$BLANK_KEY_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_blank_key_exits_1 exit" "1" "$rc"
assert_pass_if_clean "test_blank_key_exits_1"

# -- test_validate_config_does_not_know_test_plugin ---------------------------
# commands.test_plugin must not appear in KNOWN_KEYS in validate-config.sh.
_snapshot_fail
{ grep -q 'commands\.test_plugin' "$SCRIPT"; test $? -ne 0; }
rc=$?
assert_eq "test_validate_config_does_not_know_test_plugin" "0" "$rc"
assert_pass_if_clean "test_validate_config_does_not_know_test_plugin"

# -- test_ci_workflow_name_valid_key ------------------------------------------
# A config containing only ci.workflow_name=CI must exit 0.
# RED: This test FAILS before ci.workflow_name is added to KNOWN_KEYS.
_snapshot_fail
CI_WF_CONF="$TMPDIR_FIXTURE/ci-workflow-name.conf"
cat > "$CI_WF_CONF" <<'CONF'
ci.workflow_name=CI
CONF
stderr_out=$(bash "$SCRIPT" "$CI_WF_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_ci_workflow_name_valid_key exit" "0" "$rc"
assert_pass_if_clean "test_ci_workflow_name_valid_key"

# -- test_merge_ci_workflow_name_still_valid -----------------------------------
# A config containing merge.ci_workflow_name=CI must still exit 0 (backward compat).
_snapshot_fail
MERGE_CI_WF_CONF="$TMPDIR_FIXTURE/merge-ci-workflow-name.conf"
cat > "$MERGE_CI_WF_CONF" <<'CONF'
merge.ci_workflow_name=CI
CONF
stderr_out=$(bash "$SCRIPT" "$MERGE_CI_WF_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_merge_ci_workflow_name_still_valid exit" "0" "$rc"
assert_pass_if_clean "test_merge_ci_workflow_name_still_valid"

# -- test_preplanning_interactive_valid_key ------------------------------------
# A config containing preplanning.interactive=false must exit 0.
# RED: This test FAILS before preplanning.interactive is added to KNOWN_KEYS.
_snapshot_fail
PRE_INT_CONF="$TMPDIR_FIXTURE/preplanning-interactive.conf"
cat > "$PRE_INT_CONF" <<'CONF'
preplanning.interactive=false
CONF
stderr_out=$(bash "$SCRIPT" "$PRE_INT_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_preplanning_interactive_valid_key exit" "0" "$rc"
assert_pass_if_clean "test_preplanning_interactive_valid_key"

# -- test_unknown_key_still_rejected_after_preplanning_addition ----------------
# An unknown key must still be rejected even after preplanning.interactive is added.
_snapshot_fail
STILL_UNKNOWN_CONF="$TMPDIR_FIXTURE/still-unknown.conf"
cat > "$STILL_UNKNOWN_CONF" <<'CONF'
version=1.0.0
preplanning.unknown_key=value
CONF
stderr_out=$(bash "$SCRIPT" "$STILL_UNKNOWN_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_unknown_key_still_rejected_after_preplanning_addition exit" "1" "$rc"
assert_contains "test_unknown_key_still_rejected_after_preplanning_addition stderr" "preplanning.unknown_key" "$stderr_out"
assert_pass_if_clean "test_unknown_key_still_rejected_after_preplanning_addition"

# -- Summary -------------------------------------------------------------------
print_summary
