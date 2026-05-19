#!/usr/bin/env bash
# tests/scripts/test-check-recipe-engines.sh
# Behavioral tests for plugins/dso/scripts/sprint/check-recipe-engines.sh.
#
# Testing mode: RED — check-recipe-engines.sh does not yet exist.
# All tests MUST FAIL before the script is implemented.
#
# The script under test reads:
#   RECIPE_REGISTRY_PATH  — path to the recipe-registry.yaml (injectable for test isolation)
#   TASK_LIST_FILE        — path to a JSON array of tasks (injectable for test isolation)
#
# Usage: bash tests/scripts/test-check-recipe-engines.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sprint/check-recipe-engines.sh"
REGISTRY_PATH="$REPO_ROOT/plugins/dso/recipes/recipe-registry.yaml"
FIXTURE_TASK_LIST="$REPO_ROOT/tests/fixtures/task-list-with-recipe.json"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-check-recipe-engines.sh ==="

# ── Cleanup ────────────────────────────────────────────────────────────────────
_TMPFILES=()
_TMPDIRS=()
_cleanup() {
    for f in "${_TMPFILES[@]}"; do rm -f "$f"; done
    for d in "${_TMPDIRS[@]}"; do rm -rf "$d"; done
}
trap _cleanup EXIT

# ── test_script_exists_and_executable ─────────────────────────────────────────
# Given: the repo has been set up with check-recipe-engines.sh
# When:  we check whether the script file exists and has the executable bit set
# Then:  both conditions are true
_snapshot_fail
_script_exists=0
_script_executable=0
if [[ -f "$SCRIPT" ]]; then _script_exists=1; fi
if [[ -x "$SCRIPT" ]]; then _script_executable=1; fi
assert_eq "test_script_exists_and_executable: script must exist" "1" "$_script_exists"
assert_eq "test_script_exists_and_executable: script must be executable" "1" "$_script_executable"
assert_pass_if_clean "test_script_exists_and_executable"

# ── test_missing_engine_detected ──────────────────────────────────────────────
# Given: a task list that includes a recipe:add-parameter task (rope engine)
# AND:   rope is NOT installed (simulated by PATH containing a stub that exits 1)
# When:  check-recipe-engines.sh is invoked with the fixture task list
# Then:  the script outputs a line containing "MISSING_ENGINE: rope minimum:1.7.0"
# AND:   exits non-zero (exit 1)
_snapshot_fail
_stub_dir="$(mktemp -d /tmp/test-check-recipe-engines-stub.XXXXXX)"
_TMPDIRS+=("$_stub_dir")
# Stub: python3/rope unavailable — rope import fails
cat > "$_stub_dir/python3" <<'STUB'
#!/usr/bin/env bash
# Stub python3 that simulates rope not installed
if [[ "$*" == *"import rope"* ]] || [[ "$*" == *"-c"* ]]; then
    # If checking rope version, fail with ModuleNotFoundError
    echo "ModuleNotFoundError: No module named 'rope'" >&2
    exit 1
fi
# Pass through any other invocations to the real python3
exec /usr/bin/env python3 "$@"
STUB
chmod +x "$_stub_dir/python3"

_missing_output=""
_missing_exit=0
_missing_output=$(
    RECIPE_REGISTRY_PATH="$REGISTRY_PATH" \
    TASK_LIST_FILE="$FIXTURE_TASK_LIST" \
    PATH="$_stub_dir:$PATH" \
    bash "$SCRIPT" 2>&1
) || _missing_exit=$?

assert_ne "test_missing_engine_detected: script must exit non-zero when engine missing" "0" "$_missing_exit"
assert_contains "test_missing_engine_detected: output must contain MISSING_ENGINE: rope minimum:1.7.0" \
    "MISSING_ENGINE: rope minimum:1.7.0" "$_missing_output"
assert_pass_if_clean "test_missing_engine_detected"

# ── test_no_recipe_tasks_is_noop ──────────────────────────────────────────────
# Given: a task list with NO recipe: tasks (no recipe tag on any task)
# When:  check-recipe-engines.sh is invoked
# Then:  the script outputs "NO_RECIPE_TASKS" and exits 0
_snapshot_fail
_no_recipe_file="$(mktemp /tmp/test-check-recipe-engines-no-recipe.XXXXXX.json)"
_TMPFILES+=("$_no_recipe_file")
cat > "$_no_recipe_file" <<'JSON'
[
  {"id": "task-001", "title": "Write unit tests", "tags": [], "status": "open"},
  {"id": "task-002", "title": "Lint Python files", "tags": ["lint"], "status": "open"}
]
JSON

_noop_output=""
_noop_exit=0
_noop_output=$(
    RECIPE_REGISTRY_PATH="$REGISTRY_PATH" \
    TASK_LIST_FILE="$_no_recipe_file" \
    bash "$SCRIPT" 2>&1
) || _noop_exit=$?

assert_eq "test_no_recipe_tasks_is_noop: must exit 0 for no-recipe task list" "0" "$_noop_exit"
assert_contains "test_no_recipe_tasks_is_noop: output must contain NO_RECIPE_TASKS" \
    "NO_RECIPE_TASKS" "$_noop_output"
assert_pass_if_clean "test_no_recipe_tasks_is_noop"

# ── test_outdated_engine_detected ─────────────────────────────────────────────
# Given: a task list with recipe:add-parameter (rope)
# AND:   rope IS installed but reports version 1.5.0 (below minimum 1.7.0)
# When:  check-recipe-engines.sh is invoked
# Then:  output contains "OUTDATED_ENGINE: rope found:1.5.0 minimum:1.7.0"
# AND:   exits non-zero
_snapshot_fail
_outdated_stub_dir="$(mktemp -d /tmp/test-check-recipe-engines-outdated.XXXXXX)"
_TMPDIRS+=("$_outdated_stub_dir")
# Stub python3 that reports rope version 1.5.0
cat > "$_outdated_stub_dir/python3" <<'STUB'
#!/usr/bin/env bash
# Stub python3: rope installed but at version 1.5.0 (outdated)
if [[ "$*" == *"-c"* ]]; then
    # Print version string for rope
    echo "1.5.0"
    exit 0
fi
exec /usr/bin/env python3 "$@"
STUB
chmod +x "$_outdated_stub_dir/python3"

_outdated_output=""
_outdated_exit=0
_outdated_output=$(
    RECIPE_REGISTRY_PATH="$REGISTRY_PATH" \
    TASK_LIST_FILE="$FIXTURE_TASK_LIST" \
    PATH="$_outdated_stub_dir:$PATH" \
    bash "$SCRIPT" 2>&1
) || _outdated_exit=$?

assert_ne "test_outdated_engine_detected: must exit non-zero for outdated engine" "0" "$_outdated_exit"
assert_contains "test_outdated_engine_detected: output must contain OUTDATED_ENGINE: rope found:1.5.0 minimum:1.7.0" \
    "OUTDATED_ENGINE: rope found:1.5.0 minimum:1.7.0" "$_outdated_output"
assert_pass_if_clean "test_outdated_engine_detected"

# ── test_engines_ok_all_present_and_current ───────────────────────────────────
# Given: a task list with recipe:add-parameter (rope)
# AND:   rope IS installed and reports version 1.9.0 (above minimum 1.7.0)
# When:  check-recipe-engines.sh is invoked
# Then:  output contains "ENGINES_OK" and exits 0
_snapshot_fail
_ok_stub_dir="$(mktemp -d /tmp/test-check-recipe-engines-ok.XXXXXX)"
_TMPDIRS+=("$_ok_stub_dir")
# Stub python3 that reports rope version 1.9.0 (satisfies >=1.7.0)
cat > "$_ok_stub_dir/python3" <<'STUB'
#!/usr/bin/env bash
# Stub python3: rope installed and at version 1.9.0 (current)
if [[ "$*" == *"-c"* ]]; then
    echo "1.9.0"
    exit 0
fi
exec /usr/bin/env python3 "$@"
STUB
chmod +x "$_ok_stub_dir/python3"

_ok_output=""
_ok_exit=0
_ok_output=$(
    RECIPE_REGISTRY_PATH="$REGISTRY_PATH" \
    TASK_LIST_FILE="$FIXTURE_TASK_LIST" \
    PATH="$_ok_stub_dir:$PATH" \
    bash "$SCRIPT" 2>&1
) || _ok_exit=$?

assert_eq "test_engines_ok_all_present_and_current: must exit 0 when all engines OK" "0" "$_ok_exit"
assert_contains "test_engines_ok_all_present_and_current: output must contain ENGINES_OK" \
    "ENGINES_OK" "$_ok_output"
assert_pass_if_clean "test_engines_ok_all_present_and_current"

# ── test_missing_engines_list_emitted ─────────────────────────────────────────
# Given: a task list with multiple recipe: tasks where some engines are missing
# AND:   rope is NOT installed (simulated by failing stub)
# When:  check-recipe-engines.sh is invoked
# Then:  output contains a line of the form "MISSING_ENGINES_LIST=rope" (or comma-separated engines)
#        so that S5 fallback logic can parse the env-var-style line
_snapshot_fail
# Reuse the _stub_dir from test_missing_engine_detected (rope missing)
_list_stub_dir="$(mktemp -d /tmp/test-check-recipe-engines-list.XXXXXX)"
_TMPDIRS+=("$_list_stub_dir")
cat > "$_list_stub_dir/python3" <<'STUB'
#!/usr/bin/env bash
# Stub python3: rope not installed
if [[ "$*" == *"-c"* ]]; then
    echo "ModuleNotFoundError: No module named 'rope'" >&2
    exit 1
fi
exec /usr/bin/env python3 "$@"
STUB
chmod +x "$_list_stub_dir/python3"

_list_output=""
_list_exit=0
_list_output=$(
    RECIPE_REGISTRY_PATH="$REGISTRY_PATH" \
    TASK_LIST_FILE="$FIXTURE_TASK_LIST" \
    PATH="$_list_stub_dir:$PATH" \
    bash "$SCRIPT" 2>&1
) || _list_exit=$?

assert_contains "test_missing_engines_list_emitted: output must contain MISSING_ENGINES_LIST=" \
    "MISSING_ENGINES_LIST=" "$_list_output"
assert_pass_if_clean "test_missing_engines_list_emitted"

# ── test_missing_registry_exits_nonzero ───────────────────────────────────────
# Given: RECIPE_REGISTRY_PATH points to a non-existent file
# When:  check-recipe-engines.sh is invoked
# Then:  the script emits an error message to stderr referencing the missing file
# AND:   exits non-zero
_snapshot_fail
_bad_registry="/tmp/missing-registry-${RANDOM}.yaml"
_reg_stderr=""
_reg_exit=0
# Capture stderr separately
_reg_tmpout="$(mktemp /tmp/test-check-recipe-engines-reg.XXXXXX)"
_TMPFILES+=("$_reg_tmpout")
{
    RECIPE_REGISTRY_PATH="$_bad_registry" \
    TASK_LIST_FILE="$FIXTURE_TASK_LIST" \
    bash "$SCRIPT" 2>"$_reg_tmpout"
} || _reg_exit=$?
_reg_stderr="$(cat "$_reg_tmpout")"

assert_ne "test_missing_registry_exits_nonzero: must exit non-zero for missing registry" "0" "$_reg_exit"
# Expect stderr to contain a reference to the missing registry path or a standard error message
_reg_has_error=0
if [[ "$_reg_stderr" == *"registry not found"* ]] || \
   [[ "$_reg_stderr" == *"Error:"* ]] || \
   [[ "$_reg_stderr" == *"$_bad_registry"* ]]; then
    _reg_has_error=1
fi
assert_eq "test_missing_registry_exits_nonzero: stderr must contain registry error message" "1" "$_reg_has_error"
assert_pass_if_clean "test_missing_registry_exits_nonzero"

print_summary
