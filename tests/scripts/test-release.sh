#!/usr/bin/env bash
# tests/scripts/test-release.sh
# RED phase tests for scripts/release.sh precondition logic.
#
# All tests MUST FAIL because scripts/release.sh does not yet exist.
#
# Test cases:
#   1. test_release_ci_not_green              [RED MARKER]
#   2. test_release_dirty_tree
#   3. test_release_not_on_main
#   4. test_release_not_up_to_date
#   5. test_release_validate_fails
#   6. test_release_invalid_json
#   7. test_release_confirmation_required
#   8. test_release_yes_flag_accepted
#   9. test_release_all_preconditions_pass
#  10. test_release_yes_does_not_bypass_preconditions
#
# Usage: bash tests/scripts/test-release.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail (RED: expect exit 1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/release.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-release.sh ==="

# =============================================================================
# Cleanup registry
# =============================================================================
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

# =============================================================================
# Helper: create a throwaway temp dir and register for cleanup
# =============================================================================
_make_tmp() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# =============================================================================
# Helper: seed a throwaway git repo in a temp dir
# Returns the path of the git repo.
# =============================================================================
_make_git_repo() {
    local repo
    repo="$(_make_tmp)"
    (
        cd "$repo" || exit 1
        git init -b main --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "initial" --quiet
    ) 2>/dev/null
    echo "$repo"
}

# =============================================================================
# Helper: create a MOCK_BIN directory with stub binaries.
#
# Usage: make_mock MOCK_BIN_DIR COMMAND_NAME EXIT_CODE [STDOUT] [STDERR]
#
# Creates MOCK_BIN_DIR/COMMAND_NAME that exits with EXIT_CODE, writes STDOUT
# to stdout and STDERR to stderr. MOCK_BIN_DIR should be prepended to PATH.
# =============================================================================
make_mock() {
    local mock_bin="$1"
    local cmd_name="$2"
    local exit_code="${3:-0}"
    local stdout="${4:-}"
    local stderr="${5:-}"

    mkdir -p "$mock_bin"
    cat > "$mock_bin/$cmd_name" << STUB
#!/usr/bin/env bash
$([ -n "$stdout" ] && printf 'echo %q' "$stdout" || echo ':')
$([ -n "$stderr" ] && printf 'echo %q >&2' "$stderr" || echo ':')
exit $exit_code
STUB
    chmod +x "$mock_bin/$cmd_name"
}

# =============================================================================
# Helper: create a call-recording push stub.
# Returns path to the call-log file. Stub script exits 0 and appends "called"
# to the log on each invocation. The stub is placed in MOCK_BIN_DIR as "git".
# NOTE: git commands are mocked by a dispatcher that delegates sub-commands.
# =============================================================================
_make_push_recording_git_stub() {
    local mock_bin="$1"
    local call_log="$2"
    local branch_name="${3:-main}"

    mkdir -p "$mock_bin"
    cat > "$mock_bin/git" << STUB
#!/usr/bin/env bash
# Mock git dispatcher
case "\$1" in
  push)
    echo "called" >> "$call_log"
    exit 0
    ;;
  branch)
    # --show-current
    echo "$branch_name"
    exit 0
    ;;
  status)
    # Return clean status (no output from --porcelain; behind-check also clean)
    exit 0
    ;;
  rev-parse)
    # For --show-toplevel or similar — return a safe path
    echo "$mock_bin"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
    chmod +x "$mock_bin/git"
}


# =============================================================================
# Structural: script must exist and be executable (drives implementation)
# MUST FAIL (RED): scripts/release.sh does not exist yet.
# =============================================================================
echo ""
echo "--- structural guard ---"
if [[ -x "$SCRIPT" ]]; then
    actual="executable"
else
    actual="not_executable"
fi
assert_eq "scripts/release.sh exists and is executable" "executable" "$actual"

# =============================================================================
# test_release_ci_not_green  [RED MARKER]
# Given: gh returns a CI failure status
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero AND "CI" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_ci_not_green ---"
_snapshot_fail

_tmp_ci="$(_make_tmp)"
_mock_ci="$_tmp_ci/bin"
_fake_repo_ci="$(_make_git_repo)"
mkdir -p "$_fake_repo_ci/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_ci/.claude-plugin/marketplace.json"

make_mock "$_mock_ci" "git" 0
# Override git to report main branch and clean tree
cat > "$_mock_ci/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date; CI check is the failure
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_ci/git"

# gh returns failure
cat > "$_mock_ci/gh" << 'STUB'
#!/usr/bin/env bash
echo "completed  failure  main  CI  1234" >&2
exit 1
STUB
chmod +x "$_mock_ci/gh"

make_mock "$_mock_ci" "dso" 0

_ci_exit=0
PATH="$_mock_ci:$PATH" bash "$SCRIPT" "1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_ci/stderr.txt" || _ci_exit=$?
_ci_stderr_content=$(cat "$_tmp_ci/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_ci_not_green: exit non-zero" "0" "$_ci_exit"
assert_contains "test_release_ci_not_green: CI in stderr" "CI" "$_ci_stderr_content"
assert_pass_if_clean "test_release_ci_not_green"

# =============================================================================
# test_release_dirty_tree
# Given: git status --porcelain returns dirty output
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero AND "working tree" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_dirty_tree ---"
_snapshot_fail

_tmp_dirty="$(_make_tmp)"
_mock_dirty="$_tmp_dirty/bin"
_fake_repo_dirty="$(_make_git_repo)"
mkdir -p "$_fake_repo_dirty/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_dirty/.claude-plugin/marketplace.json"

mkdir -p "$_mock_dirty"
cat > "$_mock_dirty/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  branch)   echo "main"; exit 0 ;;
  status)   echo " M some-file.txt"; exit 0 ;;  # always dirty
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date; dirty tree is the failure
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_dirty/git"

make_mock "$_mock_dirty" "gh" 0 "completed  success  main  CI  1234"
make_mock "$_mock_dirty" "dso" 0

_dirty_exit=0
PATH="$_mock_dirty:$PATH" bash "$SCRIPT" "1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_dirty/stderr.txt" || _dirty_exit=$?
_dirty_stderr=$(cat "$_tmp_dirty/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_dirty_tree: exit non-zero" "0" "$_dirty_exit"
assert_contains "test_release_dirty_tree: working tree in stderr" "working tree" "$_dirty_stderr"
assert_pass_if_clean "test_release_dirty_tree"

# =============================================================================
# test_release_not_on_main
# Given: git branch --show-current returns "feature-x"
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero AND "main" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_not_on_main ---"
_snapshot_fail

_tmp_branch="$(_make_tmp)"
_mock_branch="$_tmp_branch/bin"
_fake_repo_branch="$(_make_git_repo)"
mkdir -p "$_fake_repo_branch/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_branch/.claude-plugin/marketplace.json"

mkdir -p "$_mock_branch"
cat > "$_mock_branch/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  branch)   echo "feature-x"; exit 0 ;;  # wrong branch — the failure
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date; branch check is the failure
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_branch/git"

make_mock "$_mock_branch" "gh" 0 "completed  success  main  CI  1234"
make_mock "$_mock_branch" "dso" 0

_branch_exit=0
PATH="$_mock_branch:$PATH" bash "$SCRIPT" "1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_branch/stderr.txt" || _branch_exit=$?
_branch_stderr=$(cat "$_tmp_branch/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_not_on_main: exit non-zero" "0" "$_branch_exit"
assert_contains "test_release_not_on_main: main in stderr" "main" "$_branch_stderr"
assert_pass_if_clean "test_release_not_on_main"

# =============================================================================
# test_release_not_up_to_date
# Given: git status shows behind origin
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero AND "up-to-date" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_not_up_to_date ---"
_snapshot_fail

_tmp_behind="$(_make_tmp)"
_mock_behind="$_tmp_behind/bin"
_fake_repo_behind="$(_make_git_repo)"
mkdir -p "$_fake_repo_behind/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_behind/.claude-plugin/marketplace.json"

mkdir -p "$_mock_behind"
cat > "$_mock_behind/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;  # clean tree (no --porcelain output)
  fetch)    exit 0 ;;  # fetch succeeds
  rev-list) echo "3"; exit 0 ;;  # 3 commits behind origin (HEAD..@{u})
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_behind/git"

make_mock "$_mock_behind" "gh" 0 "completed  success  main  CI  1234"
make_mock "$_mock_behind" "dso" 0

_behind_exit=0
PATH="$_mock_behind:$PATH" bash "$SCRIPT" "1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_behind/stderr.txt" || _behind_exit=$?
_behind_stderr=$(cat "$_tmp_behind/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_not_up_to_date: exit non-zero" "0" "$_behind_exit"
assert_contains "test_release_not_up_to_date: up-to-date in stderr" "up-to-date" "$_behind_stderr"
assert_pass_if_clean "test_release_not_up_to_date"

# =============================================================================
# test_release_validate_fails
# Given: .claude/scripts/dso exits non-zero for validate.sh --ci
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero AND "validate" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_validate_fails ---"
_snapshot_fail

_tmp_val="$(_make_tmp)"
_mock_val="$_tmp_val/bin"
_fake_repo_val="$(_make_git_repo)"
mkdir -p "$_fake_repo_val/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_val/.claude-plugin/marketplace.json"

mkdir -p "$_mock_val"
cat > "$_mock_val/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date; validate is the failure
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_val/git"

make_mock "$_mock_val" "gh" 0 "completed  success  main  CI  1234"

# dso shim: exits non-zero on validate
cat > "$_mock_val/dso" << 'STUB'
#!/usr/bin/env bash
echo "validation failed" >&2
exit 1
STUB
chmod +x "$_mock_val/dso"

_val_exit=0
PATH="$_mock_val:$PATH" bash "$SCRIPT" "1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_val/stderr.txt" || _val_exit=$?
_val_stderr=$(cat "$_tmp_val/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_validate_fails: exit non-zero" "0" "$_val_exit"
assert_contains "test_release_validate_fails: validate in stderr" "validate" "$_val_stderr"
assert_pass_if_clean "test_release_validate_fails"

# =============================================================================
# test_release_invalid_json
# Given: .claude-plugin/marketplace.json contains invalid JSON
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero
# =============================================================================
echo ""
echo "--- test_release_invalid_json ---"
_snapshot_fail

_tmp_json="$(_make_tmp)"
_mock_json="$_tmp_json/bin"
_fake_repo_json="$(_make_git_repo)"
mkdir -p "$_fake_repo_json/.claude-plugin"
# Write intentionally invalid JSON
printf 'not valid json {{{' > "$_fake_repo_json/.claude-plugin/marketplace.json"

mkdir -p "$_mock_json"
cat > "$_mock_json/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date; invalid JSON is the failure
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_json/git"

make_mock "$_mock_json" "gh" 0 "completed  success  main  CI  1234"
make_mock "$_mock_json" "dso" 0

_json_exit=0
(
    cd "$_fake_repo_json"
    PATH="$_mock_json:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _json_exit=$?

assert_ne "test_release_invalid_json: exit non-zero" "0" "$_json_exit"
assert_pass_if_clean "test_release_invalid_json"

# =============================================================================
# test_release_confirmation_required
# Given: no --yes flag, stdin=/dev/null (no user input possible)
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero AND push stub is NOT called
# =============================================================================
echo ""
echo "--- test_release_confirmation_required ---"
_snapshot_fail

_tmp_conf="$(_make_tmp)"
_mock_conf="$_tmp_conf/bin"
_fake_repo_conf="$(_make_git_repo)"
mkdir -p "$_fake_repo_conf/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_conf/.claude-plugin/marketplace.json"
_push_log_conf="$_tmp_conf/push-calls.log"

mkdir -p "$_mock_conf"
cat > "$_mock_conf/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date
  push)     echo "called" >> "$_push_log_conf"; exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_conf/git"

make_mock "$_mock_conf" "gh" 0 "completed  success  main  CI  1234"
make_mock "$_mock_conf" "dso" 0

_conf_exit=0
(
    cd "$_fake_repo_conf"
    PATH="$_mock_conf:$PATH" bash "$SCRIPT" "1.2.3" < /dev/null > /dev/null 2>/dev/null
) || _conf_exit=$?

_push_calls_conf=0
if [[ -f "$_push_log_conf" ]]; then
    _push_calls_conf=$(wc -l < "$_push_log_conf")
fi

assert_ne "test_release_confirmation_required: exit non-zero without --yes" "0" "$_conf_exit"
assert_eq "test_release_confirmation_required: push NOT called" "0" "$_push_calls_conf"
assert_pass_if_clean "test_release_confirmation_required"

# =============================================================================
# test_release_yes_flag_accepted
# Given: --yes flag AND all preconditions passing
# When:  scripts/release.sh 1.2.3 --yes is called
# Then:  exits 0 AND push stub is called exactly once
# =============================================================================
echo ""
echo "--- test_release_yes_flag_accepted ---"
_snapshot_fail

_tmp_yes="$(_make_tmp)"
_mock_yes="$_tmp_yes/bin"
_fake_repo_yes="$(_make_git_repo)"
mkdir -p "$_fake_repo_yes/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_yes/.claude-plugin/marketplace.json"
_push_log_yes="$_tmp_yes/push-calls.log"

mkdir -p "$_mock_yes"
cat > "$_mock_yes/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date
  push)     echo "called" >> "$_push_log_yes"; exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_yes/git"

make_mock "$_mock_yes" "gh" 0 "completed  success  main  CI  1234"
make_mock "$_mock_yes" "dso" 0

_yes_exit=0
(
    cd "$_fake_repo_yes"
    PATH="$_mock_yes:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _yes_exit=$?

_push_calls_yes=0
if [[ -f "$_push_log_yes" ]]; then
    _push_calls_yes=$(wc -l < "$_push_log_yes")
fi

assert_eq "test_release_yes_flag_accepted: exits 0" "0" "$_yes_exit"
assert_eq "test_release_yes_flag_accepted: push called exactly once" "1" "$_push_calls_yes"
assert_pass_if_clean "test_release_yes_flag_accepted"

# =============================================================================
# test_release_all_preconditions_pass
# Given: all preconditions mocked as passing + --yes
# When:  scripts/release.sh 1.2.3 --yes is called
# Then:  exits 0 (happy path)
# =============================================================================
echo ""
echo "--- test_release_all_preconditions_pass ---"
_snapshot_fail

_tmp_pass="$(_make_tmp)"
_mock_pass="$_tmp_pass/bin"
_fake_repo_pass="$(_make_git_repo)"
mkdir -p "$_fake_repo_pass/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_pass/.claude-plugin/marketplace.json"

mkdir -p "$_mock_pass"
cat > "$_mock_pass/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_pass/git"

make_mock "$_mock_pass" "gh" 0 "completed  success  main  CI  1234"
make_mock "$_mock_pass" "dso" 0

_pass_exit=0
(
    cd "$_fake_repo_pass"
    PATH="$_mock_pass:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _pass_exit=$?

assert_eq "test_release_all_preconditions_pass: exits 0" "0" "$_pass_exit"
assert_pass_if_clean "test_release_all_preconditions_pass"

# =============================================================================
# test_release_yes_does_not_bypass_preconditions  (AC amendment)
# Given: --yes flag BUT mocked dirty tree
# When:  scripts/release.sh 1.2.3 --yes is called
# Then:  exits non-zero AND push stub is NOT called
# =============================================================================
echo ""
echo "--- test_release_yes_does_not_bypass_preconditions ---"
_snapshot_fail

_tmp_bypass="$(_make_tmp)"
_mock_bypass="$_tmp_bypass/bin"
_fake_repo_bypass="$(_make_git_repo)"
mkdir -p "$_fake_repo_bypass/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_bypass/.claude-plugin/marketplace.json"
_push_log_bypass="$_tmp_bypass/push-calls.log"

mkdir -p "$_mock_bypass"
cat > "$_mock_bypass/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)
    echo "main"
    exit 0
    ;;
  status)
    # --porcelain returns dirty output regardless of args
    echo " M dirty-file.txt"
    exit 0
    ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;  # up-to-date (dirty tree is the failure, not behind)
  push)
    echo "called" >> "$_push_log_bypass"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$_mock_bypass/git"

make_mock "$_mock_bypass" "gh" 0 "completed  success  main  CI  1234"
make_mock "$_mock_bypass" "dso" 0

_bypass_exit=0
(
    cd "$_fake_repo_bypass"
    PATH="$_mock_bypass:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _bypass_exit=$?

_push_calls_bypass=0
if [[ -f "$_push_log_bypass" ]]; then
    _push_calls_bypass=$(wc -l < "$_push_log_bypass")
fi

assert_ne "test_release_yes_does_not_bypass_preconditions: exit non-zero" "0" "$_bypass_exit"
assert_eq "test_release_yes_does_not_bypass_preconditions: push NOT called" "0" "$_push_calls_bypass"
assert_pass_if_clean "test_release_yes_does_not_bypass_preconditions"

print_summary
