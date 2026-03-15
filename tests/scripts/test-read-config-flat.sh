#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-read-config-flat.sh
# TDD tests for the flat KEY=VALUE config reader (read-config.sh rewrite).
#
# Tests the pure-bash read-config.sh against .conf fixture files.
# No Python dependency required — tests exercise grep/cut logic only.
#
# Usage: bash lockpick-workflow/tests/scripts/test-read-config-flat.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/read-config.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-read-config-flat.sh ==="

# Create temp dir for fixture files
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# Write a .conf fixture (flat KEY=VALUE format)
FIXTURE_CONF="$TMPDIR_FIXTURE/workflow-config.conf"
cat > "$FIXTURE_CONF" <<'CONF'
# workflow-config.conf fixture for tests
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
CONF

# Write a .yaml fixture (for fallback / backward compat tests)
FIXTURE_YAML="$TMPDIR_FIXTURE/workflow-config.yaml"
cat > "$FIXTURE_YAML" <<'YAML'
commands:
  test: "make test"
  lint: "make lint"
stack: python-poetry
YAML

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

# ── test_config_first_form_yaml ──────────────────────────────────────────────
# Config-first form with .yaml extension still works (backward compat).
_snapshot_fail
actual=$(bash "$SCRIPT" "$FIXTURE_YAML" commands.test)
assert_eq "test_config_first_form_yaml" "make test" "$actual"
assert_pass_if_clean "test_config_first_form_yaml"

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

# ── test_fallback_to_yaml ────────────────────────────────────────────────────
# When .conf not found but .yaml exists in same dir, falls back to .yaml.
_snapshot_fail
# Create a dir with only .yaml, no .conf
FALLBACK_DIR="$TMPDIR_FIXTURE/fallback"
mkdir -p "$FALLBACK_DIR"
cp "$FIXTURE_YAML" "$FALLBACK_DIR/workflow-config.yaml"
actual=$(CLAUDE_PLUGIN_ROOT="$FALLBACK_DIR" bash "$SCRIPT" commands.test)
assert_eq "test_fallback_to_yaml" "make test" "$actual"
assert_pass_if_clean "test_fallback_to_yaml"

# ── test_conf_takes_precedence_over_yaml ─────────────────────────────────────
# When BOTH .conf and .yaml exist, .conf is used (not .yaml).
_snapshot_fail
BOTH_DIR="$TMPDIR_FIXTURE/both"
mkdir -p "$BOTH_DIR"
# .conf has a different value than .yaml for commands.test
cat > "$BOTH_DIR/workflow-config.conf" <<'CONF'
commands.test=make test-from-conf
CONF
cat > "$BOTH_DIR/workflow-config.yaml" <<'YAML'
commands:
  test: "make test-from-yaml"
YAML
actual=$(CLAUDE_PLUGIN_ROOT="$BOTH_DIR" bash "$SCRIPT" commands.test)
assert_eq "test_conf_takes_precedence_over_yaml" "make test-from-conf" "$actual"
assert_pass_if_clean "test_conf_takes_precedence_over_yaml"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
