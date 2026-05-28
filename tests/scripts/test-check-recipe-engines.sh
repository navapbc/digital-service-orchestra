#!/usr/bin/env bash
# tests/scripts/test-check-recipe-engines.sh
# Behavioral tests for plugins/dso/scripts/sprint/check-recipe-engines.sh.
#
# Testing mode: GREEN — check-recipe-engines.sh is implemented.
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
_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-stub.XXXXXX")"
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
_no_recipe_file="$(mktemp "${TMPDIR:-/tmp}/test-check-recipe-engines-no-recipe.XXXXXX".json)"
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
_outdated_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-outdated.XXXXXX")"
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
_ok_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-ok.XXXXXX")"
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
_list_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-list.XXXXXX")"
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
_reg_tmpout="$(mktemp "${TMPDIR:-/tmp}/test-check-recipe-engines-reg.XXXXXX")"
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

# ── test_tsmorph_installed_detected_via_node_require ─────────────────────────
# Given: a task list with a recipe that uses the ts-morph engine
# AND:   node is available AND ts-morph package is accessible at version 20.0.0
#        (simulated via node stub that intercepts ts-morph package require)
# When:  check-recipe-engines.sh is invoked
# Then:  the script outputs "ENGINES_OK" and exits 0
# (RED: current wildcard case uses 'command -v ts-morph' which always fails)
_snapshot_fail
_tsm_ok_reg="$(mktemp "${TMPDIR:-/tmp}/test-check-recipe-engines-tsm-reg.XXXXXX".yaml)"
_TMPFILES+=("$_tsm_ok_reg")
cat > "$_tsm_ok_reg" <<'YAML'
recipes:
  - name: refactor-typescript
    language: typescript
    engine: ts-morph
    adapter: ts-morph-adapter.sh
    capability_description: "TypeScript refactoring via ts-morph"
    scope: cross-file
    min_engine_version: "17.0.0"
    installation_instructions: "npm install ts-morph@>=17"
YAML

_tsm_ok_tasks="$(mktemp "${TMPDIR:-/tmp}/test-check-recipe-engines-tsm-tasks.XXXXXX".json)"
_TMPFILES+=("$_tsm_ok_tasks")
cat > "$_tsm_ok_tasks" <<'JSON'
[{"id": "task-ts-001", "title": "Refactor TS", "tags": ["recipe:refactor-typescript"], "status": "open"}]
JSON

# Stub node: ts-morph package present at version 20.0.0
_tsm_ok_stub="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-tsm-ok.XXXXXX")"
_TMPDIRS+=("$_tsm_ok_stub")
cat > "$_tsm_ok_stub/node" <<'STUB'
#!/usr/bin/env bash
# Stub node: ts-morph installed at version 20.0.0
if [[ "$*" == *"ts-morph"* ]]; then
    printf "20.0.0"
    exit 0
fi
exec /usr/bin/env node "$@"
STUB
chmod +x "$_tsm_ok_stub/node"

_tsm_ok_output=""
_tsm_ok_exit=0
_tsm_ok_output=$(
    RECIPE_REGISTRY_PATH="$_tsm_ok_reg" \
    TASK_LIST_FILE="$_tsm_ok_tasks" \
    PATH="$_tsm_ok_stub:$PATH" \
    bash "$SCRIPT" 2>&1
) || _tsm_ok_exit=$?

assert_eq "test_tsmorph_installed_detected_via_node_require: must exit 0 when ts-morph installed" "0" "$_tsm_ok_exit"
assert_contains "test_tsmorph_installed_detected_via_node_require: output must contain ENGINES_OK" \
    "ENGINES_OK" "$_tsm_ok_output"
assert_pass_if_clean "test_tsmorph_installed_detected_via_node_require"

# ── test_tsmorph_missing_package_reports_missing_engine ──────────────────────
# Given: a task list with a recipe that uses the ts-morph engine
# AND:   node is available but ts-morph package is NOT installed (require fails)
# When:  check-recipe-engines.sh is invoked
# Then:  output contains "MISSING_ENGINE: ts-morph minimum:17.0.0" and exits non-zero
_snapshot_fail
_tsm_miss_stub="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-tsm-miss.XXXXXX")"
_TMPDIRS+=("$_tsm_miss_stub")
cat > "$_tsm_miss_stub/node" <<'STUB'
#!/usr/bin/env bash
# Stub node: ts-morph package NOT installed
if [[ "$*" == *"ts-morph"* ]]; then
    echo "Cannot find module 'ts-morph/package.json'" >&2
    exit 1
fi
exec /usr/bin/env node "$@"
STUB
chmod +x "$_tsm_miss_stub/node"

_tsm_miss_output=""
_tsm_miss_exit=0
_tsm_miss_output=$(
    RECIPE_REGISTRY_PATH="$_tsm_ok_reg" \
    TASK_LIST_FILE="$_tsm_ok_tasks" \
    PATH="$_tsm_miss_stub:$PATH" \
    bash "$SCRIPT" 2>&1
) || _tsm_miss_exit=$?

assert_ne "test_tsmorph_missing_package_reports_missing_engine: must exit non-zero" "0" "$_tsm_miss_exit"
assert_contains "test_tsmorph_missing_package_reports_missing_engine: output must contain MISSING_ENGINE: ts-morph" \
    "MISSING_ENGINE: ts-morph minimum:17.0.0" "$_tsm_miss_output"
assert_pass_if_clean "test_tsmorph_missing_package_reports_missing_engine"

# ── test_tsmorph_outdated_version_detected ───────────────────────────────────
# Given: a task list with a recipe that uses the ts-morph engine
# AND:   ts-morph is installed but at version 15.0.0 (below minimum 17.0.0)
# When:  check-recipe-engines.sh is invoked
# Then:  output contains "OUTDATED_ENGINE: ts-morph found:15.0.0 minimum:17.0.0" and exits non-zero
_snapshot_fail
_tsm_old_stub="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-tsm-old.XXXXXX")"
_TMPDIRS+=("$_tsm_old_stub")
cat > "$_tsm_old_stub/node" <<'STUB'
#!/usr/bin/env bash
# Stub node: ts-morph installed at version 15.0.0 (outdated)
if [[ "$*" == *"ts-morph"* ]]; then
    printf "15.0.0"
    exit 0
fi
exec /usr/bin/env node "$@"
STUB
chmod +x "$_tsm_old_stub/node"

_tsm_old_output=""
_tsm_old_exit=0
_tsm_old_output=$(
    RECIPE_REGISTRY_PATH="$_tsm_ok_reg" \
    TASK_LIST_FILE="$_tsm_ok_tasks" \
    PATH="$_tsm_old_stub:$PATH" \
    bash "$SCRIPT" 2>&1
) || _tsm_old_exit=$?

assert_ne "test_tsmorph_outdated_version_detected: must exit non-zero for outdated ts-morph" "0" "$_tsm_old_exit"
assert_contains "test_tsmorph_outdated_version_detected: output must contain OUTDATED_ENGINE" \
    "OUTDATED_ENGINE: ts-morph found:15.0.0 minimum:17.0.0" "$_tsm_old_output"
assert_pass_if_clean "test_tsmorph_outdated_version_detected"

# ── test_cli_engine_outdated_version_detected ─────────────────────────────────
# Given: a task list with a recipe that uses the isort CLI engine (min 5.0.0)
# AND:   isort IS installed but reports version 4.3.0 (below minimum 5.0.0)
# When:  check-recipe-engines.sh is invoked
# Then:  output contains "OUTDATED_ENGINE: isort found:4.3.0 minimum:5.0.0" and exits non-zero
# (RED: current wildcard case only checks binary presence, never version)
_snapshot_fail
_cli_outdated_reg="$(mktemp "${TMPDIR:-/tmp}/test-check-recipe-engines-cli-reg.XXXXXX".yaml)"
_TMPFILES+=("$_cli_outdated_reg")
cat > "$_cli_outdated_reg" <<'YAML'
recipes:
  - name: sort-imports
    language: python
    engine: isort
    adapter: isort-adapter.sh
    capability_description: "Sort Python imports"
    scope: single-file
    min_engine_version: "5.0.0"
    installation_instructions: "pip install isort>=5"
YAML

_cli_outdated_tasks="$(mktemp "${TMPDIR:-/tmp}/test-check-recipe-engines-cli-tasks.XXXXXX".json)"
_TMPFILES+=("$_cli_outdated_tasks")
cat > "$_cli_outdated_tasks" <<'JSON'
[{"id": "task-isort-001", "title": "Sort imports", "tags": ["recipe:sort-imports"], "status": "open"}]
JSON

# Stub isort binary reporting outdated version 4.3.0
_cli_outdated_stub="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-cli-old.XXXXXX")"
_TMPDIRS+=("$_cli_outdated_stub")
cat > "$_cli_outdated_stub/isort" <<'STUB'
#!/usr/bin/env bash
# Stub isort: reports version 4.3.0 (outdated)
if [[ "$*" == *"--version"* ]]; then
    echo "isort, version 4.3.0"
    exit 0
fi
exit 0
STUB
chmod +x "$_cli_outdated_stub/isort"

_cli_outdated_output=""
_cli_outdated_exit=0
_cli_outdated_output=$(
    RECIPE_REGISTRY_PATH="$_cli_outdated_reg" \
    TASK_LIST_FILE="$_cli_outdated_tasks" \
    PATH="$_cli_outdated_stub:$PATH" \
    bash "$SCRIPT" 2>&1
) || _cli_outdated_exit=$?

assert_ne "test_cli_engine_outdated_version_detected: must exit non-zero for outdated isort" "0" "$_cli_outdated_exit"
assert_contains "test_cli_engine_outdated_version_detected: output must contain OUTDATED_ENGINE: isort found:4.3.0 minimum:5.0.0" \
    "OUTDATED_ENGINE: isort found:4.3.0 minimum:5.0.0" "$_cli_outdated_output"
assert_pass_if_clean "test_cli_engine_outdated_version_detected"

# ── test_cli_engine_current_version_passes ────────────────────────────────────
# Given: a task list with a recipe that uses the isort CLI engine (min 5.0.0)
# AND:   isort IS installed and reports version 5.10.1 (above minimum 5.0.0)
# When:  check-recipe-engines.sh is invoked
# Then:  output contains "ENGINES_OK" and exits 0
_snapshot_fail
_cli_ok_stub="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-cli-ok.XXXXXX")"
_TMPDIRS+=("$_cli_ok_stub")
cat > "$_cli_ok_stub/isort" <<'STUB'
#!/usr/bin/env bash
# Stub isort: reports version 5.10.1 (current)
if [[ "$*" == *"--version"* ]]; then
    echo "isort, version 5.10.1"
    exit 0
fi
exit 0
STUB
chmod +x "$_cli_ok_stub/isort"

_cli_ok_output=""
_cli_ok_exit=0
_cli_ok_output=$(
    RECIPE_REGISTRY_PATH="$_cli_outdated_reg" \
    TASK_LIST_FILE="$_cli_outdated_tasks" \
    PATH="$_cli_ok_stub:$PATH" \
    bash "$SCRIPT" 2>&1
) || _cli_ok_exit=$?

assert_eq "test_cli_engine_current_version_passes: must exit 0 when isort is current" "0" "$_cli_ok_exit"
assert_contains "test_cli_engine_current_version_passes: output must contain ENGINES_OK" \
    "ENGINES_OK" "$_cli_ok_output"
assert_pass_if_clean "test_cli_engine_current_version_passes"

# ── test_zero_min_version_skips_version_check ─────────────────────────────────
# Given: a task list with a recipe whose min_engine_version is "0.0.0" (scaffold)
# AND:   the engine binary exists (any version is acceptable)
# When:  check-recipe-engines.sh is invoked
# Then:  output contains "ENGINES_OK" and exits 0 (no version check needed)
_snapshot_fail
_zero_reg="$(mktemp "${TMPDIR:-/tmp}/test-check-recipe-engines-zero-reg.XXXXXX".yaml)"
_TMPFILES+=("$_zero_reg")
cat > "$_zero_reg" <<'YAML'
recipes:
  - name: scaffold-route
    language: any
    engine: scaffold
    adapter: scaffold-adapter.sh
    capability_description: "Generate route boilerplate"
    scope: generative
    min_engine_version: "0.0.0"
    installation_instructions: "No external engine required"
YAML

_zero_tasks="$(mktemp "${TMPDIR:-/tmp}/test-check-recipe-engines-zero-tasks.XXXXXX".json)"
_TMPFILES+=("$_zero_tasks")
cat > "$_zero_tasks" <<'JSON'
[{"id": "task-scaffold-001", "title": "Scaffold route", "tags": ["recipe:scaffold-route"], "status": "open"}]
JSON

_zero_stub="$(mktemp -d "${TMPDIR:-/tmp}/test-check-recipe-engines-zero.XXXXXX")"
_TMPDIRS+=("$_zero_stub")
cat > "$_zero_stub/scaffold" <<'STUB'
#!/usr/bin/env bash
# Stub scaffold binary (min_engine_version=0.0.0, any version OK)
if [[ "$*" == *"--version"* ]]; then
    echo "scaffold 0.1.0"
    exit 0
fi
exit 0
STUB
chmod +x "$_zero_stub/scaffold"

_zero_output=""
_zero_exit=0
_zero_output=$(
    RECIPE_REGISTRY_PATH="$_zero_reg" \
    TASK_LIST_FILE="$_zero_tasks" \
    PATH="$_zero_stub:$PATH" \
    bash "$SCRIPT" 2>&1
) || _zero_exit=$?

assert_eq "test_zero_min_version_skips_version_check: must exit 0 for 0.0.0 min version" "0" "$_zero_exit"
assert_contains "test_zero_min_version_skips_version_check: output must contain ENGINES_OK" \
    "ENGINES_OK" "$_zero_output"
assert_pass_if_clean "test_zero_min_version_skips_version_check"

print_summary
