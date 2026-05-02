#!/usr/bin/env bash
# shellcheck disable=SC2046,SC2329
# tests/scripts/test-merge-to-main-pr.sh
# Tests for merge-to-main-pr.sh PR-creation + auto-merge phase (DD1, DD6).
#
# Tests (all start RED, turn GREEN once Task 4746 _phase_merge is implemented):
#   1. t_pr_create_invocation             — gh invoked with `pr create --base main --head <branch>`
#   2. t_pr_auto_merge_queued             — gh invoked with `pr merge <num> --auto --merge`
#   3. t_pr_state_file_persists_pr_url    — state file gains pr_url + pr_number keys
#   4. t_pr_conflict_emits_conflict_data  — gh reports CONFLICTING → CONFLICT_DATA + non-zero exit
#
# Strategy: PATH-shim `gh` and `git` to record argv into a sentinel file and
# return scripted output. Borrowed directly from test-merge-to-main-dispatcher.sh.
#
# Usage: bash tests/scripts/test-merge-to-main-pr.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Shared fixture builder
# ---------------------------------------------------------------------------
# _build_pr_fixture <tmpdir> <branch> <gh_pr_create_mode> <gh_pr_merge_mode>
#   gh_pr_create_mode:
#     ok      → emit a synthetic PR url ("https://github.com/x/y/pull/42")
#     conflict→ emit no url; subsequent `gh pr view --json mergeable` returns CONFLICTING
#   gh_pr_merge_mode:
#     ok      → exit 0
#     refused → exit 1 with "auto-merge not allowed" stderr
_build_pr_fixture() {
    local tmpdir="$1" branch="$2" pr_create_mode="$3" pr_merge_mode="$4"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"

    # ---- gh shim ----
    local gh_argv_log="$tmpdir/gh-argv.log"
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
# Record full argv (one invocation per line, args tab-separated)
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version)
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
  pr)
    case "\$2" in
      list)
        # Used by duplicate-PR guard — return empty.
        exit 0
        ;;
      create)
        if [[ "$pr_create_mode" == "conflict" ]]; then
          # gh pr create can succeed and PR is created in CONFLICTING state.
          # Emit URL so script proceeds to mergeable check.
          echo "https://github.com/x/y/pull/42"
          exit 0
        fi
        echo "https://github.com/x/y/pull/42"
        exit 0
        ;;
      view)
        # mergeable status query — used in the conflict path to detect CONFLICTING.
        if [[ "$pr_create_mode" == "conflict" ]]; then
          echo '{"mergeable":"CONFLICTING","number":42,"url":"https://github.com/x/y/pull/42"}'
        else
          echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
        fi
        exit 0
        ;;
      merge)
        if [[ "$pr_merge_mode" == "refused" ]]; then
          echo "ERROR: auto-merge is not allowed for this repository" >&2
          exit 1
        fi
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    # ---- git shim wrapper: pass through to real git EXCEPT for `git push` ----
    # We don't want the test to actually push to a real remote. Record push argv
    # and exit 0. Everything else delegates to the real git binary.
    local real_git
    real_git=$(command -v git)
    local git_push_log="$tmpdir/git-push.log"
    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  printf '%s\n' "\$*" >> "$git_push_log"
  exit 0
fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$bin/git"

    # ---- Minimal git repo so `git rev-parse --show-toplevel` resolves and
    #      `git branch --show-current` returns $branch.
    (
        cd "$tmpdir" || exit 1
        # Use real git for setup (bin/ not yet on PATH for this subshell)
        "$real_git" init -q -b main >/dev/null 2>&1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        "$real_git" checkout -q -b "$branch"
        echo "feature" > feature.txt
        "$real_git" add feature.txt
        "$real_git" commit -q -m "feature work" >/dev/null
    )
}

# ---------------------------------------------------------------------------
# Test 1: t_pr_create_invocation
# Asserts gh is invoked with `pr create --base main --head <branch>`.
# ---------------------------------------------------------------------------
t_pr_create_invocation() {
    local _T branch _argv _has_create
    _T="$(mktemp -d /tmp/dso-pr-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-pr-create"
    _build_pr_fixture "$_T" "$branch" "ok" "ok"

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true

    _argv="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    _has_create="false"
    # Match: `pr create --base main --head feature-pr-create ...`
    if echo "$_argv" | grep -qE "^pr create .*--base main .*--head $branch"; then
        _has_create="true"
    elif echo "$_argv" | grep -qE "^pr create .*--head $branch .*--base main"; then
        # Allow flag order variation
        _has_create="true"
    fi

    assert_eq "t_pr_create_invocation_invokes_gh_pr_create" "true" "$_has_create"
}
t_pr_create_invocation

# ---------------------------------------------------------------------------
# Test 2: t_pr_auto_merge_queued
# Asserts gh is invoked with `pr merge 42 --auto --merge` after pr create.
# ---------------------------------------------------------------------------
t_pr_auto_merge_queued() {
    local _T branch _argv _has_merge_42 _uses_merge_strategy _has_auto
    _T="$(mktemp -d /tmp/dso-pr-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-auto-merge"
    _build_pr_fixture "$_T" "$branch" "ok" "ok"

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true

    _argv="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    _has_merge_42="false"
    _uses_merge_strategy="false"
    _has_auto="false"
    if echo "$_argv" | grep -qE "^pr merge 42"; then
        _has_merge_42="true"
    fi
    if echo "$_argv" | grep -E "^pr merge 42" | grep -q -- "--merge"; then
        _uses_merge_strategy="true"
    fi
    if echo "$_argv" | grep -E "^pr merge 42" | grep -q -- "--auto"; then
        _has_auto="true"
    fi

    assert_eq "t_pr_auto_merge_queued_invokes_pr_merge_with_pr_number" "true" "$_has_merge_42"
    assert_eq "t_pr_auto_merge_queued_uses_merge_not_squash" "true" "$_uses_merge_strategy"
    assert_eq "t_pr_auto_merge_queued_passes_auto_flag" "true" "$_has_auto"
}
t_pr_auto_merge_queued

# ---------------------------------------------------------------------------
# Test 3: t_pr_state_file_persists_pr_url
# Asserts the state file written by the merge phase contains pr_url and
# pr_number keys after a successful PR creation.
# ---------------------------------------------------------------------------
t_pr_state_file_persists_pr_url() {
    local _T branch _state_file _pr_url _pr_number _branch_safe
    _T="$(mktemp -d /tmp/dso-pr-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-state-persist"
    _build_pr_fixture "$_T" "$branch" "ok" "ok"

    _branch_safe="${branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true

    _pr_url="$(python3 -c "
import json
try:
    d = json.load(open('$_state_file'))
    print(d.get('pr_url', 'MISSING'))
except Exception as e:
    print('ERR:' + str(e))
" 2>/dev/null)"

    _pr_number="$(python3 -c "
import json
try:
    d = json.load(open('$_state_file'))
    print(d.get('pr_number', 'MISSING'))
except Exception as e:
    print('ERR:' + str(e))
" 2>/dev/null)"

    assert_contains "t_pr_state_file_persists_pr_url_url_recorded" "pull/42" "$_pr_url"
    assert_eq "t_pr_state_file_persists_pr_number_recorded" "42" "$_pr_number"
}
t_pr_state_file_persists_pr_url

# ---------------------------------------------------------------------------
# Test 4: t_pr_conflict_emits_conflict_data
# When gh reports mergeable=CONFLICTING, the script must emit CONFLICT_DATA
# (with the four-key contract) and exit non-zero.
# ---------------------------------------------------------------------------
t_pr_conflict_emits_conflict_data() {
    local _T branch _out _ec _branch_safe _state_file
    _T="$(mktemp -d /tmp/dso-pr-test.XXXXXX)"
    branch="feature-conflict"
    _branch_safe="${branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    _build_pr_fixture "$_T" "$branch" "conflict" "ok"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        bash "$PR_SCRIPT" 2>&1
    )"; _ec=$?

    local _has_conflict_data="false"
    local _has_branch="false"
    local _has_base_branch="false"
    local _has_conflicted_files="false"
    local _has_resolution_strategy="false"
    local _exits_nonzero="false"

    [[ "$_ec" -ne 0 ]] && _exits_nonzero="true"
    if echo "$_out" | grep -q "CONFLICT_DATA"; then
        _has_conflict_data="true"
        echo "$_out" | grep -q '"branch"' && _has_branch="true"
        echo "$_out" | grep -q '"base_branch"' && _has_base_branch="true"
        echo "$_out" | grep -q '"conflicted_files"' && _has_conflicted_files="true"
        echo "$_out" | grep -q '"resolution_strategy"' && _has_resolution_strategy="true"
    fi

    assert_eq "t_pr_conflict_emits_conflict_data_emitted" "true" "$_has_conflict_data"
    assert_eq "t_pr_conflict_emits_conflict_data_exits_nonzero" "true" "$_exits_nonzero"
    assert_eq "t_pr_conflict_emits_conflict_data_has_branch" "true" "$_has_branch"
    assert_eq "t_pr_conflict_emits_conflict_data_has_base_branch" "true" "$_has_base_branch"
    assert_eq "t_pr_conflict_emits_conflict_data_has_conflicted_files" "true" "$_has_conflicted_files"
    assert_eq "t_pr_conflict_emits_conflict_data_has_resolution_strategy" "true" "$_has_resolution_strategy"
}
t_pr_conflict_emits_conflict_data

# ---------------------------------------------------------------------------
print_summary
