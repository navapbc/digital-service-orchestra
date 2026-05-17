#!/usr/bin/env bash
# tests/scripts/test-read-config-flat.sh
# TDD tests for the flat KEY=VALUE config reader (read-config.sh rewrite).
#
# Tests the pure-bash read-config.sh against .conf fixture files.
# No Python dependency required — tests exercise grep/cut logic only.
#
# Usage: bash tests/scripts/test-read-config-flat.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/read-config.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-read-config-flat.sh ==="

# Create temp dir for fixture files
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# Write a .conf fixture (flat KEY=VALUE format)
FIXTURE_CONF="$TMPDIR_FIXTURE/dso-config.conf"
cat > "$FIXTURE_CONF" <<'CONF'
# dso-config.conf fixture for tests
version=1.0.0
stack=python-poetry
commands.test=make test
commands.lint=make lint
format.extensions=.py
format.source_dirs=app/src
format.source_dirs=app/tests
ci.fast_gate_job=Fast Gate
# this is a comment line
staging.url=http://example.com/stage?mode=full&env=prod
merge.message_exclusion_pattern=^chore: post-merge cleanup
database.base_port=5432
inline.equals.value=a=b=c
review.max_cycles=3
CONF


# ── test_scalar_read ─────────────────────────────────────────────────────────
# Reads a scalar key from the .conf file.
_snapshot_fail
actual=$(bash "$SCRIPT" commands.test "$FIXTURE_CONF")
assert_eq "test_scalar_read" "make test" "$actual"
assert_pass_if_clean "test_scalar_read"

# ── test_list_read ───────────────────────────────────────────────────────────
# Reads a list key with --list; single entry returns one line.
_snapshot_fail
actual=$(bash "$SCRIPT" --list format.extensions "$FIXTURE_CONF")
assert_eq "test_list_read" ".py" "$actual"
assert_pass_if_clean "test_list_read"

# ── test_list_multi_value ────────────────────────────────────────────────────
# Reads a list key with --list; multiple entries return multiple lines.
_snapshot_fail
actual=$(bash "$SCRIPT" --list format.source_dirs "$FIXTURE_CONF")
expected="app/src
app/tests"
assert_eq "test_list_multi_value" "$expected" "$actual"
assert_pass_if_clean "test_list_multi_value"

# ── test_missing_key_scalar ──────────────────────────────────────────────────
# Missing key in scalar mode returns empty string, exit 0.
_snapshot_fail
actual=$(bash "$SCRIPT" nonexistent.key "$FIXTURE_CONF")
rc=$?
assert_eq "test_missing_key_scalar value" "" "$actual"
assert_eq "test_missing_key_scalar exit" "0" "$rc"
assert_pass_if_clean "test_missing_key_scalar"

# ── test_missing_key_list ────────────────────────────────────────────────────
# Missing key in --list mode returns exit 1.
_snapshot_fail
actual=$(bash "$SCRIPT" --list nonexistent.key "$FIXTURE_CONF" 2>/dev/null)
rc=$?
assert_eq "test_missing_key_list exit" "1" "$rc"
assert_pass_if_clean "test_missing_key_list"

# ── test_missing_file ────────────────────────────────────────────────────────
# Missing config file returns empty string, exit 0.
_snapshot_fail
actual=$(bash "$SCRIPT" commands.test "$TMPDIR_FIXTURE/nonexistent.conf")
rc=$?
assert_eq "test_missing_file value" "" "$actual"
assert_eq "test_missing_file exit" "0" "$rc"
assert_pass_if_clean "test_missing_file"

# ── test_config_first_form ───────────────────────────────────────────────────
# Config-first form: read-config.sh /path/to/config.conf <key> works.
_snapshot_fail
actual=$(bash "$SCRIPT" "$FIXTURE_CONF" commands.test)
assert_eq "test_config_first_form" "make test" "$actual"
assert_pass_if_clean "test_config_first_form"


# ── test_empty_list ──────────────────────────────────────────────────────────
# A key that exists but has no repeated values in --list mode:
# scalar degradation means single value output, exit 0.
_snapshot_fail
actual=$(bash "$SCRIPT" --list commands.test "$FIXTURE_CONF")
rc=$?
assert_eq "test_empty_list exit" "0" "$rc"
assert_eq "test_empty_list value" "make test" "$actual"
assert_pass_if_clean "test_empty_list"

# ── test_comment_lines_ignored ───────────────────────────────────────────────
# Lines starting with # are not returned as values.
_snapshot_fail
# "# this is a comment line" should not be returned for any key
actual=$(bash "$SCRIPT" --list "# this is a comment line" "$FIXTURE_CONF" 2>/dev/null)
rc=$?
# The key doesn't exist → list mode should exit 1
assert_eq "test_comment_lines_ignored exit" "1" "$rc"
assert_pass_if_clean "test_comment_lines_ignored"

# ── test_inline_values_with_equals ───────────────────────────────────────────
# Values containing = signs are preserved (e.g., key=a=b=c returns a=b=c).
_snapshot_fail
actual=$(bash "$SCRIPT" inline.equals.value "$FIXTURE_CONF")
assert_eq "test_inline_values_with_equals" "a=b=c" "$actual"
assert_pass_if_clean "test_inline_values_with_equals"

# ── test_review_max_cycles ─────────────────────────────────────────────────────
# Reads the review.max_cycles numeric config key.
_snapshot_fail
actual=$(bash "$SCRIPT" review.max_cycles "$FIXTURE_CONF")
assert_eq "test_review_max_cycles" "3" "$actual"
assert_pass_if_clean "test_review_max_cycles"

# ── test_review_max_cycles_default ────────────────────────────────────────────
# When review.max_cycles is absent, scalar mode returns empty (caller applies default).
_snapshot_fail
NO_REVIEW_CONF="$TMPDIR_FIXTURE/no-review.conf"
cat > "$NO_REVIEW_CONF" <<'CONF2'
commands.test=make test
CONF2
actual=$(bash "$SCRIPT" review.max_cycles "$NO_REVIEW_CONF")
rc=$?
assert_eq "test_review_max_cycles_default value" "" "$actual"
assert_eq "test_review_max_cycles_default exit" "0" "$rc"
assert_pass_if_clean "test_review_max_cycles_default"

# ── test_review_max_resolution_attempts_alias ─────────────────────────────────
# Backward-compat: when ONLY review.max_resolution_attempts is set (old key),
# reading review.max_cycles should return the old value via alias shim.
# RED: this test fails until read-config.sh shim is added (T2).
_snapshot_fail
OLD_KEY_CONF="$TMPDIR_FIXTURE/old-key.conf"
cat > "$OLD_KEY_CONF" <<'CONF3'
commands.test=make test
review.max_resolution_attempts=7
CONF3
actual=$(DSO_DEPRECATION_QUIET=1 bash "$SCRIPT" review.max_cycles "$OLD_KEY_CONF")
rc=$?
assert_eq "test_review_max_resolution_attempts_alias value" "7" "$actual"
assert_eq "test_review_max_resolution_attempts_alias exit" "0" "$rc"
assert_pass_if_clean "test_review_max_resolution_attempts_alias"

# ── test_review_max_resolution_attempts_alias_deprecation_warning ─────────────
# Backward-compat alias emits a deprecation warning to stderr (without quiet flag).
# RED: this test fails until read-config.sh shim is added (T2).
_snapshot_fail
stderr_out=$(bash "$SCRIPT" review.max_cycles "$OLD_KEY_CONF" 2>&1 >/dev/null)
assert_contains "test_review_max_resolution_attempts_alias_deprecation_warning" "deprecated" "$stderr_out"
assert_pass_if_clean "test_review_max_resolution_attempts_alias_deprecation_warning"

# ── test_review_max_cycles_takes_precedence ───────────────────────────────────
# When BOTH review.max_cycles and review.max_resolution_attempts are set,
# the new key (review.max_cycles) wins.
# RED: this test fails until read-config.sh shim is added (T2).
_snapshot_fail
BOTH_KEYS_CONF="$TMPDIR_FIXTURE/both-keys.conf"
cat > "$BOTH_KEYS_CONF" <<'CONF4'
commands.test=make test
review.max_cycles=4
review.max_resolution_attempts=7
CONF4
actual=$(DSO_DEPRECATION_QUIET=1 bash "$SCRIPT" review.max_cycles "$BOTH_KEYS_CONF")
assert_eq "test_review_max_cycles_takes_precedence" "4" "$actual"
assert_pass_if_clean "test_review_max_cycles_takes_precedence"

# ── test_no_yaml_fallback ─────────────────────────────────────────────────────
# When the specified config file does not exist, script exits 0 with empty output.
# (YAML support has been removed — .yaml files are no longer read as default config.)
_snapshot_fail
FALLBACK_DIR="$TMPDIR_FIXTURE/fallback"
mkdir -p "$FALLBACK_DIR"
cat > "$FALLBACK_DIR/workflow-config.yaml" <<'YAML'
commands:
  test: "make test"
YAML
# Point WORKFLOW_CONFIG_FILE at the .conf path (which doesn't exist — only .yaml does).
actual=$(WORKFLOW_CONFIG_FILE="$FALLBACK_DIR/dso-config.conf" bash "$SCRIPT" commands.test)
rc=$?
assert_eq "test_no_yaml_fallback value" "" "$actual"
assert_eq "test_no_yaml_fallback exit" "0" "$rc"
assert_pass_if_clean "test_no_yaml_fallback"

# ── test_conf_is_sole_format ──────────────────────────────────────────────────
# .conf is the only supported format; the value from .conf is returned.
_snapshot_fail
CONF_DIR="$TMPDIR_FIXTURE/confonly"
mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/dso-config.conf" <<'CONF'
commands.test=make test-from-conf
CONF
actual=$(WORKFLOW_CONFIG_FILE="$CONF_DIR/dso-config.conf" bash "$SCRIPT" commands.test)
assert_eq "test_conf_is_sole_format" "make test-from-conf" "$actual"
assert_pass_if_clean "test_conf_is_sole_format"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
