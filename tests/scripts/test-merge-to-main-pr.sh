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
        # gh pr view --json mergeable — pre-auto-merge check
        # gh pr view --json state — polling-phase check (return MERGED so loop exits)
        if [[ "\$*" == *"--json state"* ]]; then
          echo "MERGED"
          exit 0
        fi
        if [[ "$pr_create_mode" == "conflict" ]]; then
          echo '{"mergeable":"CONFLICTING","number":42,"url":"https://github.com/x/y/pull/42"}'
        else
          echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
        fi
        exit 0
        ;;
      checks)
        # Polling-phase: return all SUCCESS so the loop proceeds to state check.
        echo '[{"name":"ci","state":"COMPLETED","conclusion":"SUCCESS"}]'
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
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
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
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
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
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
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
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
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

# ===========================================================================
# Polling-loop tests (Task f7cf-4f1b — DD1, DD2, DD3)
# ===========================================================================
#
# Polling fixture extends _build_pr_fixture's gh shim with iteration-aware
# behavior for `gh pr checks` and `gh pr view --json state`. A counter file
# tracks the iteration number across gh invocations.
#
# _build_pr_polling_fixture <tmpdir> <branch> <mode>
#   mode:
#     success_after_2  → iter 1: IN_PROGRESS / OPEN; iter 2: SUCCESS / MERGED
#     check_failure    → iter 1: FAILURE → exit 1
#     forever_pending  → always IN_PROGRESS / OPEN (used with low max_wait)
#     success_after_3  → iters 1,2: IN_PROGRESS; iter 3: SUCCESS / MERGED
#                        (used to assert ONE pr-checks call per iteration)
_build_pr_polling_fixture() {
    local tmpdir="$1" branch="$2" mode="$3"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"

    local gh_argv_log="$tmpdir/gh-argv.log"
    local checks_counter="$tmpdir/checks-counter"
    : > "$checks_counter"  # zero-length → iteration 0 before first call

    # ---- Build the remote and seed the merge commit BEFORE writing shims ----
    # merge_sha must be captured first so it can be baked into the gh shim heredoc
    # at write time (runtime file reads proved unreliable on Linux CI / git 2.53.0).
    local real_git
    real_git=$(command -v git)
    local git_push_log="$tmpdir/git-push.log"

    local remote_dir="$tmpdir/remote.git"
    "$real_git" init -q --bare -b main "$remote_dir" >/dev/null 2>&1
    local seed_dir="$tmpdir/seed-poll"
    "$real_git" init -q -b main "$seed_dir" >/dev/null 2>&1
    (
        cd "$seed_dir" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        "$real_git" checkout -q -b feat
        echo "feat" > feat.txt
        "$real_git" add feat.txt
        "$real_git" commit -q -m "feat" >/dev/null
        "$real_git" checkout -q main
        "$real_git" merge --no-ff -q feat -m "merge feat" >/dev/null
    )
    local merge_sha
    merge_sha=$("$real_git" -C "$seed_dir" rev-parse HEAD)
    echo "$merge_sha" > "$tmpdir/merge-sha"
    "$real_git" -C "$seed_dir" remote add origin "$remote_dir"
    "$real_git" -C "$seed_dir" push -q origin main >/dev/null 2>&1

    # ---- gh shim: now merge_sha is available for heredoc expansion ----
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version)
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
  pr)
    case "\$2" in
      list)
        # Duplicate-PR guard — empty
        exit 0
        ;;
      create)
        echo "https://github.com/x/y/pull/42"
        exit 0
        ;;
      view)
        # gh pr view --json state OR --json mergeable OR --json mergeCommit
        if [[ "\$*" == *"--json mergeCommit"* ]]; then
          # SHA baked in at fixture-build time (same pattern as _build_pr_success_fixture).
          # Runtime file reads proved unreliable on Linux CI (git 2.53.0).
          echo "$merge_sha"
          exit 0
        fi
        # mergeable check (pre-auto-merge) → MERGEABLE; state check during poll → see below
        if [[ "\$*" == *"--json mergeable"* && "\$*" != *state* ]]; then
          echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
          exit 0
        fi
        # state query during polling
        _iter=\$(wc -c < "$checks_counter" 2>/dev/null | tr -d ' ' || echo 0)
        # Use checks-counter byte count as the pollIter (incremented by pr checks calls)
        case "$mode" in
          success_after_2)
            if [[ "\$_iter" -ge 2 ]]; then
              echo '{"state":"MERGED"}'
            else
              echo '{"state":"OPEN"}'
            fi
            ;;
          success_after_3)
            if [[ "\$_iter" -ge 3 ]]; then
              echo '{"state":"MERGED"}'
            else
              echo '{"state":"OPEN"}'
            fi
            ;;
          check_failure|forever_pending)
            echo '{"state":"OPEN"}'
            ;;
        esac
        exit 0
        ;;
      checks)
        # Each call increments iteration counter (one byte per call)
        printf 'x' >> "$checks_counter"
        _iter=\$(wc -c < "$checks_counter" 2>/dev/null | tr -d ' ' || echo 0)
        case "$mode" in
          success_after_2)
            if [[ "\$_iter" -ge 2 ]]; then
              echo '[{"name":"ci","state":"COMPLETED","conclusion":"SUCCESS"}]'
            else
              echo '[{"name":"ci","state":"IN_PROGRESS","conclusion":""}]'
            fi
            ;;
          success_after_3)
            if [[ "\$_iter" -ge 3 ]]; then
              echo '[{"name":"ci","state":"COMPLETED","conclusion":"SUCCESS"}]'
            else
              echo '[{"name":"ci","state":"IN_PROGRESS","conclusion":""}]'
            fi
            ;;
          check_failure)
            echo '[{"name":"ci","state":"COMPLETED","conclusion":"FAILURE"}]'
            ;;
          forever_pending)
            echo '[{"name":"ci","state":"IN_PROGRESS","conclusion":""}]'
            ;;
        esac
        exit 0
        ;;
      merge)
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    # ---- git shim ----
    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  printf '%s\n' "\$*" >> "$git_push_log"
  exit 0
fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$bin/git"

    (
        cd "$tmpdir" || exit 1
        "$real_git" init -q -b main >/dev/null 2>&1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        "$real_git" remote add origin "$remote_dir"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        # Pre-fetch origin/main so the merge commit is already in refs/remotes/origin/main
        # before the script runs. This prevents a race where the script's git fetch call
        # (which uses the git shim's exec delegation) might not see the commit in CI.
        "$real_git" fetch -q origin main >/dev/null 2>&1 || true
        "$real_git" checkout -q -b "$branch"
        echo "feature" > feature.txt
        "$real_git" add feature.txt
        "$real_git" commit -q -m "feature work" >/dev/null
    )

    # Fixture invariant check: origin/main must contain the merge SHA.
    # This catches fixture-setup failures early rather than producing a confusing
    # downstream "not found" error from the script under test.
    if ! "$real_git" -C "$tmpdir" log origin/main --pretty=%H -n 50 2>/dev/null | grep -q "^${merge_sha}$"; then
        echo "FIXTURE_BUG: merge_sha $merge_sha not on origin/main in $tmpdir" >&2
        return 1
    fi

    # Per-test config override: zero-cadence polling
    local cfg="$tmpdir/dso-config.conf"
    cat > "$cfg" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF
}

# ---------------------------------------------------------------------------
# t_pr_poll_single_call_per_iteration
# Given polling that succeeds on iter 3; assert exactly 3 `gh pr checks` calls
# total: all 3 from _phase_poll (iters 1, 2, 3). _phase_resolve_threads settles
# immediately (threads=0 + quiet window elapsed via override) and makes zero
# `gh pr checks` calls — it only calls `gh pr view` and GraphQL.
# ---------------------------------------------------------------------------
t_pr_poll_single_call_per_iteration() {
    local _T branch _argv _checks_count
    _T="$(mktemp -d /tmp/dso-pr-poll-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-poll-once-per-iter"
    _build_pr_polling_fixture "$_T" "$branch" "success_after_3"

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true

    _argv="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"
    _checks_count=$(echo "$_argv" | grep -cE "^pr checks " || true)

    assert_eq "t_pr_poll_single_call_per_iteration_count" "3" "$_checks_count"
}
t_pr_poll_single_call_per_iteration

# ---------------------------------------------------------------------------
# t_pr_poll_succeeds_on_merged_state
# Given shim returns SUCCESS+MERGED on iter 2; expect exit 0.
# ---------------------------------------------------------------------------
t_pr_poll_succeeds_on_merged_state() {
    local _T branch _ec
    _T="$(mktemp -d /tmp/dso-pr-poll-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-poll-success"
    _build_pr_polling_fixture "$_T" "$branch" "success_after_2"

    local _stderr_file
    _stderr_file="$(mktemp /tmp/pr-poll-success-test.XXXXXX)"
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >/dev/null 2>"$_stderr_file"
    )
    _ec=$?
    if [[ "$_ec" -ne 0 ]]; then
        echo "  debug stderr: $(cat "$_stderr_file" 2>/dev/null | head -5)" >&2
    fi
    rm -f "$_stderr_file"

    assert_eq "t_pr_poll_succeeds_on_merged_state_exit_zero" "0" "$_ec"
}
t_pr_poll_succeeds_on_merged_state

# ---------------------------------------------------------------------------
# t_pr_poll_fails_on_check_failure
# Given shim returns FAILURE conclusion on iter 1; expect non-zero exit
# and PR URL in stderr.
# ---------------------------------------------------------------------------
t_pr_poll_fails_on_check_failure() {
    local _T branch _stderr _ec _has_url _exits_nonzero
    _T="$(mktemp -d /tmp/dso-pr-poll-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-poll-failure"
    _build_pr_polling_fixture "$_T" "$branch" "check_failure"

    _stderr="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" 2>&1 >/dev/null
    )"
    _ec=$?

    _exits_nonzero="false"
    [[ "$_ec" -ne 0 ]] && _exits_nonzero="true"

    _has_url="false"
    if echo "$_stderr" | grep -q "pull/42"; then
        _has_url="true"
    fi

    assert_eq "t_pr_poll_fails_on_check_failure_exits_nonzero" "true" "$_exits_nonzero"
    assert_eq "t_pr_poll_fails_on_check_failure_has_pr_url" "true" "$_has_url"
}
t_pr_poll_fails_on_check_failure

# ---------------------------------------------------------------------------
# t_pr_poll_timeout
# Given max_wait=1 and shim returns IN_PROGRESS forever; expect non-zero
# exit, "max-wait exceeded" message, and PR URL in stderr.
# ---------------------------------------------------------------------------
t_pr_poll_timeout() {
    local _T branch _stderr _ec _has_timeout _has_url _exits_nonzero _cfg
    _T="$(mktemp -d /tmp/dso-pr-poll-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-poll-timeout"
    _build_pr_polling_fixture "$_T" "$branch" "forever_pending"

    # Override max_wait to 1 second
    _cfg="$_T/dso-config.conf"
    cat > "$_cfg" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=1
EOF

    _stderr="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_cfg" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" 2>&1 >/dev/null
    )"
    _ec=$?

    _exits_nonzero="false"
    [[ "$_ec" -ne 0 ]] && _exits_nonzero="true"

    _has_timeout="false"
    if echo "$_stderr" | grep -q "max-wait exceeded"; then
        _has_timeout="true"
    fi

    _has_url="false"
    if echo "$_stderr" | grep -q "pull/42"; then
        _has_url="true"
    fi

    assert_eq "t_pr_poll_timeout_exits_nonzero" "true" "$_exits_nonzero"
    assert_eq "t_pr_poll_timeout_has_max_wait_message" "true" "$_has_timeout"
    assert_eq "t_pr_poll_timeout_has_pr_url" "true" "$_has_url"
}
t_pr_poll_timeout

# ===========================================================================
# Success-exit tests (Task 99f2-6aee — DD5)
# ===========================================================================
#
# After polling reports MERGED, the script must:
#   1. fetch origin main
#   2. retrieve the merge SHA via gh pr view --json mergeCommit
#   3. verify the SHA appears in git log origin/main
#   4. invoke _phase_version_bump → _phase_archive → _phase_ci_trigger
#   5. exit 0
#
# Failure mode: if the SHA is NOT on origin/main, exit non-zero with a
# "merge commit ... not found on origin/main" error.
#
# Fixture builder: _build_pr_success_fixture <tmpdir> <branch> <mode>
#   mode:
#     present  → origin/main contains the merge SHA → exit 0 expected
#     missing  → origin/main does NOT contain the SHA → exit non-zero expected

_build_pr_success_fixture() {
    local tmpdir="$1" branch="$2" mode="$3"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"

    local gh_argv_log="$tmpdir/gh-argv.log"

    # Set up a real git repo with an "origin" remote pointing at a bare repo.
    # The bare repo's main branch will (or will not) contain the merge SHA.
    local real_git
    real_git=$(command -v git)

    # 1. Bare "remote" repo
    local remote_dir="$tmpdir/remote.git"
    "$real_git" init -q --bare -b main "$remote_dir" >/dev/null 2>&1

    # 2. A scratch checkout used to seed the remote with the merge commit.
    #    The merge commit's SHA is the value the gh shim will return.
    local seed_dir="$tmpdir/seed"
    "$real_git" init -q -b main "$seed_dir" >/dev/null 2>&1
    (
        cd "$seed_dir" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        # Make a feature branch + merge it (no-ff) to produce a real merge commit
        "$real_git" checkout -q -b feat
        echo "feat" > feat.txt
        "$real_git" add feat.txt
        "$real_git" commit -q -m "feat" >/dev/null
        "$real_git" checkout -q main
        "$real_git" merge --no-ff -q feat -m "merge feat" >/dev/null
    )

    local merge_sha
    merge_sha=$("$real_git" -C "$seed_dir" rev-parse HEAD)
    echo "$merge_sha" > "$tmpdir/merge-sha"

    if [[ "$mode" == "present" ]]; then
        # Push the merge commit to the bare remote so origin/main contains it.
        "$real_git" -C "$seed_dir" remote add origin "$remote_dir"
        "$real_git" -C "$seed_dir" push -q origin main >/dev/null 2>&1
    else
        # mode=missing → seed remote with a single unrelated commit so origin/main
        # exists but does NOT contain the merge SHA. Use a separate seed.
        local missing_seed="$tmpdir/missing-seed"
        "$real_git" init -q -b main "$missing_seed" >/dev/null 2>&1
        (
            cd "$missing_seed" || exit 1
            "$real_git" config user.email "test@test.local"
            "$real_git" config user.name "test"
            echo "other" > other.txt
            "$real_git" add other.txt
            "$real_git" commit -q -m "other" >/dev/null
        )
        "$real_git" -C "$missing_seed" remote add origin "$remote_dir"
        "$real_git" -C "$missing_seed" push -q origin main >/dev/null 2>&1
    fi

    # 3. The actual working repo where merge-to-main-pr.sh will run.
    #    Has the same remote configured so `git fetch origin main` works.
    (
        cd "$tmpdir" || exit 1
        "$real_git" init -q -b main >/dev/null 2>&1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        "$real_git" remote add origin "$remote_dir"
        echo "local-seed" > local-seed.txt
        "$real_git" add local-seed.txt
        "$real_git" commit -q -m "local-seed" >/dev/null
        # Pre-fetch to populate refs/remotes/origin/main before the script runs.
        "$real_git" fetch -q origin main >/dev/null 2>&1 || true
        "$real_git" checkout -q -b "$branch"
        echo "feature" > feature.txt
        "$real_git" add feature.txt
        "$real_git" commit -q -m "feature work" >/dev/null
    )

    # ---- gh shim: returns merge_sha for `gh pr view --json mergeCommit` ----
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version)
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
  pr)
    case "\$2" in
      list) exit 0 ;;
      create)
        echo "https://github.com/x/y/pull/42"
        exit 0
        ;;
      view)
        if [[ "\$*" == *"--json mergeCommit"* ]]; then
          echo "$merge_sha"
          exit 0
        fi
        if [[ "\$*" == *"--json state"* ]]; then
          echo "MERGED"
          exit 0
        fi
        echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0
        ;;
      checks)
        echo '[{"name":"ci","state":"COMPLETED","conclusion":"SUCCESS"}]'
        exit 0
        ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  workflow) exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    # ---- git shim: pass-through except `git push` (no real push to remote) ----
    # Note: we DO want `git fetch` to work (so origin/main is populated locally).
    # Push would be triggered by _phase_merge — but in PR mode the publish-branch
    # push targets origin/<branch>, not origin/main, and we don't want it to run.
    # For success-path tests, the publish push is a no-op (the bare remote will
    # accept it just fine), but skipping is safer for isolation.
    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  exit 0
fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$bin/git"

    # Per-test config: zero-cadence polling, no version_file_path so the
    # version_bump phase becomes a no-op (DD5 covers exit-zero / lifecycle
    # invocation, not version-bump correctness).
    cat > "$tmpdir/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF
}

# ---------------------------------------------------------------------------
# t_pr_success_exits_zero
# Given origin/main contains the merge SHA, when pr.sh runs, it exits 0
# and the state file shows ci_trigger phase complete.
# ---------------------------------------------------------------------------
t_pr_success_exits_zero() {
    local _T branch _ec _branch_safe _state_file _ci_trigger_complete
    _T="$(mktemp -d /tmp/dso-pr-success-test.XXXXXX)"
    branch="feature-success-exit"
    _branch_safe="${branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    _build_pr_success_fixture "$_T" "$branch" "present"

    # Capture state file path BEFORE running pr.sh, since the script may
    # remove the state file on success (mirroring direct.sh tail behavior).
    # We assert on a captured snapshot instead of post-run readback.
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >"$_T/out.log" 2>&1
    )
    _ec=$?

    # The success-path tail removes the state file on exit 0. To verify
    # ci_trigger completion, check the captured stdout/stderr for the DONE
    # message AND for the "INFO: Merge commit ... verified" line.
    _ci_trigger_complete="false"
    if grep -q "DONE:" "$_T/out.log" 2>/dev/null; then
        _ci_trigger_complete="true"
    fi

    local _verified="false"
    if grep -qE "Merge commit [0-9a-f]+ verified on origin/main" "$_T/out.log"; then
        _verified="true"
    fi

    assert_eq "t_pr_success_exits_zero_exit_zero" "0" "$_ec"
    assert_eq "t_pr_success_exits_zero_done_message" "true" "$_ci_trigger_complete"
    assert_eq "t_pr_success_exits_zero_sha_verified" "true" "$_verified"
}
t_pr_success_exits_zero

# ---------------------------------------------------------------------------
# t_pr_success_missing_merge_sha
# Given gh reports merged but origin/main does NOT contain the merge SHA,
# pr.sh must exit non-zero with a "merge commit <sha> not found on
# origin/main" error in stderr.
# ---------------------------------------------------------------------------
t_pr_success_missing_merge_sha() {
    local _T branch _ec _branch_safe _state_file _stderr _has_error
    _T="$(mktemp -d /tmp/dso-pr-success-test.XXXXXX)"
    branch="feature-missing-merge-sha"
    _branch_safe="${branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    _build_pr_success_fixture "$_T" "$branch" "missing"

    _stderr="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" 2>&1 >/dev/null
    )"
    _ec=$?

    local _exits_nonzero="false"
    [[ "$_ec" -ne 0 ]] && _exits_nonzero="true"

    _has_error="false"
    if echo "$_stderr" | grep -qE "merge commit [0-9a-f]+ not found on origin/main"; then
        _has_error="true"
    fi

    assert_eq "t_pr_success_missing_merge_sha_exits_nonzero" "true" "$_exits_nonzero"
    assert_eq "t_pr_success_missing_merge_sha_has_error_message" "true" "$_has_error"
}
t_pr_success_missing_merge_sha

# ===========================================================================
# Tests for per-thread failure logging in _phase_resolve_threads
# (bug 1920-c513-cf59-4417: batch `|| true` -> per-thread failures swallowed)
# ===========================================================================
#
# Strategy: source merge-to-main-pr.sh in library mode (PR_LIB_MODE=1) to get
# function definitions only, then call _phase_resolve_threads directly with
# stub helpers that simulate a successful commit+push but a failing
# _pr_resolve_thread. Assert that WARN messages are emitted on stderr.

# ---------------------------------------------------------------------------
# t_per_thread_resolve_failure_emits_warn
# When _pr_resolve_thread fails for a code_change thread (after commit+push
# succeed), _phase_resolve_threads MUST emit a WARN message containing the
# thread ID and the exit code on stderr. The || true pattern that previously
# swallowed this failure silently is the defect under test.
# ---------------------------------------------------------------------------
t_per_thread_resolve_failure_emits_warn() {
    local _T branch _stderr _rc
    _T="$(mktemp -d /tmp/dso-pr-thread-warn-test.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-resolve-fail-warn"
    _build_pr_fixture "$_T" "$branch" "ok" "ok"

    # Build an LLM stub that emits ACTION:code_change.
    # The code_change path exercises commit+push+resolve. We want to verify
    # that when _pr_resolve_thread exits non-zero a WARN is emitted.
    local llm_stub="$_T/llm-stub.sh"
    cat > "$llm_stub" <<'LLM_EOF'
#!/usr/bin/env bash
echo "ACTION:code_change"
exit 0
LLM_EOF
    chmod +x "$llm_stub"

    # Override the git stub created by _build_pr_fixture to also intercept
    # `git [-C <dir>] commit` (the push is already handled). The -C flag
    # requires stripping two args (the flag itself and its directory arg)
    # to reveal the actual subcommand.
    local real_git
    real_git=$(command -v git)
    local git_stub="$_T/bin/git"
    cat > "$git_stub" <<GIT_EOF
#!/usr/bin/env bash
# Strip leading -C <dir> pairs so we can match the actual subcommand.
_args=("\$@")
_idx=0
while [[ "\${_idx}" -lt "\${#_args[@]}" && "\${_args[\$_idx]}" == "-C" ]]; do
    _idx=\$(( _idx + 2 ))
done
_subcmd="\${_args[\$_idx]:-}"
if [[ "\$_subcmd" == "commit" || "\$_subcmd" == "push" ]]; then
    exit 0
fi
exec "$real_git" "\$@"
GIT_EOF
    chmod +x "$git_stub"

    # NOTE: Use PR_SCRIPT (the worktree-local file path) explicitly as the
    # source argument. Do NOT use "$CLAUDE_PLUGIN_ROOT/..." here because
    # CLAUDE_PLUGIN_ROOT may be set in the caller's environment to a different
    # installation (e.g. the main repo). The PR_SCRIPT variable is set at the
    # top of this test file to the repo-local path, ensuring the worktree's
    # patched version is always sourced.
    _stderr="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        CI="true" \
        PR_LIB_MODE="1" \
        _LLM_DISPATCH_CMD="$llm_stub" \
        PR_THREAD_LOOP_INTERVAL="0" \
        PR_THREAD_LOOP_MAX_DISPATCHES="1" \
        PR_THREAD_LOOP_MAX_WALL_SECONDS="99999" \
        bash -c '
            source "$0" >/dev/null 2>&1
            # Override helpers:
            # _pr_fetch_unresolved_threads — returns one unresolved thread
            # _pr_settling_check          — always unsettled (forces dispatch loop)
            # _pr_resolve_thread          — always exits non-zero (simulates GraphQL error)
            # _pr_post_thread_reply       — always succeeds
            _pr_fetch_unresolved_threads() {
                printf "T_FAIL\tsrc/foo.py\t1\tC_001\t"
            }
            _pr_settling_check() {
                return 1
            }
            _pr_resolve_thread() {
                return 42
            }
            _pr_post_thread_reply() {
                return 0
            }
            _phase_resolve_threads 99 "https://github.com/x/y/pull/99" 2>&1 >/dev/null
        ' "$PR_SCRIPT"
    )" || true

    local _has_warn="false"
    if echo "$_stderr" | grep -qiE "WARN.*T_FAIL|T_FAIL.*WARN|WARN.*thread.*T_FAIL|thread.*T_FAIL.*failed"; then
        _has_warn="true"
    fi

    assert_eq "t_per_thread_resolve_failure_emits_warn: WARN emitted for failed resolve" "true" "$_has_warn"
}
t_per_thread_resolve_failure_emits_warn

# ---------------------------------------------------------------------------
print_summary
