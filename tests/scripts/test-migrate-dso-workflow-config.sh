#!/usr/bin/env bash
# shellcheck source=tests/lib/assert.sh
# tests/scripts/test-migrate-dso-workflow-config.sh
# RED-phase behavioral tests for plugins/dso/scripts/migrate-dso-workflow-config.sh
#
# Usage: bash tests/scripts/test-migrate-dso-workflow-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until migrate-dso-workflow-config.sh is implemented.
#
# Behavior under test:
#   migrate-dso-workflow-config.sh migrates legacy dso-config.conf keys to the
#   canonical dso.workflow=<local|ci-pr> key:
#     - merge.strategy=pr + enforcement.strategy=ci  → dso.workflow=ci-pr
#     - merge.strategy=direct                         → dso.workflow=local
#     - Creates sentinel .claude/.dso-config-v2-migrated after successful rewrite
#     - Supports --dry-run flag (no file modification)
#     - Is idempotent (second run is a no-op)
#     - Self-guards: exit 0 no-op when run from plugin source tree
#     - Grammar validation: rejects inline comments, quoted values, duplicate keys, CRLF

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

MIGRATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/migrate-dso-workflow-config.sh"

echo "=== test-migrate-dso-workflow-config.sh ==="

# ── Suite-runner guard (RED phase) ────────────────────────────────────────────
# When run-all.sh invokes this suite and the script is not yet implemented,
# skip gracefully so the overall suite stays green.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo 'SKIP: migrate-dso-workflow-config.sh not yet implemented (RED) — tests deferred'
    printf 'PASSED: 0  FAILED: 0\n'
    exit 0
fi

# ── Shared temp dir registry — all cleaned up on EXIT ─────────────────────────
_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]}"' EXIT

# ── Helper: create a minimal host project fixture ─────────────────────────────
# Usage: _make_fixture [<conf_content>]
# Sets global FIXTURE_DIR, FIXTURE_CONF, FIXTURE_SENTINEL.
_make_fixture() {
    local conf_content="${1:-}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    _TMP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"
    if [ -n "$conf_content" ]; then
        printf '%s\n' "$conf_content" > "$tmpdir/.claude/dso-config.conf"
    fi
    FIXTURE_DIR="$tmpdir"
    FIXTURE_CONF="$tmpdir/.claude/dso-config.conf"
    FIXTURE_SENTINEL="$tmpdir/.claude/.dso-config-v2-migrated"
}

# ── test_migrator_rewrites_legacy_keys_to_dso_workflow ────────────────────────
# When config has merge.strategy=pr + enforcement.strategy=ci,
# after migration: dso.workflow=ci-pr is present and legacy keys are commented out.
_snapshot_fail
_make_fixture "merge.strategy=pr
enforcement.strategy=ci
worktree.isolation_enabled=true"
_rewrite_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _rewrite_exit=$?
assert_eq "test_migrator_rewrites_legacy_keys_to_dso_workflow: exits 0" "0" "$_rewrite_exit"
if [ -f "$FIXTURE_CONF" ] && grep -q "^dso.workflow=ci-pr" "$FIXTURE_CONF"; then
    _rewrite_dw="present"
else
    _rewrite_dw="missing"
fi
assert_eq "test_migrator_rewrites_legacy_keys_to_dso_workflow: dso.workflow=ci-pr written" "present" "$_rewrite_dw"
if [ -f "$FIXTURE_CONF" ] && grep -q "^# migrated to dso.workflow" "$FIXTURE_CONF"; then
    _rewrite_comment="present"
else
    _rewrite_comment="missing"
fi
assert_eq "test_migrator_rewrites_legacy_keys_to_dso_workflow: legacy keys commented out" "present" "$_rewrite_comment"
assert_pass_if_clean "test_migrator_rewrites_legacy_keys_to_dso_workflow"

# ── test_migrator_maps_direct_to_local ────────────────────────────────────────
# When config has merge.strategy=direct, after migration dso.workflow=local is present.
_snapshot_fail
_make_fixture "merge.strategy=direct
worktree.isolation_enabled=false"
_direct_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _direct_exit=$?
assert_eq "test_migrator_maps_direct_to_local: exits 0" "0" "$_direct_exit"
if [ -f "$FIXTURE_CONF" ] && grep -q "^dso.workflow=local" "$FIXTURE_CONF"; then
    _direct_dw="present"
else
    _direct_dw="missing"
fi
assert_eq "test_migrator_maps_direct_to_local: dso.workflow=local written" "present" "$_direct_dw"
assert_pass_if_clean "test_migrator_maps_direct_to_local"

# ── test_migrator_creates_sentinel_after_migration ────────────────────────────
# After a successful migration, the sentinel file must exist.
_snapshot_fail
_make_fixture "merge.strategy=pr
enforcement.strategy=ci"
_sentinel_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _sentinel_exit=$?
assert_eq "test_migrator_creates_sentinel_after_migration: exits 0" "0" "$_sentinel_exit"
if [ -f "$FIXTURE_SENTINEL" ]; then
    _sentinel_present="present"
else
    _sentinel_present="missing"
fi
assert_eq "test_migrator_creates_sentinel_after_migration: sentinel exists" "present" "$_sentinel_present"
assert_pass_if_clean "test_migrator_creates_sentinel_after_migration"

# ── test_migrator_idempotent_second_run_noop ─────────────────────────────────
# Running the migrator twice on the same fixture produces zero diff on the second run.
_snapshot_fail
_make_fixture "merge.strategy=pr
enforcement.strategy=ci"
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || true
_conf_after_first="$(cat "$FIXTURE_CONF" 2>/dev/null)"
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || true
_conf_after_second="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_after_first" = "$_conf_after_second" ]; then
    _idempotent="yes"
else
    _idempotent="no"
fi
assert_eq "test_migrator_idempotent_second_run_noop: config unchanged on second run" "yes" "$_idempotent"
assert_pass_if_clean "test_migrator_idempotent_second_run_noop"

# ── test_migrator_dry_run_no_modification ────────────────────────────────────
# --dry-run flag must NOT modify the config file or create the sentinel.
_snapshot_fail
_make_fixture "merge.strategy=pr
enforcement.strategy=ci"
_conf_before_dry="$(cat "$FIXTURE_CONF")"
_dry_exit=0
bash "$MIGRATE_SCRIPT" --dry-run "$FIXTURE_DIR" >/dev/null 2>&1 || _dry_exit=$?
assert_eq "test_migrator_dry_run_no_modification: exits 0" "0" "$_dry_exit"
_conf_after_dry="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_before_dry" = "$_conf_after_dry" ]; then
    _dry_unchanged="yes"
else
    _dry_unchanged="no"
fi
assert_eq "test_migrator_dry_run_no_modification: config not modified" "yes" "$_dry_unchanged"
if [ ! -f "$FIXTURE_SENTINEL" ]; then
    _dry_no_sentinel="yes"
else
    _dry_no_sentinel="no"
fi
assert_eq "test_migrator_dry_run_no_modification: sentinel not created" "yes" "$_dry_no_sentinel"
assert_pass_if_clean "test_migrator_dry_run_no_modification"

# ── test_migrator_self_guard_noop_in_plugin_source ───────────────────────────
# When the script is invoked from a directory that IS the plugin source tree
# (i.e. contains plugins/dso/scripts/migrate-dso-workflow-config.sh referencing itself),
# it must exit 0 and make no modifications.
_snapshot_fail
_make_fixture "merge.strategy=pr
enforcement.strategy=ci"
# Create the plugin source marker: a plugins/dso/ subtree that contains the script itself.
mkdir -p "$FIXTURE_DIR/plugins/dso/scripts"
cp "$MIGRATE_SCRIPT" "$FIXTURE_DIR/plugins/dso/scripts/migrate-dso-workflow-config.sh"
_conf_before_sg="$(cat "$FIXTURE_CONF")"
_sg_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _sg_exit=$?
assert_eq "test_migrator_self_guard_noop_in_plugin_source: exits 0" "0" "$_sg_exit"
_conf_after_sg="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_before_sg" = "$_conf_after_sg" ]; then
    _sg_unchanged="yes"
else
    _sg_unchanged="no"
fi
assert_eq "test_migrator_self_guard_noop_in_plugin_source: config not modified" "yes" "$_sg_unchanged"
assert_pass_if_clean "test_migrator_self_guard_noop_in_plugin_source"

# ── test_migrator_false_positive_self_guard ───────────────────────────────────
# A host project WITH a plugins/dso/ subdirectory that is NOT the plugin source
# (i.e. the subdirectory exists but does not contain migrate-dso-workflow-config.sh)
# must be treated as a host project and have its config migrated.
_snapshot_fail
_make_fixture "merge.strategy=pr
enforcement.strategy=ci"
# Create plugins/dso/ but WITHOUT the migrate script inside it (host-project pattern).
mkdir -p "$FIXTURE_DIR/plugins/dso/scripts"
_fp_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _fp_exit=$?
assert_eq "test_migrator_false_positive_self_guard: exits 0" "0" "$_fp_exit"
if [ -f "$FIXTURE_CONF" ] && grep -q "^dso.workflow=" "$FIXTURE_CONF"; then
    _fp_migrated="yes"
else
    _fp_migrated="no"
fi
assert_eq "test_migrator_false_positive_self_guard: migration applied to host project" "yes" "$_fp_migrated"
assert_pass_if_clean "test_migrator_false_positive_self_guard"

# ── test_migrator_rejects_inline_comments ────────────────────────────────────
# Config with an inline comment (e.g. merge.strategy=pr # comment) must cause
# the migrator to exit non-zero and leave the file unmodified.
_snapshot_fail
_make_fixture "merge.strategy=pr # comment
enforcement.strategy=ci"
_conf_before_ic="$(cat "$FIXTURE_CONF")"
_ic_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _ic_exit=$?
assert_ne "test_migrator_rejects_inline_comments: exits non-zero" "0" "$_ic_exit"
_conf_after_ic="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_before_ic" = "$_conf_after_ic" ]; then
    _ic_unchanged="yes"
else
    _ic_unchanged="no"
fi
assert_eq "test_migrator_rejects_inline_comments: config not modified" "yes" "$_ic_unchanged"
assert_pass_if_clean "test_migrator_rejects_inline_comments"

# ── test_migrator_rejects_quoted_values ───────────────────────────────────────
# Config with a quoted value (e.g. merge.strategy="pr") must cause the migrator
# to exit non-zero and leave the file unmodified.
_snapshot_fail
_make_fixture 'merge.strategy="pr"
enforcement.strategy=ci'
_conf_before_qv="$(cat "$FIXTURE_CONF")"
_qv_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _qv_exit=$?
assert_ne "test_migrator_rejects_quoted_values: exits non-zero" "0" "$_qv_exit"
_conf_after_qv="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_before_qv" = "$_conf_after_qv" ]; then
    _qv_unchanged="yes"
else
    _qv_unchanged="no"
fi
assert_eq "test_migrator_rejects_quoted_values: config not modified" "yes" "$_qv_unchanged"
assert_pass_if_clean "test_migrator_rejects_quoted_values"

# ── test_migrator_rejects_duplicate_keys ──────────────────────────────────────
# Config with two merge.strategy= lines must cause the migrator to exit non-zero
# and leave the file unmodified.
_snapshot_fail
_make_fixture "merge.strategy=pr
merge.strategy=direct
enforcement.strategy=ci"
_conf_before_dk="$(cat "$FIXTURE_CONF")"
_dk_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _dk_exit=$?
assert_ne "test_migrator_rejects_duplicate_keys: exits non-zero" "0" "$_dk_exit"
_conf_after_dk="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_before_dk" = "$_conf_after_dk" ]; then
    _dk_unchanged="yes"
else
    _dk_unchanged="no"
fi
assert_eq "test_migrator_rejects_duplicate_keys: config not modified" "yes" "$_dk_unchanged"
assert_pass_if_clean "test_migrator_rejects_duplicate_keys"

# ── test_migrator_atomic_write ────────────────────────────────────────────────
# After a successful migration, if the sentinel exists, the config must be valid
# (contain dso.workflow=). This verifies atomicity: sentinel is only written after
# the config rewrite succeeds.
_snapshot_fail
_make_fixture "merge.strategy=pr
enforcement.strategy=ci"
_aw_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _aw_exit=$?
assert_eq "test_migrator_atomic_write: exits 0" "0" "$_aw_exit"
if [ -f "$FIXTURE_SENTINEL" ]; then
    # Sentinel exists — config must be valid
    if [ -f "$FIXTURE_CONF" ] && grep -q "^dso.workflow=" "$FIXTURE_CONF"; then
        _aw_valid="yes"
    else
        _aw_valid="no"
    fi
else
    # No sentinel — treat as missing (atomic write didn't complete)
    _aw_valid="no"
fi
assert_eq "test_migrator_atomic_write: sentinel presence implies valid config" "yes" "$_aw_valid"
assert_pass_if_clean "test_migrator_atomic_write"

# ── test_migrator_already_migrated_noop ───────────────────────────────────────
# When config already has dso.workflow=ci-pr (post-migration format), the migrator
# must exit 0, make no modifications, and the sentinel must exist.
_snapshot_fail
_make_fixture "dso.workflow=ci-pr
# merge.strategy=pr # migrated to dso.workflow (v1.0.0)"
# Pre-create sentinel to simulate already-migrated state
touch "$FIXTURE_SENTINEL"
_conf_before_am="$(cat "$FIXTURE_CONF")"
_am_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _am_exit=$?
assert_eq "test_migrator_already_migrated_noop: exits 0" "0" "$_am_exit"
_conf_after_am="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_before_am" = "$_conf_after_am" ]; then
    _am_unchanged="yes"
else
    _am_unchanged="no"
fi
assert_eq "test_migrator_already_migrated_noop: config not modified" "yes" "$_am_unchanged"
if [ -f "$FIXTURE_SENTINEL" ]; then
    _am_sentinel="present"
else
    _am_sentinel="missing"
fi
assert_eq "test_migrator_already_migrated_noop: sentinel present" "present" "$_am_sentinel"
assert_pass_if_clean "test_migrator_already_migrated_noop"

# ── test_migrator_rejects_crlf_line_endings ──────────────────────────────────
# Config with CRLF line endings must cause the migrator to exit non-zero and
# leave the file unmodified.
_snapshot_fail
_make_fixture ""
# Write config with CRLF line endings (printf to avoid shell newline translation)
printf 'merge.strategy=pr\r\nenforcement.strategy=ci\r\n' > "$FIXTURE_CONF"
_conf_before_crlf="$(cat "$FIXTURE_CONF")"
_crlf_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _crlf_exit=$?
assert_ne "test_migrator_rejects_crlf_line_endings: exits non-zero" "0" "$_crlf_exit"
_conf_after_crlf="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_before_crlf" = "$_conf_after_crlf" ]; then
    _crlf_unchanged="yes"
else
    _crlf_unchanged="no"
fi
assert_eq "test_migrator_rejects_crlf_line_endings: config not modified" "yes" "$_crlf_unchanged"
assert_pass_if_clean "test_migrator_rejects_crlf_line_endings"

# ── test_migrator_backup_detection_blocks_rerun ───────────────────────────────
# When a prior backup file already exists, the migrator must exit non-zero and
# leave both the config and the backup unmodified.
_snapshot_fail
_make_fixture "merge.strategy=pr
enforcement.strategy=ci"
# Pre-create backup from a prior failed run
printf 'merge.strategy=pr\nenforcement.strategy=ci\n' > "$FIXTURE_DIR/.claude/dso-config.conf.pre-migrate-backup"
_conf_before_bd="$(cat "$FIXTURE_CONF")"
_backup_before_bd="$(cat "$FIXTURE_DIR/.claude/dso-config.conf.pre-migrate-backup")"
_bd_exit=0
bash "$MIGRATE_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _bd_exit=$?
assert_ne "test_migrator_backup_detection_blocks_rerun: exits non-zero" "0" "$_bd_exit"
_conf_after_bd="$(cat "$FIXTURE_CONF" 2>/dev/null)"
if [ "$_conf_before_bd" = "$_conf_after_bd" ]; then
    _bd_conf_unchanged="yes"
else
    _bd_conf_unchanged="no"
fi
assert_eq "test_migrator_backup_detection_blocks_rerun: config not modified" "yes" "$_bd_conf_unchanged"
_backup_after_bd="$(cat "$FIXTURE_DIR/.claude/dso-config.conf.pre-migrate-backup" 2>/dev/null)"
if [ "$_backup_before_bd" = "$_backup_after_bd" ]; then
    _bd_backup_unchanged="yes"
else
    _bd_backup_unchanged="no"
fi
assert_eq "test_migrator_backup_detection_blocks_rerun: backup not overwritten" "yes" "$_bd_backup_unchanged"
assert_pass_if_clean "test_migrator_backup_detection_blocks_rerun"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
