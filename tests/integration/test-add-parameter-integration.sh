#!/usr/bin/env bash
# tests/integration/test-add-parameter-integration.sh
# Integration tests for add-parameter recipe via recipe-executor.sh
#
# Tests operate on synthetic fixtures committed to the repo.
# Gracefully skips when external engines (rope, ts-morph) are unavailable.
#
# Usage: bash tests/integration/test-add-parameter-integration.sh
# Returns: exit 0 if all pass or skip, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-add-parameter-integration.sh ==="

# Graceful skip
if [[ "${TEST_INTEGRATION_SKIP:-0}" == "1" ]]; then
    echo "SKIP: TEST_INTEGRATION_SKIP=1"
    exit 0
fi

# Fixture availability check
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
if [[ ! -d "$FIXTURES_DIR/python-project" ]] || [[ ! -d "$FIXTURES_DIR/typescript-project" ]]; then
    echo "SKIP: fixtures not available"
    exit 0
fi

# Engine availability checks
PYTHON_ROPE_AVAILABLE=0
if command -v rope >/dev/null 2>&1 || python3 -c "import rope" >/dev/null 2>&1; then
    PYTHON_ROPE_AVAILABLE=1
fi

TYPESCRIPT_AVAILABLE=0
if command -v node >/dev/null 2>&1; then
    if node -e "require('ts-morph')" >/dev/null 2>&1; then
        TYPESCRIPT_AVAILABLE=1
    fi
fi

EXECUTOR="$REPO_ROOT/plugins/dso/scripts/recipe-executor.sh"
[[ -f "$EXECUTOR" ]] || { echo "SKIP: recipe-executor.sh not found"; exit 0; }

# Cleanup
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap _cleanup EXIT

# Helper: copy fixture to temp dir and init git repo
_copy_fixture() {
    local fixture_name="$1"
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    cp -r "$FIXTURES_DIR/$fixture_name/." "$tmpdir/"
    # Initialize as a git repo so rollback tests can work
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "initial fixture"
    echo "$tmpdir"
}

# Helper: create a test registry with a single recipe entry
# Usage: _make_registry tmpdir recipe_name engine adapter_file [language]
_make_registry() {
    local tmpdir="$1"
    local recipe_name="$2"
    local engine="$3"
    local adapter_file="$4"
    local language="${5:-any}"
    local registry_path="$tmpdir/registry.yaml"
    cat > "$registry_path" <<YAML
recipes:
  ${recipe_name}:
    language: ${language}
    engine: ${engine}
    min_engine_version: "0.0.1"
    adapter: ${adapter_file}
    description: "Test recipe"
    parameters: []
YAML
    echo "$registry_path"
}

# Helper: create a failing adapter for rollback tests.
# The adapter modifies a tracked file then exits non-zero.
# Rollback of tracked modifications is owned by the executor (git checkout -- .).
_make_failing_adapter() {
    local adapters_dir="$1"
    local adapter_name="${2:-fail-adapter.sh}"
    local adapter_path="$adapters_dir/$adapter_name"
    cat > "$adapter_path" <<'ADAPTER'
#!/usr/bin/env bash
# Failing adapter: modifies a tracked file then exits non-zero.
# Does NOT perform rollback — rollback is the executor's responsibility.
# Modifies a tracked file (not untracked) so executor's git checkout -- . cleans it.
WORK_DIR="${GIT_WORK_TREE:-$(pwd)}"
_TRACKED=$(git -C "$WORK_DIR" ls-files --full-name 2>/dev/null | head -1)
if [[ -n "$_TRACKED" ]]; then
    echo "ADAPTER_MODIFICATION" >> "$WORK_DIR/$_TRACKED"
fi
exit 1
ADAPTER
    chmod +x "$adapter_path"
    echo "$adapter_path"
}

# Helper: check if working tree is clean
_is_clean() {
    local git_dir="$1"
    local status
    status="$(git -C "$git_dir" status --porcelain 2>/dev/null)"
    [[ -z "$status" ]]
}

# test_python_add_parameter_updates_callers
# Run add-parameter (python/rope) on python fixture; verify output structure.
# Skip if rope unavailable.

test_python_add_parameter_updates_callers() {
    if [[ "$PYTHON_ROPE_AVAILABLE" -eq 0 ]]; then
        echo "  SKIP: test_python_add_parameter_updates_callers (rope unavailable)"
        return
    fi

    local workdir
    workdir="$(_copy_fixture python-project)"

    local exit_code=0
    local output
    output=$(GIT_WORK_TREE="$workdir" bash "$EXECUTOR" add-parameter \
        --param function_name=add \
        --param new_param=z \
        --param default_value=0 \
        --param project_root="$workdir" \
        2>&1) || exit_code=$?

    # Output must be valid JSON
    local valid_json=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_python_add_parameter_updates_callers: output is valid JSON" "1" "$valid_json"

    # files_changed must be non-empty (rope actually changed files)
    local files_changed_count=0
    files_changed_count=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "0")
    assert_ne "test_python_add_parameter_updates_callers: files_changed non-empty" "0" "$files_changed_count"

    # Run the fixture's own test suite to verify all callers still work after transform.
    # This validates semantic correctness: add(x, y, z=0) still behaves as add(x, y) for all callers.
    if command -v python3 >/dev/null 2>&1; then
        local pytest_exit=0
        python3 -m pytest "$workdir" -q --tb=short 2>/dev/null || pytest_exit=$?
        assert_eq "test_python_add_parameter_updates_callers: fixture test suite passes after transform" "0" "$pytest_exit"
    fi
}

# test_typescript_add_parameter_structure
# Run add-parameter (typescript) on TypeScript fixture; verify output structure.
# Skip if node/ts-morph unavailable.

test_typescript_add_parameter_structure() {
    if [[ "$TYPESCRIPT_AVAILABLE" -eq 0 ]]; then
        echo "  SKIP: test_typescript_add_parameter_structure (ts-morph unavailable)"
        return
    fi

    local workdir
    workdir="$(_copy_fixture typescript-project)"

    local exit_code=0
    local output
    output=$(RECIPE_NAME=add-parameter GIT_WORK_TREE="$workdir" bash "$EXECUTOR" add-parameter \
        --param function_name=add \
        --param new_param=z \
        --param project_root="$workdir" \
        2>&1) || exit_code=$?

    # Output must be valid JSON
    local valid_json=0
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_typescript_add_parameter_structure: output is valid JSON" "1" "$valid_json"

    # files_changed must be an array
    local has_files_key=0
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('files_changed'), list)" 2>/dev/null && has_files_key=1 || true
    assert_eq "test_typescript_add_parameter_structure: files_changed is array" "1" "$has_files_key"
}

# test_add_parameter_idempotency
# Run add-parameter twice; second run files_changed should be [].
# Skip if rope unavailable.

test_add_parameter_idempotency() {
    if [[ "$PYTHON_ROPE_AVAILABLE" -eq 0 ]]; then
        echo "  SKIP: test_add_parameter_idempotency (rope unavailable)"
        return
    fi

    local workdir
    workdir="$(_copy_fixture python-project)"

    # First run
    local output1
    output1=$(GIT_WORK_TREE="$workdir" bash "$EXECUTOR" add-parameter \
        --param function_name=add \
        --param new_param=z \
        --param default_value=0 \
        --param project_root="$workdir" \
        2>&1) || true

    # Assert first run changed files (otherwise idempotency test is vacuous)
    local files_first=0
    files_first=$(echo "$output1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "0")
    assert_ne "test_add_parameter_idempotency: first run files_changed non-empty" "0" "$files_first"

    # Commit first-run changes so second run starts clean
    git -C "$workdir" add -A >/dev/null 2>&1 || true
    git -C "$workdir" commit -q -m "after first run" >/dev/null 2>&1 || true

    # Second run -- idempotent: no new changes
    local output2
    output2=$(GIT_WORK_TREE="$workdir" bash "$EXECUTOR" add-parameter \
        --param function_name=add \
        --param new_param=z \
        --param default_value=0 \
        --param project_root="$workdir" \
        2>&1) || true

    local valid_json=0
    echo "$output2" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true
    assert_eq "test_add_parameter_idempotency: second run produces valid JSON" "1" "$valid_json"

    # files_changed should be empty on second run
    local files_changed_count=0
    files_changed_count=$(echo "$output2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('files_changed', [])))" 2>/dev/null || echo "-1")
    assert_eq "test_add_parameter_idempotency: second run files_changed=[]" "0" "$files_changed_count"
}

# test_add_parameter_determinism
# Three consecutive runs produce same exit_code=0.
# Skip if rope unavailable.

test_add_parameter_determinism() {
    if [[ "$PYTHON_ROPE_AVAILABLE" -eq 0 ]]; then
        echo "  SKIP: test_add_parameter_determinism (rope unavailable)"
        return
    fi

    local codes=()
    for i in 1 2 3; do
        local workdir
        workdir="$(_copy_fixture python-project)"

        local exit_code=0
        GIT_WORK_TREE="$workdir" bash "$EXECUTOR" add-parameter \
            --param function_name=add \
            --param new_param=z \
            --param default_value=0 \
            --param project_root="$workdir" \
            >/dev/null 2>&1 || exit_code=$?
        codes+=("$exit_code")
    done

    assert_eq "test_add_parameter_determinism: run1 exit_code=0" "0" "${codes[0]}"
    assert_eq "test_add_parameter_determinism: run2 exit_code=0" "0" "${codes[1]}"
    assert_eq "test_add_parameter_determinism: run3 exit_code=0" "0" "${codes[2]}"
}

# test_rollback_on_failure
# Create a temp git repo. Run executor with a failing adapter that rolls back.
# Verify working tree is clean after the executor completes.

test_rollback_on_failure() {
    # This test does not require rope or ts-morph -- uses a mock failing adapter.
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    local work_dir="$tmpdir/work"
    mkdir -p "$work_dir/src"
    echo "print('hello')" > "$work_dir/src/main.py"
    git -C "$work_dir" init -q
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "initial"

    # Create failing adapter that implements rollback per contract
    local adapters_dir="$tmpdir/adapters"
    mkdir -p "$adapters_dir"
    _make_failing_adapter "$adapters_dir" "fail-adapter.sh" >/dev/null

    # Create registry pointing to failing adapter (language: any -- fake engine)
    local registry_path
    registry_path="$(_make_registry "$tmpdir" "test-recipe" "fake-engine" "fail-adapter.sh" "any")"

    # Run executor -- it will fail (exit non-zero)
    local exit_code=0
    GIT_WORK_TREE="$work_dir" TEST_REGISTRY_PATH="$registry_path" TEST_ADAPTERS_DIR="$adapters_dir" \
        bash "$EXECUTOR" test-recipe >/dev/null 2>&1 || exit_code=$?

    # Executor should exit non-zero
    assert_ne "test_rollback_on_failure: executor exits non-zero on failure" "0" "$exit_code"

    # Working tree must be clean after rollback (executor owns rollback via git stash)
    if _is_clean "$work_dir"; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_rollback_on_failure\n  working tree is dirty after rollback\n  status: %s\n" \
            "$(git -C "$work_dir" status --porcelain 2>/dev/null)" >&2
    fi
}

# test_rollback_restores_preexisting_changes
# When an adapter fails, the executor must:
#   1. Discard adapter's changes (checkout -- .)
#   2. Restore pre-existing uncommitted changes (stash pop)
# Verifies the pre-existing change is present and adapter change is absent.

test_rollback_restores_preexisting_changes() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    local work_dir="$tmpdir/work"
    mkdir -p "$work_dir/src"
    printf "original line\n" > "$work_dir/src/shared.py"
    git -C "$work_dir" init -q
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"
    git -C "$work_dir" add -A
    git -C "$work_dir" commit -q -m "initial"

    # Introduce pre-existing uncommitted change before executor runs (will be stashed)
    printf "pre-existing change\n" >> "$work_dir/src/shared.py"

    # Failing adapter that also modifies shared.py then exits non-zero
    local adapters_dir="$tmpdir/adapters"
    mkdir -p "$adapters_dir"
    local fail_adapter="$adapters_dir/fail-adapter.sh"
    cat > "$fail_adapter" <<'ADAPTER'
#!/usr/bin/env bash
WORK_DIR="${GIT_WORK_TREE:-$(pwd)}"
echo "adapter change" >> "$WORK_DIR/src/shared.py"
exit 1
ADAPTER
    chmod +x "$fail_adapter"

    local registry_path
    registry_path="$(_make_registry "$tmpdir" "fail-recipe" "fake-engine" "fail-adapter.sh" "any")"

    local exit_code=0
    GIT_WORK_TREE="$work_dir" TEST_REGISTRY_PATH="$registry_path" TEST_ADAPTERS_DIR="$adapters_dir" \
        bash "$EXECUTOR" fail-recipe >/dev/null 2>&1 || exit_code=$?

    # Executor must exit non-zero
    assert_ne "test_rollback_restores_preexisting_changes: executor exits non-zero" "0" "$exit_code"

    # Adapter change must NOT be present
    local has_adapter_change=0
    grep -q "adapter change" "$work_dir/src/shared.py" 2>/dev/null && has_adapter_change=1 || true
    if [[ $has_adapter_change -eq 0 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_rollback_restores_preexisting_changes\n  adapter change found in working tree after rollback\n" >&2
    fi

    # Pre-existing change must be RESTORED
    local has_preexisting=0
    grep -q "pre-existing change" "$work_dir/src/shared.py" 2>/dev/null && has_preexisting=1 || true
    if [[ $has_preexisting -eq 1 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_rollback_restores_preexisting_changes\n  pre-existing change not restored after rollback\n  content: %s\n" \
            "$(cat "$work_dir/src/shared.py" 2>/dev/null)" >&2
    fi
}

# Run all tests
test_python_add_parameter_updates_callers
test_typescript_add_parameter_structure
test_add_parameter_idempotency
test_add_parameter_determinism
test_rollback_on_failure
test_rollback_restores_preexisting_changes

print_summary
