#!/usr/bin/env bash
# tests/scripts/test-check-persistence-coverage.sh
# TDD tests for check-persistence-coverage.sh config-driven behavior:
#   1. dso-config.conf contains the required keys:
#      - persistence.source_patterns → non-empty list
#      - persistence.test_patterns   → non-empty list
#   2. scripts/check-persistence-coverage.sh:
#      - exists and is executable
#      - has zero hardcoded pattern arrays
#      - has no TESTING-MIGRATION.md reference
#      - reads patterns from config via read-config.sh --list
#      - exits 0 when persistence section is absent from config
#      - exits 0 with "nothing to check" when source_patterns is empty
#      - exits 0 when no persistence-critical files are changed
#      - exits 1 when persistence source files change without test changes
#
# Usage: bash tests/scripts/test-check-persistence-coverage.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
READ_CONFIG="$DSO_PLUGIN_DIR/scripts/read-config.sh"
PLUGIN_SCRIPT="$DSO_PLUGIN_DIR/scripts/check-persistence-coverage.sh"

# Create an inline fixture config instead of depending on project config
CONFIG="$(mktemp)"
_fixture_cleanup() { rm -f "$CONFIG"; }
cat > "$CONFIG" <<'FIXTURE'
stack=python-poetry
persistence.source_patterns=src/core/data_store.py
persistence.source_patterns=src/adapters/db/
persistence.test_patterns=tests/integration/.*test_.*_db_roundtrip
persistence.test_patterns=tests/integration/.*test_.*persistence
FIXTURE

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-persistence-coverage.sh ==="

# ── test_plugin_script_exists ─────────────────────────────────────────────────
# scripts/check-persistence-coverage.sh must exist
_snapshot_fail
if [[ -f "$PLUGIN_SCRIPT" ]]; then
    assert_eq "test_plugin_script_exists: file exists" "yes" "yes"
else
    assert_eq "test_plugin_script_exists: file exists" "yes" "no"
fi
assert_pass_if_clean "test_plugin_script_exists"

# ── test_plugin_script_is_executable ─────────────────────────────────────────
# scripts/check-persistence-coverage.sh must be executable
_snapshot_fail
if [[ -x "$PLUGIN_SCRIPT" ]]; then
    assert_eq "test_plugin_script_is_executable: executable" "yes" "yes"
else
    assert_eq "test_plugin_script_is_executable: executable" "yes" "no"
fi
assert_pass_if_clean "test_plugin_script_is_executable"

# ── test_no_hardcoded_source_patterns_array ───────────────────────────────────
# Script must NOT contain hardcoded PERSISTENCE_SOURCE_PATTERNS=( array declaration
_snapshot_fail
if grep -q 'PERSISTENCE_SOURCE_PATTERNS=(' "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_no_hardcoded_source_patterns_array: no hardcoded array" "no_hardcode" "hardcoded"
else
    assert_eq "test_no_hardcoded_source_patterns_array: no hardcoded array" "no_hardcode" "no_hardcode"
fi
assert_pass_if_clean "test_no_hardcoded_source_patterns_array"

# ── test_no_hardcoded_test_patterns_array ────────────────────────────────────
# Script must NOT contain hardcoded PERSISTENCE_TEST_PATTERNS=( array declaration
_snapshot_fail
if grep -q 'PERSISTENCE_TEST_PATTERNS=(' "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_no_hardcoded_test_patterns_array: no hardcoded array" "no_hardcode" "hardcoded"
else
    assert_eq "test_no_hardcoded_test_patterns_array: no hardcoded array" "no_hardcode" "no_hardcode"
fi
assert_pass_if_clean "test_no_hardcoded_test_patterns_array"

# ── test_no_testing_migration_reference ──────────────────────────────────────
# Script must NOT reference TESTING-MIGRATION.md
_snapshot_fail
if grep -q 'TESTING-MIGRATION' "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_no_testing_migration_reference: no TESTING-MIGRATION ref" "no_ref" "has_ref"
else
    assert_eq "test_no_testing_migration_reference: no TESTING-MIGRATION ref" "no_ref" "no_ref"
fi
assert_pass_if_clean "test_no_testing_migration_reference"

# ── test_reads_persistence_source_patterns ───────────────────────────────────
# Script must reference 'persistence.source_patterns' (reads from config)
_snapshot_fail
if grep -q 'persistence\.source_patterns' "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_reads_persistence_source_patterns: key referenced" "yes" "yes"
else
    assert_eq "test_reads_persistence_source_patterns: key referenced" "yes" "no"
fi
assert_pass_if_clean "test_reads_persistence_source_patterns"

# ── test_reads_persistence_test_patterns ─────────────────────────────────────
# Script must reference 'persistence.test_patterns' (reads from config)
_snapshot_fail
if grep -q 'persistence\.test_patterns' "$PLUGIN_SCRIPT" 2>/dev/null; then
    assert_eq "test_reads_persistence_test_patterns: key referenced" "yes" "yes"
else
    assert_eq "test_reads_persistence_test_patterns: key referenced" "yes" "no"
fi
assert_pass_if_clean "test_reads_persistence_test_patterns"

# ── test_config_persistence_source_patterns_present ──────────────────────────
# dso-config.conf must have persistence.source_patterns as a non-empty list
_snapshot_fail
sp_exit=0
sp_output=""
sp_output=$(bash "$READ_CONFIG" --list persistence.source_patterns "$CONFIG" 2>&1) || sp_exit=$?
sp_count=$(echo "$sp_output" | grep -c . || true)
assert_eq "test_config_persistence_source_patterns_present: exit 0" "0" "$sp_exit"
# Must have at least 1 entry
if [[ "$sp_count" -ge 1 ]]; then
    assert_eq "test_config_persistence_source_patterns_present: at least 1 entry" "yes" "yes"
else
    assert_eq "test_config_persistence_source_patterns_present: at least 1 entry" "yes" "no"
fi
assert_pass_if_clean "test_config_persistence_source_patterns_present"

# ── test_config_persistence_test_patterns_present ────────────────────────────
# dso-config.conf must have persistence.test_patterns as a non-empty list
_snapshot_fail
tp_exit=0
tp_output=""
tp_output=$(bash "$READ_CONFIG" --list persistence.test_patterns "$CONFIG" 2>&1) || tp_exit=$?
tp_count=$(echo "$tp_output" | grep -c . || true)
assert_eq "test_config_persistence_test_patterns_present: exit 0" "0" "$tp_exit"
# Must have at least 1 entry
if [[ "$tp_count" -ge 1 ]]; then
    assert_eq "test_config_persistence_test_patterns_present: at least 1 entry" "yes" "yes"
else
    assert_eq "test_config_persistence_test_patterns_present: at least 1 entry" "yes" "no"
fi
assert_pass_if_clean "test_config_persistence_test_patterns_present"

# ── Portability test helpers ──────────────────────────────────────────────────
# All portability tests run against isolated git repos in temp directories.
# They require:
#   1. CLAUDE_PLUGIN_PYTHON — points to python3 with pyyaml so read-config.sh
#      can parse yaml without resolving through the lockpick REPO_ROOT venv path.
#   2. Git identity configured in the isolated repo so commits work.
#   3. A proper `main` branch as merge-base target so git diff detects branch changes.

PORTABILITY_TMPDIR="$(mktemp -d)"
trap '_fixture_cleanup; rm -rf "$PORTABILITY_TMPDIR"' EXIT

# Resolve python3 with pyyaml: use the lockpick venv if available, else system python3.
_PORTABILITY_PYTHON=""
for _py_candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "python3"; do
    [[ -z "$_py_candidate" ]] && continue
    [[ "$_py_candidate" != "python3" ]] && [[ ! -f "$_py_candidate" ]] && continue
    if "$_py_candidate" -c "import yaml" 2>/dev/null; then
        _PORTABILITY_PYTHON="$_py_candidate"
        break
    fi
done

# Helper: create a minimal isolated git repo with a `main` branch and one base
# commit (the merge-base), then check out a feature branch for test additions.
_make_portability_repo() {
    local name="$1"
    local config_content="$2"
    local dir="$PORTABILITY_TMPDIR/$name"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@test.local"
    git -C "$dir" config user.name "Test"
    printf '%s\n' "$config_content" > "$dir/dso-config.conf"
    git -C "$dir" add dso-config.conf
    git -C "$dir" commit -m "base" -q
    git -C "$dir" checkout -q -b feature/test
    echo "$dir"
}

# Helper: run PLUGIN_SCRIPT from within a portability repo dir
# Sets CONFIG_FILE to the isolated repo's dso-config.conf so the plugin
# script does not fall back to the real repo's config via BASH_SOURCE resolution.
_run_portability() {
    local repo_dir="$1"
    shift
    (
        export CLAUDE_PLUGIN_PYTHON="${_PORTABILITY_PYTHON:-python3}"
        export CONFIG_FILE="$repo_dir/dso-config.conf"
        cd "$repo_dir"
        bash "$PLUGIN_SCRIPT" "$@" 2>&1
    )
}

# ── test_portability_no_workflow_config_file_exits_0 ─────────────────────────
# Portability: when dso-config.conf does not exist at all (CONFIG_FILE set
# to a non-existent path), script exits 0 with a warning message.
# This verifies SC5: missing config file is treated as a no-op.
_snapshot_fail
_p0_dir="$PORTABILITY_TMPDIR/no-config-file"
mkdir -p "$_p0_dir"
git -C "$_p0_dir" init -q -b main
git -C "$_p0_dir" config user.email "test@test.local"
git -C "$_p0_dir" config user.name "Test"
echo "# placeholder" > "$_p0_dir/placeholder.txt"
git -C "$_p0_dir" add placeholder.txt
git -C "$_p0_dir" commit -m "base" -q
git -C "$_p0_dir" checkout -q -b feature/test

no_config_exit=0
no_config_output=""
no_config_output=$(
    export CLAUDE_PLUGIN_PYTHON="${_PORTABILITY_PYTHON:-python3}"
    export CONFIG_FILE="$_p0_dir/dso-config.conf"  # file does NOT exist
    cd "$_p0_dir"
    bash "$PLUGIN_SCRIPT" 2>&1
) || no_config_exit=$?

assert_eq "test_portability_no_workflow_config_file_exits_0: exit code" "0" "$no_config_exit"
assert_contains "test_portability_no_workflow_config_file_exits_0: warning in output" \
    "not configured" "$no_config_output"
assert_pass_if_clean "test_portability_no_workflow_config_file_exits_0"

# ── test_portability_absent_config_exits_0 ───────────────────────────────────
# Portability: when persistence section is absent from config, script exits 0
# with a warning to stderr. This verifies graceful handling end-to-end.
_snapshot_fail
_p1_repo=$(_make_portability_repo "no-persistence-config" "$(cat <<'CONF'
stack=python-poetry
CONF
)")

absent_exit=0
absent_output=""
absent_output=$(_run_portability "$_p1_repo") || absent_exit=$?

assert_eq "test_portability_absent_config_exits_0: exit code" "0" "$absent_exit"
# Verify the absent-config branch was actually exercised (not the "no changed files" branch)
assert_contains "test_portability_absent_config_exits_0: INFO warning in output" \
    "not configured" "$absent_output"
assert_pass_if_clean "test_portability_absent_config_exits_0"

# ── test_portability_empty_source_patterns_exits_0 ───────────────────────────
# Portability: when persistence.source_patterns is empty, script exits 0 with
# "nothing to check" message.
_snapshot_fail
_p2_repo=$(_make_portability_repo "empty-source-patterns" "$(cat <<'CONF'
stack=python-poetry
persistence.test_patterns=tests/integration/.*test_.*_db_roundtrip
CONF
)")

empty_sp_exit=0
empty_sp_output=""
empty_sp_output=$(_run_portability "$_p2_repo") || empty_sp_exit=$?

assert_eq "test_portability_empty_source_patterns_exits_0: exit code" "0" "$empty_sp_exit"
# Verify the empty-source-patterns branch was actually exercised (not "no changed files")
assert_contains "test_portability_empty_source_patterns_exits_0: empty-patterns message" \
    "persistence.source_patterns not configured" "$empty_sp_output"
assert_pass_if_clean "test_portability_empty_source_patterns_exits_0"

# ── test_portability_absent_test_patterns ────────────────────────────────────
# Portability: when persistence.source_patterns is present but
# persistence.test_patterns key is absent from config, script exits 0 with
# an INFO message (not an error). This exercises the graceful fallback at the
# read_config --list persistence.test_patterns path.
_snapshot_fail
_p_absent_tp_repo=$(_make_portability_repo "absent-test-patterns" "$(cat <<'CONF'
stack=python-poetry
persistence.source_patterns=src/extraction/job_store.py
CONF
)")

absent_tp_exit=0
absent_tp_output=""
absent_tp_output=$(_run_portability "$_p_absent_tp_repo") || absent_tp_exit=$?

assert_eq "test_portability_absent_test_patterns: exit code" "0" "$absent_tp_exit"
assert_contains "test_portability_absent_test_patterns: INFO in output" \
    "not configured" "$absent_tp_output"
assert_pass_if_clean "test_portability_absent_test_patterns"

# ── test_portability_no_persistence_changes_exits_0 ──────────────────────────
# Portability: when persistence source patterns are configured but no matching
# files are changed on the branch, script exits 0.
_snapshot_fail
_p3_repo=$(_make_portability_repo "no-persistence-changes" "$(cat <<'CONF'
stack=python-poetry
persistence.source_patterns=src/extraction/job_store.py
persistence.test_patterns=tests/integration/.*test_.*_db_roundtrip
CONF
)")
# Add a non-persistence file change
echo "# readme" > "$_p3_repo/README.md"
git -C "$_p3_repo" add README.md
git -C "$_p3_repo" commit -m "non-persistence change" -q

no_change_exit=0
no_change_output=""
no_change_output=$(_run_portability "$_p3_repo") || no_change_exit=$?

assert_eq "test_portability_no_persistence_changes_exits_0: exit code" "0" "$no_change_exit"
assert_pass_if_clean "test_portability_no_persistence_changes_exits_0"

# ── test_portability_source_changed_no_tests_exits_1 ─────────────────────────
# Portability: when a persistence source file changes but no test files match,
# script exits 1 (coverage failure).
_snapshot_fail
_p4_repo=$(_make_portability_repo "source-no-tests" "$(cat <<'CONF'
stack=python-poetry
persistence.source_patterns=src/extraction/job_store.py
persistence.test_patterns=tests/integration/.*test_.*_db_roundtrip
CONF
)")
# Add a persistence source file change — no test changes
mkdir -p "$_p4_repo/src/extraction"
echo "# job store" > "$_p4_repo/src/extraction/job_store.py"
git -C "$_p4_repo" add "src/extraction/job_store.py"
git -C "$_p4_repo" commit -m "change job_store" -q

source_no_test_exit=0
source_no_test_output=""
source_no_test_output=$(_run_portability "$_p4_repo") || source_no_test_exit=$?

assert_eq "test_portability_source_changed_no_tests_exits_1: exit code" "1" "$source_no_test_exit"
assert_contains "test_portability_source_changed_no_tests_exits_1: FAILED in output" \
    "FAILED" "$source_no_test_output"
assert_pass_if_clean "test_portability_source_changed_no_tests_exits_1"

# ── test_portability_source_and_test_changed_exits_0 ─────────────────────────
# Portability: when a persistence source file changes AND a matching test file
# changes, script exits 0 (coverage satisfied).
_snapshot_fail
_p5_repo=$(_make_portability_repo "source-with-tests" "$(cat <<'CONF'
stack=python-poetry
persistence.source_patterns=src/extraction/job_store.py
persistence.test_patterns=tests/integration/.*test_.*_db_roundtrip
CONF
)")
# Add both a persistence source file AND a matching test file
mkdir -p "$_p5_repo/src/extraction"
echo "# job store" > "$_p5_repo/src/extraction/job_store.py"
mkdir -p "$_p5_repo/tests/integration"
echo "# test" > "$_p5_repo/tests/integration/test_job_store_db_roundtrip.py"
git -C "$_p5_repo" add "src/extraction/job_store.py" "tests/integration/test_job_store_db_roundtrip.py"
git -C "$_p5_repo" commit -m "change job_store with tests" -q

with_test_exit=0
with_test_output=""
with_test_output=$(_run_portability "$_p5_repo") || with_test_exit=$?

assert_eq "test_portability_source_and_test_changed_exits_0: exit code" "0" "$with_test_exit"
assert_contains "test_portability_source_and_test_changed_exits_0: passed in output" \
    "passed" "$with_test_output"
assert_pass_if_clean "test_portability_source_and_test_changed_exits_0"

print_summary
