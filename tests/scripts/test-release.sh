#!/usr/bin/env bash
# tests/scripts/test-release.sh
# Tests for scripts/release.sh precondition logic.
#
# Test cases:
#   1. test_release_ci_not_green
#   2. test_release_dirty_tree
#   3. test_release_not_on_main
#   4. test_release_not_up_to_date
#   5. test_release_validate_fails
#   6. test_release_invalid_json
#   7. test_release_confirmation_required
#   8. test_release_yes_flag_accepted
#   9. test_release_all_preconditions_pass
#  10. test_release_yes_does_not_bypass_preconditions
#  11. test_release_invalid_semver
#  12. test_release_gh_not_authenticated
#  13. test_release_tag_already_exists
#  14. test_release_push_failure
#  15. test_release_no_upstream_configured
#  16. test_release_ci_polls_in_progress_then_succeeds
#  17. test_release_ci_polls_in_progress_then_fails
#  18. test_release_defaults_version_from_plugin_json
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
# test_release_ci_not_green
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
  branch)    echo "main"; exit 0 ;;
  status)    exit 0 ;;
  fetch)     exit 0 ;;
  rev-list)  echo "0"; exit 0 ;;  # up-to-date; CI check is the failure
  rev-parse) echo "deadbeef000000"; exit 0 ;;
  push)      exit 0 ;;
  *)         exit 0 ;;
esac
STUB
chmod +x "$_mock_ci/git"

# gh: auth succeeds, but run list returns non-success conclusion (CI not green)
cat > "$_mock_ci/gh" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;  # auth status passes
  run)  echo '[{"conclusion":"failure"}]'; exit 0 ;;  # CI failed conclusion
  *)    exit 0 ;;
esac
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
  branch)    echo "main"; exit 0 ;;
  status)    echo " M some-file.txt"; exit 0 ;;  # always dirty
  fetch)     exit 0 ;;
  rev-list)  echo "0"; exit 0 ;;  # up-to-date; dirty tree is the failure
  rev-parse) echo "deadbeef000000"; exit 0 ;;
  push)      exit 0 ;;
  *)         exit 0 ;;
esac
STUB
chmod +x "$_mock_dirty/git"

make_mock "$_mock_dirty" "gh" 0 '[{"conclusion":"success"}]'
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
  branch)    echo "feature-x"; exit 0 ;;  # wrong branch — the failure
  status)    exit 0 ;;
  fetch)     exit 0 ;;
  rev-list)  echo "0"; exit 0 ;;  # up-to-date; branch check is the failure
  rev-parse) echo "deadbeef000000"; exit 0 ;;
  push)      exit 0 ;;
  *)         exit 0 ;;
esac
STUB
chmod +x "$_mock_branch/git"

make_mock "$_mock_branch" "gh" 0 '[{"conclusion":"success"}]'
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
  branch)    echo "main"; exit 0 ;;
  status)    exit 0 ;;  # clean tree (no --porcelain output)
  fetch)     exit 0 ;;  # fetch succeeds
  rev-list)  echo "3"; exit 0 ;;  # 3 commits behind origin (HEAD..@{u})
  rev-parse) echo "deadbeef000000"; exit 0 ;;
  push)      exit 0 ;;
  *)         exit 0 ;;
esac
STUB
chmod +x "$_mock_behind/git"

make_mock "$_mock_behind" "gh" 0 '[{"conclusion":"success"}]'
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

# Create failing dso shim at the absolute path release.sh will call
mkdir -p "$_fake_repo_val/.claude/scripts"
cat > "$_fake_repo_val/.claude/scripts/dso" << 'STUB'
#!/usr/bin/env bash
echo "validation failed" >&2
exit 1
STUB
chmod +x "$_fake_repo_val/.claude/scripts/dso"

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

make_mock "$_mock_val" "gh" 0 '[{"conclusion":"success"}]'

_val_exit=0
(
    cd "$_fake_repo_val"
    PATH="$_mock_val:$PATH" bash "$SCRIPT" "1.2.3" --yes \
        < /dev/null > /dev/null 2>"$_tmp_val/stderr.txt"
) || _val_exit=$?
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

# Passing dso shim so validate check succeeds and JSON check is the failure
mkdir -p "$_fake_repo_json/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_fake_repo_json/.claude/scripts/dso"
chmod +x "$_fake_repo_json/.claude/scripts/dso"

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

make_mock "$_mock_json" "gh" 0 '[{"conclusion":"success"}]'
make_mock "$_mock_json" "dso" 0

_json_exit=0
(
    cd "$_fake_repo_json"
    PATH="$_mock_json:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>"$_tmp_json/stderr.txt"
) || _json_exit=$?
_json_stderr=$(cat "$_tmp_json/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_invalid_json: exit non-zero" "0" "$_json_exit"
assert_contains "test_release_invalid_json: marketplace.json in stderr" "marketplace.json" "$_json_stderr"
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

# Passing dso shim so confirmation check is the failure (not missing dso)
mkdir -p "$_fake_repo_conf/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_fake_repo_conf/.claude/scripts/dso"
chmod +x "$_fake_repo_conf/.claude/scripts/dso"

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

make_mock "$_mock_conf" "gh" 0 '[{"conclusion":"success"}]'
make_mock "$_mock_conf" "dso" 0

_conf_exit=0
(
    cd "$_fake_repo_conf"
    PATH="$_mock_conf:$PATH" bash "$SCRIPT" "1.2.3" < /dev/null > /dev/null 2>/dev/null
) || _conf_exit=$?

_push_calls_conf=0
if [[ -f "$_push_log_conf" ]]; then
    _push_calls_conf=$(wc -l < "$_push_log_conf" | tr -d ' ')
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
_tag_log_yes="$_tmp_yes/tag-calls.log"

# Passing dso shim at the absolute path release.sh will invoke
mkdir -p "$_fake_repo_yes/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_fake_repo_yes/.claude/scripts/dso"
chmod +x "$_fake_repo_yes/.claude/scripts/dso"

mkdir -p "$_mock_yes"
cat > "$_mock_yes/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;
  rev-parse)
    case "\$2" in
      --show-toplevel) echo "$_fake_repo_yes"; exit 0 ;;
      --abbrev-ref)    echo "origin/main"; exit 0 ;;
      *)               echo "deadbeef000000"; exit 0 ;;
    esac
    ;;
  tag)
    [[ "\$2" == "-a" ]] && echo "called" >> "$_tag_log_yes"  # only record tag creation
    exit 0
    ;;
  push) echo "called" >> "$_push_log_yes"; exit 0 ;;
  *)    exit 0 ;;
esac
STUB
chmod +x "$_mock_yes/git"

make_mock "$_mock_yes" "gh" 0 '[{"conclusion":"success"}]'

_yes_exit=0
(
    cd "$_fake_repo_yes"
    PATH="$_mock_yes:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _yes_exit=$?

_push_calls_yes=0
if [[ -f "$_push_log_yes" ]]; then
    _push_calls_yes=$(wc -l < "$_push_log_yes" | tr -d ' ')
fi
_tag_calls_yes=0
if [[ -f "$_tag_log_yes" ]]; then
    _tag_calls_yes=$(wc -l < "$_tag_log_yes" | tr -d ' ')
fi

assert_eq "test_release_yes_flag_accepted: exits 0" "0" "$_yes_exit"
assert_eq "test_release_yes_flag_accepted: tag called" "1" "$_tag_calls_yes"
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
_tag_log_pass="$_tmp_pass/tag-calls.log"
_push_log_pass="$_tmp_pass/push-calls.log"

# Passing dso shim at the absolute path release.sh will invoke
mkdir -p "$_fake_repo_pass/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_fake_repo_pass/.claude/scripts/dso"
chmod +x "$_fake_repo_pass/.claude/scripts/dso"

mkdir -p "$_mock_pass"
cat > "$_mock_pass/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;
  rev-parse)
    case "\$2" in
      --show-toplevel) echo "$_fake_repo_pass"; exit 0 ;;
      --abbrev-ref)    echo "origin/main"; exit 0 ;;
      *)               echo "deadbeef000000"; exit 0 ;;
    esac
    ;;
  tag)
    [[ "\$2" == "-a" ]] && echo "called" >> "$_tag_log_pass"
    exit 0
    ;;
  push) echo "called" >> "$_push_log_pass"; exit 0 ;;
  *)    exit 0 ;;
esac
STUB
chmod +x "$_mock_pass/git"

make_mock "$_mock_pass" "gh" 0 '[{"conclusion":"success"}]'

_pass_exit=0
(
    cd "$_fake_repo_pass"
    PATH="$_mock_pass:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _pass_exit=$?

_tag_calls_pass=0
if [[ -f "$_tag_log_pass" ]]; then
    _tag_calls_pass=$(wc -l < "$_tag_log_pass" | tr -d ' ')
fi
_push_calls_pass=0
if [[ -f "$_push_log_pass" ]]; then
    _push_calls_pass=$(wc -l < "$_push_log_pass" | tr -d ' ')
fi

assert_eq "test_release_all_preconditions_pass: exits 0" "0" "$_pass_exit"
assert_eq "test_release_all_preconditions_pass: tag created" "1" "$_tag_calls_pass"
assert_eq "test_release_all_preconditions_pass: push called" "1" "$_push_calls_pass"
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

make_mock "$_mock_bypass" "gh" 0 '[{"conclusion":"success"}]'
make_mock "$_mock_bypass" "dso" 0

_bypass_exit=0
(
    cd "$_fake_repo_bypass"
    PATH="$_mock_bypass:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _bypass_exit=$?

_push_calls_bypass=0
if [[ -f "$_push_log_bypass" ]]; then
    _push_calls_bypass=$(wc -l < "$_push_log_bypass" | tr -d ' ')
fi

assert_ne "test_release_yes_does_not_bypass_preconditions: exit non-zero" "0" "$_bypass_exit"
assert_eq "test_release_yes_does_not_bypass_preconditions: push NOT called" "0" "$_push_calls_bypass"
assert_pass_if_clean "test_release_yes_does_not_bypass_preconditions"

# =============================================================================
# test_release_invalid_semver
# Given: VERSION is not valid semver (e.g., "1.2" or "v1.2.3")
# When:  scripts/release.sh is called
# Then:  exits non-zero AND "semver" or "Invalid" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_invalid_semver ---"
_snapshot_fail

_tmp_semver="$(_make_tmp)"
_mock_semver="$_tmp_semver/bin"

_semver_exit=0
PATH="$_mock_semver:$PATH" bash "$SCRIPT" "1.2" --yes \
    < /dev/null > /dev/null 2>"$_tmp_semver/stderr.txt" || _semver_exit=$?
_semver_stderr=$(cat "$_tmp_semver/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_invalid_semver: exit non-zero for '1.2'" "0" "$_semver_exit"
assert_contains "test_release_invalid_semver: error in stderr" "Invalid" "$_semver_stderr"

_semver2_exit=0
PATH="$_mock_semver:$PATH" bash "$SCRIPT" "v1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_semver/stderr2.txt" || _semver2_exit=$?
_semver2_stderr=$(cat "$_tmp_semver/stderr2.txt" 2>/dev/null || true)

assert_ne "test_release_invalid_semver: exit non-zero for 'v1.2.3'" "0" "$_semver2_exit"
assert_contains "test_release_invalid_semver: error in stderr for v-prefixed" "Invalid" "$_semver2_stderr"
assert_pass_if_clean "test_release_invalid_semver"

# =============================================================================
# test_release_gh_not_authenticated
# Given: gh auth status exits non-zero
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero AND "gh" or "authenticated" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_gh_not_authenticated ---"
_snapshot_fail

_tmp_ghauth="$(_make_tmp)"
_mock_ghauth="$_tmp_ghauth/bin"
mkdir -p "$_mock_ghauth"

make_mock "$_mock_ghauth" "git" 0
# gh auth status returns non-zero (not authenticated)
cat > "$_mock_ghauth/gh" << 'STUB'
#!/usr/bin/env bash
echo "You are not logged into any GitHub hosts." >&2
exit 1
STUB
chmod +x "$_mock_ghauth/gh"

_ghauth_exit=0
PATH="$_mock_ghauth:$PATH" bash "$SCRIPT" "1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_ghauth/stderr.txt" || _ghauth_exit=$?
_ghauth_stderr=$(cat "$_tmp_ghauth/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_gh_not_authenticated: exit non-zero" "0" "$_ghauth_exit"
assert_contains "test_release_gh_not_authenticated: gh in stderr" "gh" "$_ghauth_stderr"
assert_pass_if_clean "test_release_gh_not_authenticated"

# =============================================================================
# test_release_tag_already_exists
# Given: git tag -l returns the tag (it already exists)
# When:  scripts/release.sh 1.2.3 is called
# Then:  exits non-zero AND "already exists" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_tag_already_exists ---"
_snapshot_fail

_tmp_tagex="$(_make_tmp)"
_mock_tagex="$_tmp_tagex/bin"
mkdir -p "$_mock_tagex"

# gh auth passes
make_mock "$_mock_tagex" "gh" 0 '[{"conclusion":"success"}]'

# git mock: tag -l returns the tag (already exists)
cat > "$_mock_tagex/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  tag)      echo "v1.2.3"; exit 0 ;;  # tag already exists
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_tagex/git"

_tagex_exit=0
PATH="$_mock_tagex:$PATH" bash "$SCRIPT" "1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_tagex/stderr.txt" || _tagex_exit=$?
_tagex_stderr=$(cat "$_tmp_tagex/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_tag_already_exists: exit non-zero" "0" "$_tagex_exit"
assert_contains "test_release_tag_already_exists: already exists in stderr" "already exists" "$_tagex_stderr"
assert_pass_if_clean "test_release_tag_already_exists"

# =============================================================================
# test_release_push_failure
# Given: git push --follow-tags fails (e.g., rejected by remote)
# When:  scripts/release.sh 1.2.3 --yes is called
# Then:  exits non-zero (set -euo pipefail aborts on push failure)
# =============================================================================
echo ""
echo "--- test_release_push_failure ---"
_snapshot_fail

_tmp_push_fail="$(_make_tmp)"
_mock_push_fail="$_tmp_push_fail/bin"
_fake_repo_push_fail="$(_make_git_repo)"
mkdir -p "$_fake_repo_push_fail/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_push_fail/.claude-plugin/marketplace.json"

mkdir -p "$_fake_repo_push_fail/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_fake_repo_push_fail/.claude/scripts/dso"
chmod +x "$_fake_repo_push_fail/.claude/scripts/dso"

mkdir -p "$_mock_push_fail"
cat > "$_mock_push_fail/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)    echo "main"; exit 0 ;;
  status)    exit 0 ;;
  fetch)     exit 0 ;;
  rev-list)  echo "0"; exit 0 ;;
  rev-parse) echo "deadbeef000000"; exit 0 ;;
  tag)       exit 0 ;;   # tag creation succeeds
  push)      echo "remote: push rejected" >&2; exit 1 ;;  # push fails
  *)         exit 0 ;;
esac
STUB
chmod +x "$_mock_push_fail/git"

make_mock "$_mock_push_fail" "gh" 0 '[{"conclusion":"success"}]'

_push_fail_exit=0
(
    cd "$_fake_repo_push_fail"
    PATH="$_mock_push_fail:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _push_fail_exit=$?

assert_ne "test_release_push_failure: exits non-zero when push fails" "0" "$_push_fail_exit"
assert_pass_if_clean "test_release_push_failure"

# =============================================================================
# test_release_no_upstream_configured
# Given: git rev-parse --abbrev-ref HEAD@{upstream} exits non-zero (no upstream)
# When:  scripts/release.sh 1.2.3 --yes is called
# Then:  exits non-zero AND "upstream" or "tracking" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_no_upstream_configured ---"
_snapshot_fail

_tmp_noup="$(_make_tmp)"
_mock_noup="$_tmp_noup/bin"
mkdir -p "$_mock_noup"

cat > "$_mock_noup/git" << 'STUB'
#!/usr/bin/env bash
case "$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-parse)
    if [[ "$2" == "--abbrev-ref" ]]; then
      # Simulate no upstream tracking branch configured
      echo "fatal: no upstream configured for branch 'main'" >&2
      exit 1
    fi
    echo "deadbeef000000"; exit 0
    ;;
  rev-list) echo "0"; exit 0 ;;
  push)     exit 0 ;;
  *)        exit 0 ;;
esac
STUB
chmod +x "$_mock_noup/git"

make_mock "$_mock_noup" "gh" 0 '[{"conclusion":"success"}]'

_noup_exit=0
PATH="$_mock_noup:$PATH" bash "$SCRIPT" "1.2.3" --yes \
    < /dev/null > /dev/null 2>"$_tmp_noup/stderr.txt" || _noup_exit=$?
_noup_stderr=$(cat "$_tmp_noup/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_no_upstream_configured: exit non-zero" "0" "$_noup_exit"
assert_contains "test_release_no_upstream_configured: upstream in stderr" "upstream" "$_noup_stderr"
assert_pass_if_clean "test_release_no_upstream_configured"

# =============================================================================
# test_release_ci_polls_in_progress_then_succeeds
# Given: gh returns in_progress on the first call, then success on the second
# When:  scripts/release.sh 1.2.3 --yes is called
# Then:  exits zero (release proceeds) and "rechecking" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_ci_polls_in_progress_then_succeeds ---"
_snapshot_fail

_tmp_poll_ok="$(_make_tmp)"
_mock_poll_ok="$_tmp_poll_ok/bin"
mkdir -p "$_mock_poll_ok"
_fake_repo_poll_ok="$(_make_git_repo)"
mkdir -p "$_fake_repo_poll_ok/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_poll_ok/.claude-plugin/marketplace.json"

mkdir -p "$_fake_repo_poll_ok/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_fake_repo_poll_ok/.claude/scripts/dso"
chmod +x "$_fake_repo_poll_ok/.claude/scripts/dso"

# gh: first run list call returns in_progress (no conclusion), second returns success
_poll_ok_call_file="$_tmp_poll_ok/gh_call_count"
echo "0" > "$_poll_ok_call_file"
cat > "$_mock_poll_ok/gh" << STUB
#!/usr/bin/env bash
_CALL_FILE="$_poll_ok_call_file"
case "\$1" in
  auth) exit 0 ;;
  run)
    _count=\$(cat "\$_CALL_FILE" 2>/dev/null || echo 0)
    _count=\$(( _count + 1 ))
    echo "\$_count" > "\$_CALL_FILE"
    if [[ "\$_count" -le 1 ]]; then
      echo '[{"status":"in_progress","conclusion":""}]'
    else
      echo '[{"status":"completed","conclusion":"success"}]'
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$_mock_poll_ok/gh"

# Mock sleep so the test doesn't actually wait 30s
cat > "$_mock_poll_ok/sleep" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$_mock_poll_ok/sleep"

cat > "$_mock_poll_ok/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)    echo "main"; exit 0 ;;
  status)    exit 0 ;;
  fetch)     exit 0 ;;
  rev-list)  echo "0"; exit 0 ;;
  rev-parse)
    case "\$2" in
      --show-toplevel) echo "$_fake_repo_poll_ok"; exit 0 ;;
      --abbrev-ref)    echo "origin/main"; exit 0 ;;
      *)               echo "deadbeef000000"; exit 0 ;;
    esac
    ;;
  tag)  exit 0 ;;
  push) exit 0 ;;
  *)    exit 0 ;;
esac
STUB
chmod +x "$_mock_poll_ok/git"

_poll_ok_exit=0
(
    cd "$_fake_repo_poll_ok"
    PATH="$_mock_poll_ok:$PATH" bash "$SCRIPT" "1.2.3" --yes \
        < /dev/null > /dev/null 2>"$_tmp_poll_ok/stderr.txt"
) || _poll_ok_exit=$?
_poll_ok_stderr=$(cat "$_tmp_poll_ok/stderr.txt" 2>/dev/null || true)

assert_eq  "test_release_ci_polls_in_progress_then_succeeds: exit zero" "0" "$_poll_ok_exit"
assert_contains "test_release_ci_polls_in_progress_then_succeeds: rechecking in stderr" "rechecking" "$_poll_ok_stderr"
assert_pass_if_clean "test_release_ci_polls_in_progress_then_succeeds"

# =============================================================================
# test_release_ci_polls_in_progress_then_fails
# Given: gh returns in_progress on the first call, then failure on the second
# When:  scripts/release.sh 1.2.3 --yes is called
# Then:  exits non-zero and "CI" appears in stderr
# =============================================================================
echo ""
echo "--- test_release_ci_polls_in_progress_then_fails ---"
_snapshot_fail

_tmp_poll_fail="$(_make_tmp)"
_mock_poll_fail="$_tmp_poll_fail/bin"
mkdir -p "$_mock_poll_fail"
_fake_repo_poll_fail="$(_make_git_repo)"
mkdir -p "$_fake_repo_poll_fail/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_poll_fail/.claude-plugin/marketplace.json"

_poll_fail_call_file="$_tmp_poll_fail/gh_call_count"
echo "0" > "$_poll_fail_call_file"
cat > "$_mock_poll_fail/gh" << STUB
#!/usr/bin/env bash
_CALL_FILE="$_poll_fail_call_file"
case "\$1" in
  auth) exit 0 ;;
  run)
    _count=\$(cat "\$_CALL_FILE" 2>/dev/null || echo 0)
    _count=\$(( _count + 1 ))
    echo "\$_count" > "\$_CALL_FILE"
    if [[ "\$_count" -le 1 ]]; then
      echo '[{"status":"in_progress","conclusion":""}]'
    else
      echo '[{"status":"completed","conclusion":"failure"}]'
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$_mock_poll_fail/gh"

cat > "$_mock_poll_fail/sleep" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$_mock_poll_fail/sleep"

cat > "$_mock_poll_fail/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)    echo "main"; exit 0 ;;
  status)    exit 0 ;;
  fetch)     exit 0 ;;
  rev-list)  echo "0"; exit 0 ;;
  rev-parse)
    case "\$2" in
      --show-toplevel) echo "$_fake_repo_poll_fail"; exit 0 ;;
      --abbrev-ref)    echo "origin/main"; exit 0 ;;
      *)               echo "deadbeef000000"; exit 0 ;;
    esac
    ;;
  push) exit 0 ;;
  *)    exit 0 ;;
esac
STUB
chmod +x "$_mock_poll_fail/git"

_poll_fail_exit=0
(
    cd "$_fake_repo_poll_fail"
    PATH="$_mock_poll_fail:$PATH" bash "$SCRIPT" "1.2.3" --yes \
        < /dev/null > /dev/null 2>"$_tmp_poll_fail/stderr.txt"
) || _poll_fail_exit=$?
_poll_fail_stderr=$(cat "$_tmp_poll_fail/stderr.txt" 2>/dev/null || true)

assert_ne "test_release_ci_polls_in_progress_then_fails: exit non-zero" "0" "$_poll_fail_exit"
assert_contains "test_release_ci_polls_in_progress_then_fails: CI in stderr" "CI" "$_poll_fail_stderr"
assert_pass_if_clean "test_release_ci_polls_in_progress_then_fails"

# =============================================================================
# test_release_defaults_version_from_plugin_json
# Given: no VERSION argument, plugin.json exists with a valid semver
# When:  scripts/release.sh --yes is called (no positional VERSION)
# Then:  exits 0, stderr contains "Using version from plugin.json:", and
#        the version used matches the one in plugin.json
# =============================================================================
echo ""
echo "--- test_release_defaults_version_from_plugin_json ---"
_snapshot_fail

_tmp_defver="$(_make_tmp)"
_mock_defver="$_tmp_defver/bin"
mkdir -p "$_mock_defver"
_fake_repo_defver="$(_make_git_repo)"

mkdir -p "$_fake_repo_defver/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_defver/.claude-plugin/marketplace.json"
mkdir -p "$_fake_repo_defver/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_fake_repo_defver/.claude/scripts/dso"
chmod +x "$_fake_repo_defver/.claude/scripts/dso"

# Read expected version from real plugin.json (the path the script will resolve to)
_defver_expected=$(python3 -c "
import json, os, sys
p = os.path.join('$REPO_ROOT', 'plugins', 'dso', '.claude-plugin', 'plugin.json')
print(json.load(open(p))['version'])
" 2>/dev/null || echo "")
_defver_tag="v${_defver_expected}"
_defver_tag_log="$_tmp_defver/tag-calls.log"

cat > "$_mock_defver/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)   echo "main"; exit 0 ;;
  status)   exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;
  rev-parse)
    case "\$2" in
      --show-toplevel) echo "$_fake_repo_defver"; exit 0 ;;
      --abbrev-ref)    echo "origin/main"; exit 0 ;;
      *)               echo "deadbeef000000"; exit 0 ;;
    esac
    ;;
  tag)
    if [[ "\$2" == "-a" ]]; then
      echo "\$3" >> "$_defver_tag_log"
    fi
    exit 0
    ;;
  push) exit 0 ;;
  *)    exit 0 ;;
esac
STUB
chmod +x "$_mock_defver/git"

make_mock "$_mock_defver" "gh" 0 '[{"conclusion":"success"}]'

_defver_exit=0
_defver_stderr=""
(
    cd "$_fake_repo_defver"
    PATH="$_mock_defver:$PATH" bash "$SCRIPT" --yes < /dev/null > /dev/null 2>"$_tmp_defver/stderr.txt"
) || _defver_exit=$?
_defver_stderr=$(cat "$_tmp_defver/stderr.txt" 2>/dev/null || true)

assert_eq "test_release_defaults_version_from_plugin_json: exits 0" "0" "$_defver_exit"
assert_contains "test_release_defaults_version_from_plugin_json: stderr reports version source" \
    "Using version from plugin.json" "$_defver_stderr"

# Verify the tag used matches the version from plugin.json
_defver_tagged=""
if [[ -f "$_defver_tag_log" ]]; then
    _defver_tagged=$(head -1 "$_defver_tag_log" | tr -d '[:space:]')
fi
assert_eq "test_release_defaults_version_from_plugin_json: tag uses plugin.json version" \
    "$_defver_tag" "$_defver_tagged"

assert_pass_if_clean "test_release_defaults_version_from_plugin_json"

# =============================================================================
# test_release_tag_points_to_bump_commit
# Given: tag-release.sh leaves version files dirty (simulated by stateful git
#        status mock returning dirty after the precondition clean check)
# When:  scripts/release.sh 1.2.3 --yes is called
# Then:  git commit is called BEFORE git tag -a (so tag lands on bump commit)
# =============================================================================
echo ""
echo "--- test_release_tag_points_to_bump_commit ---"
_snapshot_fail

_tmp_order="$(_make_tmp)"
_mock_order="$_tmp_order/bin"
_fake_repo_order="$(_make_git_repo)"
mkdir -p "$_fake_repo_order/.claude-plugin"
printf '{"name":"p","version":"1.0.0"}' > "$_fake_repo_order/.claude-plugin/marketplace.json"
_call_seq_log="$_tmp_order/call-sequence.log"
_status_call_count="$_tmp_order/status-call-count"
echo "0" > "$_status_call_count"

mkdir -p "$_fake_repo_order/.claude/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_fake_repo_order/.claude/scripts/dso"
chmod +x "$_fake_repo_order/.claude/scripts/dso"

mkdir -p "$_mock_order"
cat > "$_mock_order/git" << STUB
#!/usr/bin/env bash
case "\$1" in
  branch)   echo "main"; exit 0 ;;
  fetch)    exit 0 ;;
  rev-list) echo "0"; exit 0 ;;
  rev-parse)
    case "\$2" in
      --show-toplevel) echo "$_fake_repo_order"; exit 0 ;;
      --abbrev-ref)    echo "origin/main"; exit 0 ;;
      *)               echo "deadbeef000000"; exit 0 ;;
    esac
    ;;
  status)
    # First call: clean (precondition check). Subsequent calls: dirty (post-bump).
    _cnt=\$(cat "$_status_call_count" 2>/dev/null || echo 0)
    echo \$((_cnt + 1)) > "$_status_call_count"
    if [[ "\$_cnt" -gt 0 ]]; then
      echo " M plugins/dso/.claude-plugin/plugin.json"
    fi
    exit 0
    ;;
  add)    exit 0 ;;
  commit)
    echo "commit" >> "$_call_seq_log"
    exit 0
    ;;
  tag)
    [[ "\$2" == "-a" ]] && echo "tag" >> "$_call_seq_log"
    exit 0
    ;;
  push)   exit 0 ;;
  *)      exit 0 ;;
esac
STUB
chmod +x "$_mock_order/git"

make_mock "$_mock_order" "gh" 0 '[{"conclusion":"success"}]'

_order_exit=0
(
    cd "$_fake_repo_order"
    PATH="$_mock_order:$PATH" bash "$SCRIPT" "1.2.3" --yes < /dev/null > /dev/null 2>/dev/null
) || _order_exit=$?

assert_eq "test_release_tag_points_to_bump_commit: exits 0" "0" "$_order_exit"

# Verify commit appeared before tag in the call sequence
_commit_line=0
_tag_line=0
if [[ -f "$_call_seq_log" ]]; then
    _commit_line=$(grep -n "^commit$" "$_call_seq_log" | head -1 | cut -d: -f1 || echo 0)
    _tag_line=$(grep -n "^tag$" "$_call_seq_log" | head -1 | cut -d: -f1 || echo 0)
fi
_commit_before_tag=0
if [[ -n "$_commit_line" && -n "$_tag_line" && "$_commit_line" -gt 0 && "$_tag_line" -gt 0 && "$_commit_line" -lt "$_tag_line" ]]; then
    _commit_before_tag=1
fi
assert_eq "test_release_tag_points_to_bump_commit: commit called before tag (tag lands on bump commit)" "1" "$_commit_before_tag"

assert_pass_if_clean "test_release_tag_points_to_bump_commit"

print_summary
