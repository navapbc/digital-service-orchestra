#!/usr/bin/env bash
set -uo pipefail
# tests/hooks/test-eval-todo-guard.sh
# Behavioral tests for the TODO eval guard in record-test-status.sh.
#
# The guard scans staged */evals/promptfooconfig.yaml files and blocks
# (exits non-zero) when any staged eval config contains:
#   - TODO markers in assertion values
#   - Empty tests: list ([] or no entries)
#   - No type: llm-rubric assertion
#
# Each test creates an isolated temporary git repo with specific staged
# eval config files, invokes record-test-status.sh, and asserts on
# observable outcomes: exit code, stdout, and stderr.
#
# RECORD_TEST_STATUS_EVALS_RUNNER is set to a no-op mock in all tests
# to prevent the existing skill eval runner from blocking on API calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Disable commit signing for all test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# Create a shared no-op mock eval runner so tests don't hang on actual evals.
# All tests set RECORD_TEST_STATUS_EVALS_RUNNER to this runner.
_MOCK_NOOP_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-eval-noop-XXXXXX")
chmod +x "$_MOCK_NOOP_RUNNER"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_MOCK_NOOP_RUNNER"
trap 'rm -f "$_MOCK_NOOP_RUNNER"' EXIT

# ============================================================
# Helper: create an isolated temp git repo with initial commit
# ============================================================
create_eval_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-todo-guard-XXXXXX")
    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null
    echo "$tmpdir"
}

# Helper: run the hook in a given repo dir, capturing combined output and exit code.
# Usage: run_guard <repo_dir> <artifacts_dir>
# Prints combined stdout+stderr to stdout; sets global _LAST_EXIT_CODE.
#
# NOTE: run_guard is called via command substitution (_OUTPUT=$(run_guard ...)),
# which runs in a subshell. To propagate _LAST_EXIT_CODE to the parent shell,
# we write the exit code to a temp file and read it back after the call.
_LAST_EXIT_CODE=0
_GUARD_EXIT_CODE_FILE=$(mktemp "${TMPDIR:-/tmp}/guard-exit-code-XXXXXX")
trap 'rm -f "$_GUARD_EXIT_CODE_FILE"' EXIT
run_guard() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local _exit=0
    (
        cd "$repo_dir"
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        RECORD_TEST_STATUS_EVALS_RUNNER="$_MOCK_NOOP_RUNNER" \
        bash "$HOOK" 2>&1
    ) || _exit=$?
    echo "$_exit" > "$_GUARD_EXIT_CODE_FILE"
}
# Reads _LAST_EXIT_CODE from the temp file written by the most recent run_guard call.
_sync_last_exit() {
    _LAST_EXIT_CODE=$(cat "$_GUARD_EXIT_CODE_FILE" 2>/dev/null || echo "0")
}

# ============================================================
# test_todo_marker_blocks
# A staged */evals/promptfooconfig.yaml with a "TODO:" string
# in an assertion value must cause record-test-status.sh to exit
# non-zero and mention the offending file in its output.
# ============================================================
echo ""
echo "=== test_todo_marker_blocks ==="
_snapshot_fail

_REPO_TODO=$(create_eval_test_repo)
_ART_TODO=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-guard-art-XXXXXX")
trap 'rm -rf "$_REPO_TODO" "$_ART_TODO"' EXIT

mkdir -p "$_REPO_TODO/plugins/dso/skills/my-skill/evals"
cat > "$_REPO_TODO/plugins/dso/skills/my-skill/evals/promptfooconfig.yaml" << 'YAMLEOF'
providers:
  - openai:gpt-4o-mini
tests:
  - vars:
      input: "some input"
    assert:
      - type: llm-rubric
        value: "TODO: write a real rubric here"
YAMLEOF

git -C "$_REPO_TODO" add -A
git -C "$_REPO_TODO" commit -m "add eval" --quiet 2>/dev/null
echo "# changed" >> "$_REPO_TODO/plugins/dso/skills/my-skill/evals/promptfooconfig.yaml"
git -C "$_REPO_TODO" add -A

_OUTPUT_TODO=$(run_guard "$_REPO_TODO" "$_ART_TODO")
_sync_last_exit

# Guard must exit non-zero when TODO is present
assert_ne "todo_marker_blocks: exits non-zero" "0" "$_LAST_EXIT_CODE"
# Output must identify the offending file
assert_contains "todo_marker_blocks: mentions promptfooconfig.yaml" "promptfooconfig.yaml" "$_OUTPUT_TODO"

rm -rf "$_REPO_TODO" "$_ART_TODO"
trap 'rm -f "$_MOCK_NOOP_RUNNER"' EXIT

assert_pass_if_clean "test_todo_marker_blocks"

# ============================================================
# test_empty_tests_blocks
# A staged */evals/promptfooconfig.yaml with `tests: []` (empty
# test list) must cause record-test-status.sh to exit non-zero.
# ============================================================
echo ""
echo "=== test_empty_tests_blocks ==="
_snapshot_fail

_REPO_EMPTY=$(create_eval_test_repo)
_ART_EMPTY=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-guard-art-XXXXXX")
trap 'rm -rf "$_REPO_EMPTY" "$_ART_EMPTY"' EXIT

mkdir -p "$_REPO_EMPTY/plugins/dso/skills/another-skill/evals"
cat > "$_REPO_EMPTY/plugins/dso/skills/another-skill/evals/promptfooconfig.yaml" << 'YAMLEOF'
providers:
  - openai:gpt-4o-mini
tests: []
YAMLEOF

git -C "$_REPO_EMPTY" add -A
git -C "$_REPO_EMPTY" commit -m "add eval with empty tests" --quiet 2>/dev/null
echo "# changed" >> "$_REPO_EMPTY/plugins/dso/skills/another-skill/evals/promptfooconfig.yaml"
git -C "$_REPO_EMPTY" add -A

_OUTPUT_EMPTY=$(run_guard "$_REPO_EMPTY" "$_ART_EMPTY")
_sync_last_exit

assert_ne "empty_tests_blocks: exits non-zero" "0" "$_LAST_EXIT_CODE"

rm -rf "$_REPO_EMPTY" "$_ART_EMPTY"
trap 'rm -f "$_MOCK_NOOP_RUNNER"' EXIT

assert_pass_if_clean "test_empty_tests_blocks"

# ============================================================
# test_no_llm_rubric_blocks
# A staged */evals/promptfooconfig.yaml with non-empty tests but
# no `type: llm-rubric` assertion must cause a non-zero exit.
# ============================================================
echo ""
echo "=== test_no_llm_rubric_blocks ==="
_snapshot_fail

_REPO_NORUBRIC=$(create_eval_test_repo)
_ART_NORUBRIC=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-guard-art-XXXXXX")
trap 'rm -rf "$_REPO_NORUBRIC" "$_ART_NORUBRIC"' EXIT

mkdir -p "$_REPO_NORUBRIC/plugins/dso/skills/third-skill/evals"
cat > "$_REPO_NORUBRIC/plugins/dso/skills/third-skill/evals/promptfooconfig.yaml" << 'YAMLEOF'
providers:
  - openai:gpt-4o-mini
tests:
  - vars:
      input: "some input"
    assert:
      - type: contains
        value: "expected output"
YAMLEOF

git -C "$_REPO_NORUBRIC" add -A
git -C "$_REPO_NORUBRIC" commit -m "add eval without llm-rubric" --quiet 2>/dev/null
echo "# changed" >> "$_REPO_NORUBRIC/plugins/dso/skills/third-skill/evals/promptfooconfig.yaml"
git -C "$_REPO_NORUBRIC" add -A

_OUTPUT_NORUBRIC=$(run_guard "$_REPO_NORUBRIC" "$_ART_NORUBRIC")
_sync_last_exit

assert_ne "no_llm_rubric_blocks: exits non-zero" "0" "$_LAST_EXIT_CODE"

rm -rf "$_REPO_NORUBRIC" "$_ART_NORUBRIC"
trap 'rm -f "$_MOCK_NOOP_RUNNER"' EXIT

assert_pass_if_clean "test_no_llm_rubric_blocks"

# ============================================================
# test_valid_config_passes
# A staged */evals/promptfooconfig.yaml with no TODOs, a
# non-empty tests list, and at least one llm-rubric assertion
# must NOT produce a TODO/rubric/empty-tests error message.
# ============================================================
echo ""
echo "=== test_valid_config_passes ==="
_snapshot_fail

_REPO_VALID=$(create_eval_test_repo)
_ART_VALID=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-guard-art-XXXXXX")
trap 'rm -rf "$_REPO_VALID" "$_ART_VALID"' EXIT

mkdir -p "$_REPO_VALID/plugins/dso/skills/valid-skill/evals"
cat > "$_REPO_VALID/plugins/dso/skills/valid-skill/evals/promptfooconfig.yaml" << 'YAMLEOF'
providers:
  - openai:gpt-4o-mini
tests:
  - vars:
      input: "some input"
    assert:
      - type: llm-rubric
        value: "The response should address the user question clearly and concisely"
YAMLEOF

git -C "$_REPO_VALID" add -A
git -C "$_REPO_VALID" commit -m "add valid eval" --quiet 2>/dev/null
echo "# changed" >> "$_REPO_VALID/plugins/dso/skills/valid-skill/evals/promptfooconfig.yaml"
git -C "$_REPO_VALID" add -A

_OUTPUT_VALID=$(run_guard "$_REPO_VALID" "$_ART_VALID")
_sync_last_exit

# A valid config must not produce a guard-rejection message (exit 0, no TODO/rubric errors).
assert_eq "valid_config_passes: exits 0 (guard does not block valid config)" "0" "$_LAST_EXIT_CODE"

rm -rf "$_REPO_VALID" "$_ART_VALID"
trap 'rm -f "$_MOCK_NOOP_RUNNER"' EXIT

assert_pass_if_clean "test_valid_config_passes"

# ============================================================
# test_non_eval_files_ignored
# Staged YAML files NOT matching */evals/promptfooconfig.yaml
# must not be scanned by the guard. A TODO in a non-eval YAML
# must not trigger a block.
# ============================================================
echo ""
echo "=== test_non_eval_files_ignored ==="
_snapshot_fail

_REPO_NONEVALS=$(create_eval_test_repo)
_ART_NONEVALS=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-guard-art-XXXXXX")
trap 'rm -rf "$_REPO_NONEVALS" "$_ART_NONEVALS"' EXIT

# YAML with TODO at a non-eval path — guard must not scan it
mkdir -p "$_REPO_NONEVALS/config"
cat > "$_REPO_NONEVALS/config/some-config.yaml" << 'YAMLEOF'
settings:
  value: "TODO: replace this with real config"
YAMLEOF

git -C "$_REPO_NONEVALS" add -A
git -C "$_REPO_NONEVALS" commit -m "add non-eval yaml" --quiet 2>/dev/null
echo "# changed" >> "$_REPO_NONEVALS/config/some-config.yaml"
git -C "$_REPO_NONEVALS" add -A

_OUTPUT_NONEVALS=$(run_guard "$_REPO_NONEVALS" "$_ART_NONEVALS")
_sync_last_exit

# Non-eval YAML with TODO must not trigger the guard; hook exits 0 (no associated tests)
assert_eq "non_eval_files_ignored: exits 0 for non-eval staged YAML" "0" "$_LAST_EXIT_CODE"

rm -rf "$_REPO_NONEVALS" "$_ART_NONEVALS"
trap 'rm -f "$_MOCK_NOOP_RUNNER"' EXIT

assert_pass_if_clean "test_non_eval_files_ignored"

# ============================================================
# test_no_api_key_required
# The guard performs static text scanning only — no API calls,
# no npx invocation. It must block (exit non-zero) on a TODO
# even when ANTHROPIC_API_KEY is explicitly unset.
# ============================================================
echo ""
echo "=== test_no_api_key_required ==="
_snapshot_fail

_REPO_NOKEY=$(create_eval_test_repo)
_ART_NOKEY=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-guard-art-XXXXXX")
trap 'rm -rf "$_REPO_NOKEY" "$_ART_NOKEY"' EXIT

mkdir -p "$_REPO_NOKEY/plugins/dso/skills/nokey-skill/evals"
cat > "$_REPO_NOKEY/plugins/dso/skills/nokey-skill/evals/promptfooconfig.yaml" << 'YAMLEOF'
providers:
  - openai:gpt-4o-mini
tests:
  - vars:
      input: "some input"
    assert:
      - type: llm-rubric
        value: "TODO: write real assertion"
YAMLEOF

git -C "$_REPO_NOKEY" add -A
git -C "$_REPO_NOKEY" commit -m "add eval with todo" --quiet 2>/dev/null
echo "# changed" >> "$_REPO_NOKEY/plugins/dso/skills/nokey-skill/evals/promptfooconfig.yaml"
git -C "$_REPO_NOKEY" add -A

_OUTPUT_NOKEY=$(
    cd "$_REPO_NOKEY"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_ART_NOKEY" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_EVALS_RUNNER="$_MOCK_NOOP_RUNNER" \
    ANTHROPIC_API_KEY="" \
    bash "$HOOK" 2>&1
) || _LAST_EXIT_CODE=$?

# Guard must exit non-zero even with no API key — it is a static scan, not an API call
assert_ne "no_api_key_required: exits non-zero without API key" "0" "$_LAST_EXIT_CODE"

rm -rf "$_REPO_NOKEY" "$_ART_NOKEY"
trap 'rm -f "$_MOCK_NOOP_RUNNER"' EXIT

assert_pass_if_clean "test_no_api_key_required"

# ============================================================
# test_multiple_files_reported
# When multiple staged */evals/promptfooconfig.yaml files each
# contain TODO markers, all offending files must be mentioned in
# the error output.
# ============================================================
echo ""
echo "=== test_multiple_files_reported ==="
_snapshot_fail

_REPO_MULTI=$(create_eval_test_repo)
_ART_MULTI=$(mktemp -d "${TMPDIR:-/tmp}/test-eval-guard-art-XXXXXX")
trap 'rm -rf "$_REPO_MULTI" "$_ART_MULTI"' EXIT

mkdir -p "$_REPO_MULTI/plugins/dso/skills/skill-alpha/evals"
mkdir -p "$_REPO_MULTI/plugins/dso/skills/skill-beta/evals"

cat > "$_REPO_MULTI/plugins/dso/skills/skill-alpha/evals/promptfooconfig.yaml" << 'YAMLEOF'
providers:
  - openai:gpt-4o-mini
tests:
  - vars:
      input: "alpha input"
    assert:
      - type: llm-rubric
        value: "TODO: alpha rubric placeholder"
YAMLEOF

cat > "$_REPO_MULTI/plugins/dso/skills/skill-beta/evals/promptfooconfig.yaml" << 'YAMLEOF'
providers:
  - openai:gpt-4o-mini
tests:
  - vars:
      input: "beta input"
    assert:
      - type: llm-rubric
        value: "TODO: beta rubric placeholder"
YAMLEOF

git -C "$_REPO_MULTI" add -A
git -C "$_REPO_MULTI" commit -m "add two evals with todos" --quiet 2>/dev/null

echo "# changed alpha" >> "$_REPO_MULTI/plugins/dso/skills/skill-alpha/evals/promptfooconfig.yaml"
echo "# changed beta" >> "$_REPO_MULTI/plugins/dso/skills/skill-beta/evals/promptfooconfig.yaml"
git -C "$_REPO_MULTI" add -A

_OUTPUT_MULTI=$(run_guard "$_REPO_MULTI" "$_ART_MULTI")
_sync_last_exit

# Guard must exit non-zero
assert_ne "multiple_files_reported: exits non-zero" "0" "$_LAST_EXIT_CODE"
# Both skill directories must appear in the output
assert_contains "multiple_files_reported: mentions skill-alpha" "skill-alpha" "$_OUTPUT_MULTI"
assert_contains "multiple_files_reported: mentions skill-beta" "skill-beta" "$_OUTPUT_MULTI"

rm -rf "$_REPO_MULTI" "$_ART_MULTI"
trap 'rm -f "$_MOCK_NOOP_RUNNER"' EXIT

assert_pass_if_clean "test_multiple_files_reported"

print_summary
