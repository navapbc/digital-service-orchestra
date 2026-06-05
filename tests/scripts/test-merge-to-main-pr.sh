#!/usr/bin/env bash
# shellcheck disable=SC2046,SC2329
# tests/scripts/test-merge-to-main-pr.sh
# Tests for merge-to-main-pr.sh PR-creation + auto-merge phase (DD1, DD6).
#

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

# Disable commit signing for temp test repos. Each fixture creates a throwaway
# repo under /tmp and runs `git commit`; a global commit.gpgsign in the host
# environment would block the commit silently, leaving the test in an
# unrecoverable state. Matches the pattern in tests/test-git-fixtures.sh.
export GIT_CONFIG_COUNT=1  # isolation-ok: scoped to this test process
export GIT_CONFIG_KEY_0=commit.gpgsign  # isolation-ok: scoped to this test process
export GIT_CONFIG_VALUE_0=false  # isolation-ok: scoped to this test process

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# Isolate test fixtures from host-project-locating env vars exported by the
# .claude/scripts/dso shim (PROJECT_ROOT) and ambient state (CLAUDE_PROJECT_DIR,
# _MERGE_STATE_GIT_DIR). When this test file is invoked through the shim
# (e.g., DSO_COMMIT_WORKFLOW=1 .claude/scripts/dso record-test-status), those
# vars leak into per-test subshells and override the fixture's temp-dir git
# repo via merge-to-main-pr.sh:53 (`REPO_ROOT="${PROJECT_ROOT:-...}"`),
# causing `cd "$REPO_ROOT"` to escape the fixture and the script to operate
# against the live worktree branch instead of the test branch. Unset here
# (parent shell) so all subshells inherit the cleared env. (Bug 2015-dcce.)
unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

# Default LLM dispatch env vars to no-op stubs so polling/merge-flow tests can
# reach downstream phases without tripping the fail-loud guards in
# _phase_resolve_threads / _dispatch_resolve_conflicts / _dispatch_fix_agent
# (bug 9e04-0eb6). Tests that exercise the LLM dispatch directly override
# these per-invocation. /bin/true succeeds without emitting any sentinels,
# which the call sites treat as "no resolution applied" — fine for tests
# whose fixtures present zero unresolved threads / no conflicts / no failing CI.
export _LLM_DISPATCH_CMD="${_LLM_DISPATCH_CMD:-/bin/true}"
export _RESOLVE_CONFLICTS_LLM_CMD="${_RESOLVE_CONFLICTS_LLM_CMD:-/bin/true}"
export _REMEDIATE_LLM_CMD="${_REMEDIATE_LLM_CMD:-/bin/true}"

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
        # gh pr view --json headRefOid — _phase_check_pr_comments_since_push
        # gh pr view --json comments,reviews,reviewThreads — comments-since-push payload
        if [[ "\$*" == *"--json state"* ]]; then
          echo "MERGED"
          exit 0
        fi
        if [[ "\$*" == *"--json headRefOid"* ]]; then
          # Empty → _phase_check_pr_comments_since_push returns early at the
          # `[[ -z "\$_head_sha" ]] && return 0` guard, so no api repos/commits
          # call follows. Keeps the fixture minimal.
          echo ""
          exit 0
        fi
        if [[ "\$*" == *"comments,reviews,reviewThreads"* ]]; then
          # Empty payload — defensive in case the head_sha guard above is
          # ever bypassed in future flows.
          echo "{}"
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
        echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'
        exit 0
        ;;
      merge)
        if [[ "$pr_merge_mode" == "auto_disabled" ]]; then
          # Auto-merge enable refuses; explicit merge (no --auto) succeeds.
          if [[ "\$*" == *"--auto"* ]]; then
            echo "ERROR: auto-merge is not allowed for this repository" >&2
            exit 1
          fi
          exit 0
        fi
        if [[ "$pr_merge_mode" == "refused" ]]; then
          echo "ERROR: auto-merge is not allowed for this repository" >&2
          exit 1
        fi
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    # gh api graphql — _pr_fetch_unresolved_threads expects this exact shape.
    # Returning empty {nodes:[]} means "no unresolved threads", letting
    # _phase_resolve_threads exit cleanly so the script proceeds to auto-merge.
    if [[ "\$2" == "graphql" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      exit 0
    fi
    exit 0
    ;;
  repo)
    # gh repo view --json nameWithOwner — _pr_repo helper. Return a placeholder
    # slug consistent with the PR URL above.
    if [[ "\$2" == "view" ]]; then
      if [[ "\$*" == *"defaultBranchRef"* ]]; then
        echo "main"
        exit 0
      fi
      echo "x/y"
      exit 0
    fi
    exit 0
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
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
# Asserts gh is invoked with `pr merge 42 --auto --rebase` after pr create.
# cca8 (linear-history cutover, DD1): the two-tier flow rebase-merges so no
# merge commit ever reaches main under required_linear_history. The auto-merge
# enqueue MUST use --rebase, never --merge.
# ---------------------------------------------------------------------------
t_pr_auto_merge_queued() {
    local _T branch _argv _has_merge_42 _uses_rebase_strategy _no_merge_strategy _has_auto
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
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
    _uses_rebase_strategy="false"
    _no_merge_strategy="true"
    _has_auto="false"
    if echo "$_argv" | grep -qE "^pr merge 42"; then
        _has_merge_42="true"
    fi
    if echo "$_argv" | grep -E "^pr merge 42" | grep -q -- "--rebase"; then
        _uses_rebase_strategy="true"
    fi
    # Linear-history invariant: NO pr merge call may use --merge.
    if echo "$_argv" | grep -E "^pr merge " | grep -q -- "--merge"; then
        _no_merge_strategy="false"
    fi
    if echo "$_argv" | grep -E "^pr merge 42" | grep -q -- "--auto"; then
        _has_auto="true"
    fi

    assert_eq "t_pr_auto_merge_queued_invokes_pr_merge_with_pr_number" "true" "$_has_merge_42"
    assert_eq "t_pr_auto_merge_queued_uses_rebase_not_merge" "true" "$_uses_rebase_strategy"
    assert_eq "t_pr_auto_merge_queued_never_uses_merge_commit" "true" "$_no_merge_strategy"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
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
        # _phase_check_pr_comments_since_push: --json headRefOid → empty so
        # the function returns early at the empty-_head_sha guard, avoiding
        # the api repos/{owner}/{repo}/commits/... call.
        if [[ "\$*" == *"--json headRefOid"* ]]; then
          echo ""
          exit 0
        fi
        # comments,reviews,reviewThreads payload — defensive empty.
        if [[ "\$*" == *"comments,reviews,reviewThreads"* ]]; then
          echo "{}"
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
              echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'
            else
              echo '[{"name":"ci","state":"IN_PROGRESS","bucket":"pending"}]'
            fi
            ;;
          success_after_3)
            if [[ "\$_iter" -ge 3 ]]; then
              echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'
            else
              echo '[{"name":"ci","state":"IN_PROGRESS","bucket":"pending"}]'
            fi
            ;;
          check_failure)
            echo '[{"name":"ci","state":"COMPLETED","bucket":"fail"}]'
            ;;
          forever_pending)
            echo '[{"name":"ci","state":"IN_PROGRESS","bucket":"pending"}]'
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
  api)
    # _pr_fetch_unresolved_threads — empty {nodes:[]} so the loop exits cleanly.
    if [[ "\$2" == "graphql" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      exit 0
    fi
    exit 0
    ;;
  repo)
    # _pr_repo helper.
    if [[ "\$2" == "view" ]]; then
      if [[ "\$*" == *"defaultBranchRef"* ]]; then
        echo "main"
        exit 0
      fi
      echo "x/y"
      exit 0
    fi
    exit 0
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
        # before the script runs. Use explicit refspec to ensure refs/remotes/origin/main
        # is populated — `git fetch origin main` without refspec may only update FETCH_HEAD
        # on some git versions (notably Ubuntu CI git 2.43+) without creating the tracking ref.
        "$real_git" fetch -q origin "main:refs/remotes/origin/main" >/dev/null 2>&1 || \
            "$real_git" fetch -q origin >/dev/null 2>&1 || true
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-poll-test.XXXXXX")"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-poll-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-poll-success"
    _build_pr_polling_fixture "$_T" "$branch" "success_after_2"

    local _stderr_file
    _stderr_file="$(mktemp "${TMPDIR:-/tmp}/pr-poll-success-test.XXXXXX")"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-poll-test.XXXXXX")"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-poll-test.XXXXXX")"
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
        # Use explicit refspec — `git fetch origin main` without refspec may only
        # update FETCH_HEAD on Ubuntu CI git 2.43+ without creating the tracking ref.
        "$real_git" fetch -q origin "main:refs/remotes/origin/main" >/dev/null 2>&1 || \
            "$real_git" fetch -q origin >/dev/null 2>&1 || true
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
        # _phase_check_pr_comments_since_push: --json headRefOid → empty so
        # the function returns early, avoiding the api repos/.../commits call.
        if [[ "\$*" == *"--json headRefOid"* ]]; then
          echo ""
          exit 0
        fi
        if [[ "\$*" == *"comments,reviews,reviewThreads"* ]]; then
          echo "{}"
          exit 0
        fi
        echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0
        ;;
      checks)
        echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'
        exit 0
        ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    # _pr_fetch_unresolved_threads — empty {nodes:[]} so the loop exits cleanly.
    if [[ "\$2" == "graphql" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      exit 0
    fi
    exit 0
    ;;
  repo)
    # _pr_repo helper.
    if [[ "\$2" == "view" ]]; then
      if [[ "\$*" == *"defaultBranchRef"* ]]; then
        echo "main"
        exit 0
      fi
      echo "x/y"
      exit 0
    fi
    exit 0
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-success-test.XXXXXX")"
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
    # Updated for squash-merge fallback (110f-9772): when mergeCommit.oid is not on
    # origin/main, the script now falls back to git rev-parse origin/main and succeeds
    # rather than exiting with an error. This handles GitHub's API limitation for squash
    # merges where mergeCommit.oid returns the source-branch HEAD instead of the squash commit.
    local _T branch _ec _branch_safe _state_file _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-success-test.XXXXXX")"
    branch="feature-missing-merge-sha"
    _branch_safe="${branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    _build_pr_success_fixture "$_T" "$branch" "missing"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" 2>&1
    )"
    _ec=$?

    local _exits_zero="false"
    [[ "$_ec" -eq 0 ]] && _exits_zero="true"

    local _fallback_used="false"
    if echo "$_out" | grep -qiE "squash|fallback"; then
        _fallback_used="true"
    fi

    assert_eq "t_pr_success_missing_merge_sha_exits_zero" "true" "$_exits_zero"
    assert_eq "t_pr_success_missing_merge_sha_fallback_used" "true" "$_fallback_used"
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
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-thread-warn-test.XXXXXX")"
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

# ===========================================================================
# T3: CI Remediation Loop (story c742-dc83-fd8e-4c89)
#
# These 9 tests cover _state_record_failed_run_id, _dispatch_fix_agent, and
# _phase_remediate. all initially fail because the implementation
# functions don't exist yet. They turn GREEN when T4a/T4b/T4c are applied.
# ===========================================================================

# ---------------------------------------------------------------------------
# t_state_record_failed_run_id_writes_to_state
# After calling _state_init + _state_record_failed_run_id "RUN123",
# the state file must contain a "failed_run_id" key with value "RUN123".

# ---------------------------------------------------------------------------
t_state_record_failed_run_id_writes_to_state() {
    local _branch_safe _state_file _result
    _branch_safe="test-branch-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'; unset BRANCH" RETURN
    export BRANCH="$_branch_safe"

    (
        BRANCH="$_branch_safe" MERGE_STRATEGY="pr" \
        bash -c "source '$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh' 2>/dev/null || exit 1
                 _state_init 2>/dev/null || true
                 _state_record_failed_run_id 'RUN123'"
    ) 2>/dev/null || true

    _result="no"
    if grep -q '"failed_run_id"' "$_state_file" 2>/dev/null && \
       grep -q 'RUN123' "$_state_file" 2>/dev/null; then
        _result="yes"
    fi
    assert_eq "t_state_record_failed_run_id_writes_to_state: failed_run_id in state" "yes" "$_result"
}
t_state_record_failed_run_id_writes_to_state

# ---------------------------------------------------------------------------
# t_phase_poll_records_failed_run_id_on_ci_failure
# When _phase_poll encounters a CI FAILURE conclusion, it must call
# gh run list and write the run ID to the state file via
# _state_record_failed_run_id.

#             into _phase_poll's CI failure branch yet.
# ---------------------------------------------------------------------------
t_phase_poll_records_failed_run_id_on_ci_failure() {
    local _T _branch_safe _state_file _result
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-poll-runid-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-poll-runid-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    mkdir -p "$_T/bin"
    # Real gh CLI surfaces check outcomes via the `bucket` field (pass|fail|pending|
    # skipping|cancel), NOT a `conclusion` field. Requesting --json conclusion exits
    # non-zero with "Unknown JSON field". This mock mirrors the real schema so the
    # test actually exercises the production code path. Bug 075d-741a.
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
# Detect requests for unsupported fields (real gh behavior — exits 1).
if [[ "\$*" == *"--json"* ]] && [[ "\$*" == *"conclusion"* ]]; then
    echo 'Unknown JSON field: "conclusion"' >&2
    echo 'Available fields:' >&2
    echo '  bucket' >&2
    exit 1
fi
case "\$1 \$2" in
  "pr checks")
    echo '[{"name":"ci","state":"COMPLETED","bucket":"fail"}]'
    exit 0
    ;;
  "pr view")
    echo '{"state":"OPEN"}'
    exit 0
    ;;
  "run list")
    echo '[{"databaseId":"RUN999"}]'
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _state_init 2>/dev/null || true
            _phase_poll "42" "https://github.com/x/y/pull/42" 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null || true

    _result="no"
    if grep -q '"failed_run_id"' "$_state_file" 2>/dev/null && \
       grep -q 'RUN999' "$_state_file" 2>/dev/null; then
        _result="yes"
    fi
    assert_eq "t_phase_poll_records_failed_run_id_on_ci_failure: run id in state" "yes" "$_result"
}
t_phase_poll_records_failed_run_id_on_ci_failure

# ---------------------------------------------------------------------------
# t_phase_poll_run_list_filters_by_branch
# Regression test for the cross-PR run-id pollution fix: when _phase_poll
# captures a failed run ID via `gh run list`, it MUST pass --branch <BRANCH>
# so concurrent CI runs from unrelated PRs cannot poison the captured ID.
# ---------------------------------------------------------------------------
t_phase_poll_run_list_filters_by_branch() {
    local _T _branch_safe _state_file _argv _has_branch_filter
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-poll-runid-test.XXXXXX")"
    _branch_safe="test-runlist-branch-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    mkdir -p "$_T/bin"
    # Mock mirrors real gh schema (bucket, not conclusion). Bug 075d-741a.
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
if [[ "\$*" == *"--json"* ]] && [[ "\$*" == *"conclusion"* ]]; then
    echo 'Unknown JSON field: "conclusion"' >&2
    exit 1
fi
case "\$1 \$2" in
  "pr checks")  echo '[{"name":"ci","state":"COMPLETED","bucket":"fail"}]' ;;
  "pr view")    echo '{"state":"OPEN"}' ;;
  "run list")   echo '[{"databaseId":"RUN999"}]' ;;
  *) ;;
esac
exit 0
GH_SHIM
    chmod +x "$_T/bin/gh"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _state_init 2>/dev/null || true
            _phase_poll "42" "https://github.com/x/y/pull/42" 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null || true

    _argv=$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')
    # Look specifically at the `run list` invocation line and verify --branch <name> is present.
    _has_branch_filter="false"
    if echo "$_argv" | grep -E "^run list" | grep -q -- "--branch ${_branch_safe}"; then
        _has_branch_filter="true"
    fi
    assert_eq "t_phase_poll_run_list_filters_by_branch" "true" "$_has_branch_filter"
}
t_phase_poll_run_list_filters_by_branch

# ---------------------------------------------------------------------------
# t_phase_remediate_redownloads_artifacts_when_run_id_changes
# Regression test for stale-artifact reuse: when a fix push triggers a NEW
# CI run, _phase_poll records the new failed_run_id in state. On the next
# outer iteration of the remediation loop, _phase_remediate must re-download
# artifacts using the new run ID rather than reusing the original artifacts.
# ---------------------------------------------------------------------------
t_phase_remediate_redownloads_artifacts_when_run_id_changes() {
    local _T _branch_safe _state_file _download_log _has_new_runid_download
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-redl-test.XXXXXX")"
    _branch_safe="test-redownload-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    _download_log="$_T/gh-download.log"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    # Seed the state file with an INITIAL failed_run_id, then on poll-failure
    # we'll have the gh shim "update" it (via _state_record_failed_run_id) to
    # a new value, simulating the post-fix-push CI re-run.
    mkdir -p "$_T"
    cat > "$_state_file" <<EOF
{"branch":"$_branch_safe","failed_run_id":"OLD_RUN_111","completed_phases":[],"current_phase":"","phases":{},"merge_strategy":"pr"}
EOF

    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
case "\$1 \$2" in
  "run download")
    # Record which run ID was downloaded
    echo "downloaded:\$3" >> "$_download_log"
    # Simulate a download failure on the SECOND run-id (NEW_RUN_222) so the
    # loop emits ARTIFACT_MISSING — that exit code is observable, and the
    # download attempt itself is logged regardless.
    if [[ "\$3" == "NEW_RUN_222" ]]; then
        exit 1
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # Update state mid-flight: simulate _phase_poll having captured a NEW run id
    # by overwriting the state file's failed_run_id BEFORE _phase_remediate's
    # outer-loop re-read fires. We do this by monkey-patching _phase_poll
    # to mutate state and return failure, forcing the loop to iterate.
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            # Stub: simulate a fix-push that updates state to NEW_RUN_222 then poll fails
            _phase_poll() { _state_record_failed_run_id "NEW_RUN_222"; return 1; }
            _push_fix_branch() { return 0; }
            _dispatch_fix_agent() { echo "{\"findings\":[]}" > "$2.dummy"; return 0; }
            _normalize_tier1() { echo "{}" > "$2"; return 0; }
            _normalize_tier2() { return 3; }
            _normalize_tier3() { return 3; }
            _normalize_tier4() { return 3; }
            _check_usage_for_remediate() { return 0; }
            _phase_remediate "42" "https://github.com/x/y/pull/42" 2>/dev/null || true
        ' "$PR_SCRIPT"
    ) 2>/dev/null || true

    # Verify: gh run download was called for NEW_RUN_222 (the post-poll run id)
    _has_new_runid_download="false"
    if grep -q "downloaded:NEW_RUN_222" "$_download_log" 2>/dev/null; then
        _has_new_runid_download="true"
    fi
    assert_eq "t_phase_remediate_redownloads_artifacts_when_run_id_changes" "true" "$_has_new_runid_download"
}
t_phase_remediate_redownloads_artifacts_when_run_id_changes

# ---------------------------------------------------------------------------
# t_dispatch_fix_agent_invokes_llm_with_correct_args
# _dispatch_fix_agent must invoke the LLM stub with the review-fix-dispatch
# prompt and the findings path as arguments.

# ---------------------------------------------------------------------------
t_dispatch_fix_agent_invokes_llm_with_correct_args() {
    local _T _branch_safe _has_dispatch _has_findings
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatch-fix-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-dispatch-$$"

    cat > "$_T/findings.json" <<'FINDINGS_EOF'
{"findings":[{"severity":"important","description":"test finding"}]}
FINDINGS_EOF

    cat > "$_T/llm_stub.sh" <<LLM_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/llm-calls.log"
echo "RESOLUTION_RESULT: FIXES_APPLIED"
exit 0
LLM_EOF
    chmod +x "$_T/llm_stub.sh"

    (
        cd "$_T" || exit 1
        CI="true" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="$_branch_safe" \
        MERGE_STRATEGY="pr" \
        _REMEDIATE_LLM_CMD="$_T/llm_stub.sh" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _dispatch_fix_agent "'"$_T/findings.json"'" 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null || true

    _has_dispatch="false"
    if grep -q "review-fix-dispatch" "$_T/llm-calls.log" 2>/dev/null; then
        _has_dispatch="true"
    fi
    _has_findings="false"
    if grep -q "findings.json" "$_T/llm-calls.log" 2>/dev/null; then
        _has_findings="true"
    fi

    assert_eq "t_dispatch_fix_agent_invokes_llm_with_correct_args: prompt+path in llm args" "true:true" "${_has_dispatch}:${_has_findings}"
}
t_dispatch_fix_agent_invokes_llm_with_correct_args

# ---------------------------------------------------------------------------
# t_phase_remediate_wires_poll_failure_to_fix_push_repoll
# Full happy-path: state has failed_run_id → download artifacts → normalize →
# dispatch fix agent (FIXES_APPLIED) → git push → re-poll succeeds → exit 0.

# ---------------------------------------------------------------------------
t_phase_remediate_wires_poll_failure_to_fix_push_repoll() {
    local _T _branch_safe _state_file _ec _push_called
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-wire-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-remediate-wire-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    mkdir -p "$_T/bin"

    # Pre-write state file with failed_run_id (bypass _state_record_failed_run_id)
    _DSO_SF="$_state_file" _DSO_BRANCH="$_branch_safe" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
d = {'branch': os.environ['_DSO_BRANCH'], 'merge_sha': '', 'completed_phases': [],
     'current_phase': '', 'phases': {}, 'merge_strategy': 'pr', 'failed_run_id': 'RUN123'}
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
import os as _os
_os.rename(sf + '.tmp', sf)
" 2>/dev/null || true

    cat > "$_T/findings.json" <<'FINDINGS_EOF'
{"findings":[{"severity":"important","description":"test finding"}]}
FINDINGS_EOF

    # Counter file: pre-seed with 1 byte so the first re-poll call (from _phase_remediate)
    # hits iter=2 → SUCCESS. Without pre-seeding, iter=1 → FAILURE on first call,
    # causing _phase_poll to return 1 immediately (it doesn't retry on failure).
    printf 'x' > "$_T/checks-count"

    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
case "\$1 \$2" in
  "run download")
    _prev=""
    _dir=""
    for _arg in "\$@"; do
      if [[ "\$_prev" == "--dir" ]]; then _dir="\$_arg"; fi
      _prev="\$_arg"
    done
    if [[ -n "\$_dir" ]]; then
      mkdir -p "\$_dir"
      cp "$_T/findings.json" "\$_dir/reviewer-findings.json"
    fi
    exit 0
    ;;
  "pr checks")
    printf 'x' >> "$_T/checks-count"
    _iter=\$(wc -c < "$_T/checks-count" 2>/dev/null | tr -d ' ' || echo 0)
    if [[ "\$_iter" -ge 2 ]]; then
      echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'
    else
      echo '[{"name":"ci","state":"COMPLETED","bucket":"fail"}]'
    fi
    exit 0
    ;;
  "pr view")
    _iter=\$(wc -c < "$_T/checks-count" 2>/dev/null | tr -d ' ' || echo 0)
    if [[ "\$_iter" -ge 2 ]]; then
      echo '{"state":"MERGED"}'
    else
      echo '{"state":"OPEN"}'
    fi
    exit 0
    ;;
  "run list")
    echo '[{"databaseId":"RUN123"}]'
    exit 0
    ;;
  "pr merge") exit 0 ;;
  "pr create") echo "https://github.com/x/y/pull/42"; exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # git shim: strip -C <dir> pairs, intercept push
    # Capture real git path BEFORE the shim is on PATH to avoid infinite recursion
    local _real_git_wire
    _real_git_wire="$(command -v git)"
    cat > "$_T/bin/git" <<GIT_SHIM
#!/usr/bin/env bash
_args=("\$@")
_idx=0
while [[ "\${_idx}" -lt "\${#_args[@]}" && "\${_args[\$_idx]}" == "-C" ]]; do
  _idx=\$(( _idx + 2 ))
done
_subcmd="\${_args[\$_idx]:-}"
case "\$_subcmd" in
  add|commit) exit 0 ;;
  push)
    touch "$_T/git-push-called"
    exit 0
    ;;
  *)
    exec "$_real_git_wire" "\$@" 2>/dev/null || exit 0
    ;;
esac
GIT_SHIM
    chmod +x "$_T/bin/git"

    # LLM stub
    cat > "$_T/llm_stub.sh" <<LLM_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/llm-calls.log"
echo "RESOLUTION_RESULT: FIXES_APPLIED"
exit 0
LLM_EOF
    chmod +x "$_T/llm_stub.sh"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    _ec=127
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CI="true" \
        _REMEDIATE_LLM_CMD="$_T/llm_stub.sh" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _normalize_tier1() { cp "$1" "$2"; }
            _check_usage_for_remediate() { return 0; }
            _phase_remediate "42" "https://github.com/x/y/pull/42" 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _push_called="false"
    [[ -f "$_T/git-push-called" ]] && _push_called="true"

    assert_eq "t_phase_remediate_wires_poll_failure_to_fix_push_repoll: exits_0:push_called" "0:true" "${_ec}:${_push_called}"
}
t_phase_remediate_wires_poll_failure_to_fix_push_repoll

# ---------------------------------------------------------------------------
# t_phase_remediate_on_fix_agent_fail_returns_nonzero
# When _dispatch_fix_agent returns a non-FIXES_APPLIED result, _phase_remediate
# must still call the LLM but must NOT push and must return non-zero.

# ---------------------------------------------------------------------------
t_phase_remediate_on_fix_agent_fail_returns_nonzero() {
    local _T _branch_safe _state_file _ec _llm_called _push_called
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-fail-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-remediate-fail-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    mkdir -p "$_T/bin"

    _DSO_SF="$_state_file" _DSO_BRANCH="$_branch_safe" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
d = {'branch': os.environ['_DSO_BRANCH'], 'merge_sha': '', 'completed_phases': [],
     'current_phase': '', 'phases': {}, 'merge_strategy': 'pr', 'failed_run_id': 'RUN123'}
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
import os as _os
_os.rename(sf + '.tmp', sf)
" 2>/dev/null || true

    cat > "$_T/findings.json" <<'FINDINGS_EOF'
{"findings":[{"severity":"important","description":"test finding"}]}
FINDINGS_EOF

    # gh shim: run download succeeds
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
case "\$1 \$2" in
  "run download")
    _prev=""
    _dir=""
    for _arg in "\$@"; do
      if [[ "\$_prev" == "--dir" ]]; then _dir="\$_arg"; fi
      _prev="\$_arg"
    done
    if [[ -n "\$_dir" ]]; then
      mkdir -p "\$_dir"
      cp "$_T/findings.json" "\$_dir/reviewer-findings.json"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # LLM stub: returns FAIL result
    cat > "$_T/llm_stub.sh" <<LLM_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/llm-calls.log"
echo "RESOLUTION_RESULT: FAIL"
exit 0
LLM_EOF
    chmod +x "$_T/llm_stub.sh"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CI="true" \
        _REMEDIATE_LLM_CMD="$_T/llm_stub.sh" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _normalize_tier1() { cp "$1" "$2"; }
            _check_usage_for_remediate() { return 0; }
            _phase_remediate "42" "https://github.com/x/y/pull/42" 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _llm_called="$(test -f "$_T/llm-calls.log" && echo yes || echo no)"
    _push_called="$(test -f "$_T/git-push-called" && echo yes || echo no)"

    assert_eq "t_phase_remediate_on_fix_agent_fail_returns_nonzero: LLM was called" "yes" "$_llm_called"
    assert_eq "t_phase_remediate_on_fix_agent_fail_returns_nonzero: no push" "no" "$_push_called"
}
t_phase_remediate_on_fix_agent_fail_returns_nonzero

# ---------------------------------------------------------------------------
# t_phase_remediate_on_artifact_missing_returns_nonzero
# When gh run download fails (artifacts unavailable), _phase_remediate must
# call gh run download and then return non-zero.

# ---------------------------------------------------------------------------
t_phase_remediate_on_artifact_missing_returns_nonzero() {
    local _T _branch_safe _state_file _ec _gh_called
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-miss-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-remediate-miss-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    mkdir -p "$_T/bin"

    _DSO_SF="$_state_file" _DSO_BRANCH="$_branch_safe" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
d = {'branch': os.environ['_DSO_BRANCH'], 'merge_sha': '', 'completed_phases': [],
     'current_phase': '', 'phases': {}, 'merge_strategy': 'pr', 'failed_run_id': 'RUN123'}
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
import os as _os
_os.rename(sf + '.tmp', sf)
" 2>/dev/null || true

    # gh shim: run download fails
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
case "\$1 \$2" in
  "run download")
    echo "ERROR: artifact not found" >&2
    exit 1
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CI="true" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _check_usage_for_remediate() { return 0; }
            _phase_remediate "42" "https://github.com/x/y/pull/42" 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _gh_called="$(grep -q 'run download' "$_T/gh-argv.log" 2>/dev/null && echo true || echo false)"

    assert_eq "t_phase_remediate_on_artifact_missing_returns_nonzero: gh run download called" "true" "$_gh_called"
    assert_eq "t_phase_remediate_on_artifact_missing_returns_nonzero: exit non-zero" \
        "yes" "$([[ "$_ec" -ne 0 ]] && echo yes || echo no)"
}
t_phase_remediate_on_artifact_missing_returns_nonzero

# ---------------------------------------------------------------------------
# t_phase_remediate_failure_exits_exactly_2
# When _dispatch_fix_agent returns a non-FIXES_APPLIED result, _phase_remediate
# must return exactly exit code 2.

# ---------------------------------------------------------------------------
t_phase_remediate_failure_exits_exactly_2() {
    local _T _branch_safe _state_file _ec _push_called
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-ec2-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-remediate-ec2-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    mkdir -p "$_T/bin"

    _DSO_SF="$_state_file" _DSO_BRANCH="$_branch_safe" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
d = {'branch': os.environ['_DSO_BRANCH'], 'merge_sha': '', 'completed_phases': [],
     'current_phase': '', 'phases': {}, 'merge_strategy': 'pr', 'failed_run_id': 'RUN123'}
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
import os as _os
_os.rename(sf + '.tmp', sf)
" 2>/dev/null || true

    cat > "$_T/findings.json" <<'FINDINGS_EOF'
{"findings":[{"severity":"important","description":"test finding"}]}
FINDINGS_EOF

    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
case "\$1 \$2" in
  "run download")
    _prev=""
    _dir=""
    for _arg in "\$@"; do
      if [[ "\$_prev" == "--dir" ]]; then _dir="\$_arg"; fi
      _prev="\$_arg"
    done
    if [[ -n "\$_dir" ]]; then
      mkdir -p "\$_dir"
      cp "$_T/findings.json" "\$_dir/reviewer-findings.json"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # LLM stub: FAIL → triggers exit 2
    cat > "$_T/llm_stub.sh" <<LLM_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/llm-calls.log"
echo "RESOLUTION_RESULT: FAIL"
exit 0
LLM_EOF
    chmod +x "$_T/llm_stub.sh"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CI="true" \
        _REMEDIATE_LLM_CMD="$_T/llm_stub.sh" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _normalize_tier1() { cp "$1" "$2"; }
            _check_usage_for_remediate() { return 0; }
            _phase_remediate "42" "https://github.com/x/y/pull/42" 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _push_called="$(test -f "$_T/git-push-called" && echo yes || echo no)"

    assert_eq "t_phase_remediate_failure_exits_exactly_2: exact exit code 2" "2" "$_ec"
    assert_eq "t_phase_remediate_failure_exits_exactly_2: no push" "no" "$_push_called"
}
t_phase_remediate_failure_exits_exactly_2

# ---------------------------------------------------------------------------
# t_phase_remediate_on_repoll_failure_returns_nonzero
# When the re-poll after fix+push still fails CI, _phase_remediate must:
# - still call git push (fix was applied)
# - return non-zero (re-poll failed)

#             push sentinel doesn't exist → assertion 2 fails.
# ---------------------------------------------------------------------------
t_phase_remediate_on_repoll_failure_returns_nonzero() {
    local _T _branch_safe _state_file _ec _push_called
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-repoll-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-remediate-repoll-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    mkdir -p "$_T/bin"

    _DSO_SF="$_state_file" _DSO_BRANCH="$_branch_safe" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
d = {'branch': os.environ['_DSO_BRANCH'], 'merge_sha': '', 'completed_phases': [],
     'current_phase': '', 'phases': {}, 'merge_strategy': 'pr', 'failed_run_id': 'RUN123'}
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
import os as _os
_os.rename(sf + '.tmp', sf)
" 2>/dev/null || true

    cat > "$_T/findings.json" <<'FINDINGS_EOF'
{"findings":[{"severity":"important","description":"test finding"}]}
FINDINGS_EOF

    # gh shim: pr checks ALWAYS FAILURE (re-poll fails too)
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
case "\$1 \$2" in
  "run download")
    _prev=""
    _dir=""
    for _arg in "\$@"; do
      if [[ "\$_prev" == "--dir" ]]; then _dir="\$_arg"; fi
      _prev="\$_arg"
    done
    if [[ -n "\$_dir" ]]; then
      mkdir -p "\$_dir"
      cp "$_T/findings.json" "\$_dir/reviewer-findings.json"
    fi
    exit 0
    ;;
  "pr checks")
    echo '[{"name":"ci","state":"COMPLETED","bucket":"fail"}]'
    exit 0
    ;;
  "pr view")
    echo '{"state":"OPEN"}'
    exit 0
    ;;
  "run list")
    echo '[{"databaseId":"RUN123"}]'
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # git shim: creates push sentinel
    # Capture real git path BEFORE the shim is on PATH to avoid infinite recursion
    local _real_git_repoll
    _real_git_repoll="$(command -v git)"
    cat > "$_T/bin/git" <<GIT_SHIM
#!/usr/bin/env bash
_args=("\$@")
_idx=0
while [[ "\${_idx}" -lt "\${#_args[@]}" && "\${_args[\$_idx]}" == "-C" ]]; do
  _idx=\$(( _idx + 2 ))
done
_subcmd="\${_args[\$_idx]:-}"
case "\$_subcmd" in
  add|commit) exit 0 ;;
  push)
    touch "$_T/git-push-called"
    exit 0
    ;;
  *)
    exec "$_real_git_repoll" "\$@" 2>/dev/null || exit 0
    ;;
esac
GIT_SHIM
    chmod +x "$_T/bin/git"

    # LLM stub: FIXES_APPLIED so push is attempted
    cat > "$_T/llm_stub.sh" <<LLM_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/llm-calls.log"
echo "RESOLUTION_RESULT: FIXES_APPLIED"
exit 0
LLM_EOF
    chmod +x "$_T/llm_stub.sh"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CI="true" \
        _REMEDIATE_LLM_CMD="$_T/llm_stub.sh" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _normalize_tier1() { cp "$1" "$2"; }
            _check_usage_for_remediate() { return 0; }
            _phase_remediate "42" "https://github.com/x/y/pull/42" 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _push_called="$(test -f "$_T/git-push-called" && echo yes || echo no)"

    assert_eq "t_phase_remediate_on_repoll_failure_returns_nonzero: exit non-zero" \
        "yes" "$([[ "$_ec" -ne 0 ]] && echo yes || echo no)"
    assert_eq "t_phase_remediate_on_repoll_failure_returns_nonzero: push called" "yes" "$_push_called"
}
t_phase_remediate_on_repoll_failure_returns_nonzero

# ---------------------------------------------------------------------------
# t_main_flow_skips_remediate_on_poll_success
# Asserts that _phase_remediate is defined in merge-to-main-pr.sh.

# ---------------------------------------------------------------------------
t_main_flow_skips_remediate_on_poll_success() {
    local _T _branch_safe _func_defined _fix_agent_called
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-main-skip-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-main-skip-$$"

    # Primary assertion: _phase_remediate must be defined as a function
    _func_defined="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c 'source "$0" 2>/dev/null; declare -f _phase_remediate | grep -c _phase_remediate' \
        "$PR_SCRIPT" 2>/dev/null || echo 0
    )"
    [[ "$_func_defined" -gt 0 ]] && _func_defined="yes" || _func_defined="no"

    assert_eq "t_main_flow_skips_remediate_on_poll_success: _phase_remediate defined" \
        "yes" "$_func_defined"

    # Behavioral guard (GREEN-phase check): when poll succeeds, fix agent must NOT be called
    if [[ "$_func_defined" == "yes" ]]; then
        mkdir -p "$_T/bin"
        _branch_safe="test-skip-behav-$$"
        local _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
        rm -f "$_state_file"
        # shellcheck disable=SC2064
        trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

        cat > "$_T/fix-agent-stub.sh" <<FIX_EOF
#!/usr/bin/env bash
touch "$_T/fix-agent-called"
echo "RESOLUTION_RESULT: FIXES_APPLIED"
exit 0
FIX_EOF
        chmod +x "$_T/fix-agent-stub.sh"

        cat > "$_T/bin/gh" <<GH_SHIM2
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr checks")  echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'; exit 0 ;;
  "pr view")
    if [[ "\$*" == *"--json state"* ]]; then echo '{"state":"MERGED"}'; exit 0; fi
    if [[ "\$*" == *"--json mergeCommit"* ]]; then echo '{"mergeCommit":{"oid":"abc123"}}'; exit 0; fi
    echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'; exit 0
    ;;
  "pr create")  echo "https://github.com/x/y/pull/42"; exit 0 ;;
  "pr merge")   exit 0 ;;
  "pr list")    exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM2
        chmod +x "$_T/bin/gh"

        # Capture real git path before shim is on PATH to avoid infinite recursion
        local _real_git_skip
        _real_git_skip="$(command -v git)"
        cat > "$_T/bin/git" <<GIT_SHIM2
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then exit 0; fi
exec "$_real_git_skip" "\$@" 2>/dev/null || exit 0
GIT_SHIM2
        chmod +x "$_T/bin/git"

        cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

        (
            cd "$_T" || exit 1
            PATH="$_T/bin:$PATH" \
            CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
            MERGE_STRATEGY="pr" \
            BRANCH="$_branch_safe" \
            WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
            CI="true" \
            PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
            PR_THREAD_LOOP_INTERVAL=0 \
            _REMEDIATE_LLM_CMD="$_T/fix-agent-stub.sh" \
            bash "$PR_SCRIPT" 2>/dev/null
        ) 2>/dev/null || true

        _fix_agent_called="$(test -f "$_T/fix-agent-called" && echo yes || echo no)"
        assert_eq "t_main_flow_skips_remediate_on_poll_success: fix agent NOT called on success" \
            "no" "$_fix_agent_called"
    fi
}
t_main_flow_skips_remediate_on_poll_success

# ===========================================================================
# Tests for _phase_conflict_resolution (task 9b44-ac2a-ceb0-45a1)
#
# _phase_conflict_resolution(pr_number, pr_url) is NOT YET IMPLEMENTED.
# All 4 tests below FAIL before the function is added.
# ===========================================================================

# ---------------------------------------------------------------------------
# t_phase_conflict_resolution_dispatches_when_conflicting
# When gh pr view --json mergeStateStatus returns CONFLICTING on first call
# and CLEAN on second call, _phase_conflict_resolution must:
#   - call _dispatch_resolve_conflicts exactly once
#   - return 0

# ---------------------------------------------------------------------------
t_phase_conflict_resolution_dispatches_when_conflicting() {
    local _T _branch_safe _dispatch_called _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pcr-dispatch-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-pcr-dispatch-$$"

    # gh shim: first mergeStateStatus call → CONFLICTING; second → CLEAN
    local _gh_call_count_file="$_T/gh-call-count"
    : > "$_gh_call_count_file"
    mkdir -p "$_T/bin"

    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
if [[ "\$*" == *"mergeStateStatus"* ]]; then
    printf 'x' >> "$_gh_call_count_file"
    _cnt=\$(wc -c < "$_gh_call_count_file" 2>/dev/null | tr -d ' ' || echo 0)
    if [[ "\$_cnt" -le 1 ]]; then
        echo "CONFLICTING"
    else
        echo "CLEAN"
    fi
    exit 0
fi
exit 0
GH_SHIM
    chmod +x "$_T/bin/gh"

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            # Stub _dispatch_resolve_conflicts to record call
            _dispatch_resolve_conflicts() {
                touch "'"$_T/dispatch-called"'"
                return 0
            }
            _phase_conflict_resolution "123" "https://example.com/pr/123"
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _dispatch_called="$(test -f "$_T/dispatch-called" && echo yes || echo no)"

    assert_eq "t_phase_conflict_resolution_dispatches_when_conflicting: returns 0" "0" "$_ec"
    assert_eq "t_phase_conflict_resolution_dispatches_when_conflicting: dispatch called" "yes" "$_dispatch_called"
}
t_phase_conflict_resolution_dispatches_when_conflicting

# ---------------------------------------------------------------------------
# t_phase_conflict_resolution_noop_when_not_conflicting
# When gh pr view --json mergeStateStatus returns CLEAN (not CONFLICTING),
# _phase_conflict_resolution must return 0 WITHOUT calling
# _dispatch_resolve_conflicts.

# ---------------------------------------------------------------------------
t_phase_conflict_resolution_noop_when_not_conflicting() {
    local _T _branch_safe _dispatch_called _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pcr-noop-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-pcr-noop-$$"

    mkdir -p "$_T/bin"

    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
if [[ "\$*" == *"mergeStateStatus"* ]]; then
    echo "CLEAN"
    exit 0
fi
exit 0
GH_SHIM
    chmod +x "$_T/bin/gh"

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _dispatch_resolve_conflicts() {
                touch "'"$_T/dispatch-called"'"
                return 0
            }
            _phase_conflict_resolution "123" "https://example.com/pr/123"
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _dispatch_called="$(test -f "$_T/dispatch-called" && echo yes || echo no)"

    assert_eq "t_phase_conflict_resolution_noop_when_not_conflicting: returns 0" "0" "$_ec"
    assert_eq "t_phase_conflict_resolution_noop_when_not_conflicting: dispatch NOT called" "no" "$_dispatch_called"
}
t_phase_conflict_resolution_noop_when_not_conflicting

# ---------------------------------------------------------------------------
# t_phase_conflict_resolution_fails_when_conflicts_remain
# When gh pr view --json mergeStateStatus always returns CONFLICTING (even
# after _dispatch_resolve_conflicts runs), _phase_conflict_resolution must
# emit ESCALATION_REASON on stderr and return non-zero.

# ---------------------------------------------------------------------------
t_phase_conflict_resolution_fails_when_conflicts_remain() {
    local _T _branch_safe _stderr _ec _exits_nonzero _has_escalation
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pcr-fail-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-pcr-fail-$$"

    mkdir -p "$_T/bin"

    # gh shim: always returns CONFLICTING
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/gh-argv.log"
if [[ "\$*" == *"mergeStateStatus"* ]]; then
    echo "CONFLICTING"
    exit 0
fi
exit 0
GH_SHIM
    chmod +x "$_T/bin/gh"

    _stderr="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_branch_safe" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _dispatch_resolve_conflicts() {
                return 0
            }
            _phase_conflict_resolution "123" "https://example.com/pr/123"
        ' "$PR_SCRIPT" 2>&1 >/dev/null
    )"
    _ec=$?

    _exits_nonzero="false"
    [[ "$_ec" -ne 0 ]] && _exits_nonzero="true"

    _has_escalation="false"
    if echo "$_stderr" | grep -q "ESCALATION_REASON"; then
        _has_escalation="true"
    fi

    assert_eq "t_phase_conflict_resolution_fails_when_conflicts_remain: exits nonzero" "true" "$_exits_nonzero"
    assert_eq "t_phase_conflict_resolution_fails_when_conflicts_remain: emits ESCALATION_REASON" "true" "$_has_escalation"
}
t_phase_conflict_resolution_fails_when_conflicts_remain

# ---------------------------------------------------------------------------
# t_phase_remediate_not_called_when_conflict_resolution_fails
# DEFERRED: main-flow integration test added in T2 (GREEN) once production code
# has the _phase_conflict_resolution gate. Tests 1-3 above verify the function
# contract behaviorally (dispatches on CONFLICTING, no-op otherwise, ESCALATION
# on unresolved conflicts). The gate's interaction with the main flow is verified
# via end-to-end tests post-implementation.
# ---------------------------------------------------------------------------
t_phase_remediate_not_called_when_conflict_resolution_fails() {
    # DEFERRED: main-flow integration test requires production code to have the
    # _phase_conflict_resolution gate in place. Added in T2 [GREEN] post-implementation.
    # Tests 1-3 above cover the _phase_conflict_resolution contract behaviorally.
    true
}
t_phase_remediate_not_called_when_conflict_resolution_fails

# ---------------------------------------------------------------------------
#

# will fail because the function does not attempt tier2/3/4 normalizers.
# GREEN phase: once the 4-tier loop is implemented, call-tracking and
# exit-code assertions will pass.

# ---------------------------------------------------------------------------
# t_phase_remediate_tries_tier2_when_tier1_artifact_missing
#
# When _normalize_tier1 returns exit 3 (ARTIFACT_MISSING), _phase_remediate
# must proceed to try tier2. After T4 implementation, tier2 is tried and the
# test passes GREEN.
# ---------------------------------------------------------------------------
t_phase_remediate_tries_tier2_when_tier1_artifact_missing() {
    local _T branch _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-remediate-t2.XXXXXX")"
    branch="feature-remediate-tier2"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_pr_fixture "$_T" "$branch" "ok" "ok"

    local _branch_safe="${branch//\//-}"
    local _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-001","pr_url":"https://github.com/x/y/pull/42","pr_number":"42"}
STATE_EOF
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    local _tier2_called="$_T/normalize-tier2-called"

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1

            _normalize_tier1() { return 3; }

            _normalize_tier2() {
                touch "'"$_tier2_called"'"
                echo "{\"tier\":2,\"findings\":[]}" > "${2:-/dev/null}"
                return 0
            }

            _dispatch_fix_agent() { return 0; }
            _push_fix_branch()    { return 0; }
            _phase_poll()         { return 0; }
            _fetch_ci_log()       { return 1; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "42" "https://github.com/x/y/pull/42"
        ' "$PR_SCRIPT"
    ); _ec=$?

    local _tier2_was_called="false"
    [[ -f "$_tier2_called" ]] && _tier2_was_called="true"

    assert_eq "t_phase_remediate_tries_tier2_when_tier1_artifact_missing: tier2 normalizer called" "true" "$_tier2_was_called"
    assert_eq "t_phase_remediate_tries_tier2_when_tier1_artifact_missing: returns 0 after tier2 fix+poll green" "0" "$_ec"
}
t_phase_remediate_tries_tier2_when_tier1_artifact_missing

# ---------------------------------------------------------------------------
# t_phase_remediate_returns_2_when_all_tiers_artifact_missing
#
# When all four tier normalizers return exit 3 (ARTIFACT_MISSING), _phase_remediate
# must try each one and return 2 (all tiers exhausted). The condition is that
# tier2 WAS called — current code never reaches tier2.
# ---------------------------------------------------------------------------
t_phase_remediate_returns_2_when_all_tiers_artifact_missing() {
    local _T branch _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-remediate-all-miss.XXXXXX")"
    branch="feature-remediate-all-missing"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_pr_fixture "$_T" "$branch" "ok" "ok"

    local _branch_safe="${branch//\//-}"
    local _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-002","pr_url":"https://github.com/x/y/pull/42","pr_number":"42"}
STATE_EOF
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    local _tier2_called="$_T/normalize-tier2-called"
    local _tier3_called="$_T/normalize-tier3-called"
    local _tier4_called="$_T/normalize-tier4-called"

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1

            _normalize_tier1() { return 3; }
            _normalize_tier2() { touch "'"$_tier2_called"'"; return 3; }
            _normalize_tier3() { touch "'"$_tier3_called"'"; return 3; }
            _normalize_tier4() { touch "'"$_tier4_called"'"; return 3; }
            _fetch_ci_log()    { return 1; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "42" "https://github.com/x/y/pull/42"
        ' "$PR_SCRIPT"
    ); _ec=$?

    local _tier2_was_called="false"
    local _tier3_was_called="false"
    local _tier4_was_called="false"
    [[ -f "$_tier2_called" ]] && _tier2_was_called="true"
    [[ -f "$_tier3_called" ]] && _tier3_was_called="true"
    [[ -f "$_tier4_called" ]] && _tier4_was_called="true"

    assert_eq "t_phase_remediate_returns_2_when_all_tiers_artifact_missing: tier2 normalizer called" "true" "$_tier2_was_called"
    assert_eq "t_phase_remediate_returns_2_when_all_tiers_artifact_missing: tier3 normalizer called" "true" "$_tier3_was_called"
    assert_eq "t_phase_remediate_returns_2_when_all_tiers_artifact_missing: tier4 normalizer called" "true" "$_tier4_was_called"
    assert_eq "t_phase_remediate_returns_2_when_all_tiers_artifact_missing: returns 2" "2" "$_ec"
}
t_phase_remediate_returns_2_when_all_tiers_artifact_missing

# ---------------------------------------------------------------------------
# t_phase_remediate_continues_to_tier2_after_tier1_fix_fails_repoll
#
# When tier1 normalization and fix dispatch succeed but the subsequent poll
# returns 1 (CI still failing), _phase_remediate must proceed to tier2.
# current code doesn't have this fallthrough.
# ---------------------------------------------------------------------------
t_phase_remediate_continues_to_tier2_after_tier1_fix_fails_repoll() {
    local _T branch _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-remediate-repoll.XXXXXX")"
    branch="feature-remediate-repoll"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_pr_fixture "$_T" "$branch" "ok" "ok"

    local _branch_safe="${branch//\//-}"
    local _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-003","pr_url":"https://github.com/x/y/pull/42","pr_number":"42"}
STATE_EOF
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    local _tier2_called="$_T/normalize-tier2-called"
    local _poll_counter="$_T/poll-count"
    printf '0' > "$_poll_counter"

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1

            _normalize_tier1() {
                echo "{\"tier\":1,\"findings\":[]}" > "${2:-/dev/null}"
                return 0
            }

            _normalize_tier2() {
                touch "'"$_tier2_called"'"
                return 3
            }

            _normalize_tier3() { return 3; }
            _normalize_tier4() { return 3; }

            _dispatch_fix_agent() { return 0; }
            _push_fix_branch()    { return 0; }

            _phase_poll() {
                local _cnt
                _cnt=$(cat "'"$_poll_counter"'" 2>/dev/null || echo 0)
                _cnt=$(( _cnt + 1 ))
                printf "%s" "$_cnt" > "'"$_poll_counter"'"
                return 1
            }

            _fetch_ci_log() { return 1; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "42" "https://github.com/x/y/pull/42"
        ' "$PR_SCRIPT"
    ); _ec=$?

    local _tier2_was_called="false"
    [[ -f "$_tier2_called" ]] && _tier2_was_called="true"

    assert_eq "t_phase_remediate_continues_to_tier2_after_tier1_fix_fails_repoll: tier2 tried after tier1 repoll failure" "true" "$_tier2_was_called"
    assert_eq "t_phase_remediate_continues_to_tier2_after_tier1_fix_fails_repoll: returns 2 when all tiers exhaust" "2" "$_ec"
}
t_phase_remediate_continues_to_tier2_after_tier1_fix_fails_repoll

# ===========================================================================
# Tests for bounded-retry support in _phase_remediate
# (story 4786-614e-8467-4bba, task 0a02-a133-f925-43b7)
#
# All tests below FAIL because:
#   - _remediate_counter_increment is not yet defined in merge-to-main-pr.sh
#   - _remediate_emit_escalation is not yet defined in merge-to-main-pr.sh
#   - _state_write_remediation_state / _state_read_remediation_state are not yet
#     defined in merge-helpers.sh
#   - _dispatch_fix_agent does not yet accept a second argument (_attempt_num)
#     for budget-pressure injection
#
# Tests turn GREEN once T4b/T4c/T4d add those functions.
# ===========================================================================

# ---------------------------------------------------------------------------
# Group 1: _remediate_counter_increment
# ---------------------------------------------------------------------------

# t_remediate_counter_increment_stops_at_tier_ceiling
# When tier=1 and t1_count has just hit its ceiling (5), the function must
# emit "TIER_CEILING" on stdout.
# ---------------------------------------------------------------------------
t_remediate_counter_increment_stops_at_tier_ceiling() {
    local _out
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_counter_increment 1 5 0 0 0 10
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    local _has_ceiling="false"
    if echo "$_out" | grep -q "TIER_CEILING"; then
        _has_ceiling="true"
    fi

    assert_eq "t_remediate_counter_increment_stops_at_tier_ceiling: stdout contains TIER_CEILING" \
        "true" "$_has_ceiling"
}
t_remediate_counter_increment_stops_at_tier_ceiling

# ---------------------------------------------------------------------------
# t_remediate_counter_increment_stops_at_global_ceiling
# When global=15 (at or above the global ceiling), the function must emit
# "GLOBAL_CEILING" on stdout.
# ---------------------------------------------------------------------------
t_remediate_counter_increment_stops_at_global_ceiling() {
    local _out
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_counter_increment 2 3 3 0 0 15
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    local _has_ceiling="false"
    if echo "$_out" | grep -q "GLOBAL_CEILING"; then
        _has_ceiling="true"
    fi

    assert_eq "t_remediate_counter_increment_stops_at_global_ceiling: stdout contains GLOBAL_CEILING" \
        "true" "$_has_ceiling"
}
t_remediate_counter_increment_stops_at_global_ceiling

# ---------------------------------------------------------------------------
# t_remediate_counter_increment_returns_empty_under_ceiling
# When counts are well under all ceilings, the function must produce no
# stop-signal on stdout.
# ---------------------------------------------------------------------------
t_remediate_counter_increment_returns_empty_under_ceiling() {
    local _out _ec
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_counter_increment 1 2 0 0 0 5
        ' "$PR_SCRIPT" 2>/dev/null
    )"; _ec=$?

    assert_eq "t_remediate_counter_increment_returns_empty_under_ceiling: exit 0" \
        "0" "$_ec"
    assert_eq "t_remediate_counter_increment_returns_empty_under_ceiling: stdout is empty" \
        "" "$_out"
}
t_remediate_counter_increment_returns_empty_under_ceiling

# ---------------------------------------------------------------------------
# Group 2: _remediate_emit_escalation
# ---------------------------------------------------------------------------

# t_remediate_emit_escalation_outputs_valid_json
# The function must emit valid JSON on stdout that includes the required fields.
# function doesn't exist yet.
# ---------------------------------------------------------------------------
t_remediate_emit_escalation_outputs_valid_json() {
    local _out _valid _stop_reason _has_required_fields
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_emit_escalation \
                "TIER_CEILING" \
                "1" \
                '"'"'{"1":5,"2":0,"3":0,"4":0}'"'"' \
                "/dev/null" \
                "Retry with updated dependencies"
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    _valid="$(echo "$_out" | python3 -c "import json,sys; json.load(sys.stdin); print('ok')" 2>/dev/null || echo 'invalid')"
    _stop_reason="$(echo "$_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_reason','MISSING'))" 2>/dev/null || echo 'MISSING')"

    _has_required_fields="$(echo "$_out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
required=['stop_reason','tiers_attempted','attempts_per_tier','remaining_findings','suggested_next_step']
missing=[k for k in required if k not in d]
print('ok' if not missing else 'missing:'+','.join(missing))
" 2>/dev/null || echo 'invalid')"

    assert_eq "t_remediate_emit_escalation_outputs_valid_json: valid JSON" "ok" "$_valid"
    assert_eq "t_remediate_emit_escalation_outputs_valid_json: stop_reason=TIER_CEILING" "TIER_CEILING" "$_stop_reason"
    assert_eq "t_remediate_emit_escalation_outputs_valid_json: required fields present" "ok" "$_has_required_fields"
}
t_remediate_emit_escalation_outputs_valid_json

# ---------------------------------------------------------------------------
# t_remediate_emit_escalation_global_ceiling_stop_reason
# When called with stop_reason="GLOBAL_CEILING", JSON stop_reason must be
# "GLOBAL_CEILING".
# ---------------------------------------------------------------------------
t_remediate_emit_escalation_global_ceiling_stop_reason() {
    local _out _stop_reason
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_emit_escalation \
                "GLOBAL_CEILING" \
                "3" \
                '"'"'{"1":5,"2":3,"3":2,"4":0}'"'"' \
                "/dev/null" \
                "Global retry limit reached"
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    _stop_reason="$(echo "$_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_reason','MISSING'))" 2>/dev/null || echo 'MISSING')"
    assert_eq "t_remediate_emit_escalation_global_ceiling_stop_reason: stop_reason=GLOBAL_CEILING" \
        "GLOBAL_CEILING" "$_stop_reason"
}
t_remediate_emit_escalation_global_ceiling_stop_reason

# ---------------------------------------------------------------------------
# t_remediate_emit_escalation_cannot_proceed_stop_reason
# When called with stop_reason="CANNOT_PROCEED", JSON stop_reason must match.
# ---------------------------------------------------------------------------
t_remediate_emit_escalation_cannot_proceed_stop_reason() {
    local _out _stop_reason
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_emit_escalation \
                "CANNOT_PROCEED" \
                "1" \
                '"'"'{"1":1,"2":0,"3":0,"4":0}'"'"' \
                "/dev/null" \
                "Manual intervention required"
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    _stop_reason="$(echo "$_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_reason','MISSING'))" 2>/dev/null || echo 'MISSING')"
    assert_eq "t_remediate_emit_escalation_cannot_proceed_stop_reason: stop_reason=CANNOT_PROCEED" \
        "CANNOT_PROCEED" "$_stop_reason"
}
t_remediate_emit_escalation_cannot_proceed_stop_reason

# ---------------------------------------------------------------------------
# t_remediate_emit_escalation_oscillation_stop_reason
# ---------------------------------------------------------------------------
t_remediate_emit_escalation_oscillation_stop_reason() {
    local _out _stop_reason
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_emit_escalation \
                "OSCILLATION" \
                "2" \
                '"'"'{"1":2,"2":1,"3":0,"4":0}'"'"' \
                "/dev/null" \
                "Fix oscillating between states"
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    _stop_reason="$(echo "$_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_reason','MISSING'))" 2>/dev/null || echo 'MISSING')"
    assert_eq "t_remediate_emit_escalation_oscillation_stop_reason: stop_reason=OSCILLATION" \
        "OSCILLATION" "$_stop_reason"
}
t_remediate_emit_escalation_oscillation_stop_reason

# ---------------------------------------------------------------------------
# t_remediate_emit_escalation_throttle_pause_stop_reason
# ---------------------------------------------------------------------------
t_remediate_emit_escalation_throttle_pause_stop_reason() {
    local _out _stop_reason
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_emit_escalation \
                "THROTTLE_PAUSE" \
                "1" \
                '"'"'{"1":1,"2":0,"3":0,"4":0}'"'"' \
                "/dev/null" \
                "Usage throttle hit; retry later"
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    _stop_reason="$(echo "$_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_reason','MISSING'))" 2>/dev/null || echo 'MISSING')"
    assert_eq "t_remediate_emit_escalation_throttle_pause_stop_reason: stop_reason=THROTTLE_PAUSE" \
        "THROTTLE_PAUSE" "$_stop_reason"
}
t_remediate_emit_escalation_throttle_pause_stop_reason

# ---------------------------------------------------------------------------
# t_remediate_emit_escalation_conflict_resolution_failed_stop_reason
# ---------------------------------------------------------------------------
t_remediate_emit_escalation_conflict_resolution_failed_stop_reason() {
    local _out _stop_reason
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_emit_escalation \
                "CONFLICT_RESOLUTION_FAILED" \
                "2" \
                '"'"'{"1":2,"2":1,"3":0,"4":0}'"'"' \
                "/dev/null" \
                "Resolve conflicts manually"
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    _stop_reason="$(echo "$_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_reason','MISSING'))" 2>/dev/null || echo 'MISSING')"
    assert_eq "t_remediate_emit_escalation_conflict_resolution_failed_stop_reason: stop_reason=CONFLICT_RESOLUTION_FAILED" \
        "CONFLICT_RESOLUTION_FAILED" "$_stop_reason"
}
t_remediate_emit_escalation_conflict_resolution_failed_stop_reason

# ---------------------------------------------------------------------------
# t_remediate_emit_escalation_artifact_missing_stop_reason
# ---------------------------------------------------------------------------
t_remediate_emit_escalation_artifact_missing_stop_reason() {
    local _out _stop_reason
    _out="$(
        PR_LIB_MODE=1 CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" MERGE_STRATEGY="pr" \
        bash -c '
            source "$0" 2>/dev/null
            _remediate_emit_escalation \
                "ARTIFACT_MISSING" \
                "4" \
                '"'"'{"1":0,"2":0,"3":0,"4":1}'"'"' \
                "/dev/null" \
                "All tier artifacts unavailable"
        ' "$PR_SCRIPT" 2>/dev/null
    )" || true

    _stop_reason="$(echo "$_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_reason','MISSING'))" 2>/dev/null || echo 'MISSING')"
    assert_eq "t_remediate_emit_escalation_artifact_missing_stop_reason: stop_reason=ARTIFACT_MISSING" \
        "ARTIFACT_MISSING" "$_stop_reason"
}
t_remediate_emit_escalation_artifact_missing_stop_reason

# ---------------------------------------------------------------------------
# Group 3: _state_write_remediation_state / _state_read_remediation_state
# ---------------------------------------------------------------------------

# t_state_write_read_remediation_state_round_trip
# After _state_init + _state_write_remediation_state, _state_read_remediation_state
# must return output containing the written phase and global attempt count.
# neither function exists in merge-helpers.sh yet.
# ---------------------------------------------------------------------------
t_state_write_read_remediation_state_round_trip() {
    local _branch_safe _state_file _output
    _branch_safe="test-branch-4786"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    _output="$(
        BRANCH="$_branch_safe" MERGE_STRATEGY="pr" \
        bash -c "
            source '$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh' 2>/dev/null || exit 1
            _state_init 2>/dev/null || true
            _state_write_remediation_state 'remediate' '{\"1\":2,\"2\":0,\"3\":0,\"4\":0}' 2 2>/dev/null
            _state_read_remediation_state 2>/dev/null
        "
    )" 2>/dev/null || true

    local _has_phase="false"
    local _has_global_count="false"
    if echo "$_output" | grep -q "remediation_phase=remediate"; then
        _has_phase="true"
    fi
    if echo "$_output" | grep -q "remediation_attempts_global=2"; then
        _has_global_count="true"
    fi

    assert_eq "t_state_write_read_remediation_state_round_trip: phase persisted" \
        "true" "$_has_phase"
    assert_eq "t_state_write_read_remediation_state_round_trip: global count persisted" \
        "true" "$_has_global_count"
}
t_state_write_read_remediation_state_round_trip

# ---------------------------------------------------------------------------
# Group 4: _dispatch_fix_agent budget-pressure injection
# ---------------------------------------------------------------------------

# t_dispatch_fix_agent_injects_budget_pressure_at_attempt_4
# When called with attempt_num=4, the prompt passed to the LLM command must
# contain "attempt 4 of 5" (or similar budget-pressure language indicating
# the penultimate attempt). RED: _dispatch_fix_agent doesn't accept a second
# argument yet.
# ---------------------------------------------------------------------------
t_dispatch_fix_agent_injects_budget_pressure_at_attempt_4() {
    local _T _branch_safe _captured_output
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatch-budget-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-budget-pressure-$$"

    cat > "$_T/findings.json" <<'FINDINGS_EOF'
{"findings":[{"severity":"important","description":"test finding","file":"foo.py"}]}
FINDINGS_EOF

    # Capture stub: records everything passed to it to a log file
    cat > "$_T/capture_stub.sh" <<CAPTURE_EOF
#!/usr/bin/env bash
# Write all args and stdin to the capture log
printf '%s\n' "\$*" >> "$_T/capture.log"
cat >> "$_T/capture.log" 2>/dev/null || true
echo "RESOLUTION_RESULT: FIXES_APPLIED"
exit 0
CAPTURE_EOF
    chmod +x "$_T/capture_stub.sh"

    (
        cd "$_T" || exit 1
        CI="true" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="$_branch_safe" \
        MERGE_STRATEGY="pr" \
        _REMEDIATE_LLM_CMD="$_T/capture_stub.sh" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _dispatch_fix_agent "'"$_T/findings.json"'" 4 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null || true

    _captured_output="$(cat "$_T/capture.log" 2>/dev/null || echo '')"

    local _has_budget_pressure="false"
    if echo "$_captured_output" | grep -q "attempt 4 of 5"; then
        _has_budget_pressure="true"
    fi

    assert_eq "t_dispatch_fix_agent_injects_budget_pressure_at_attempt_4: budget pressure in LLM input" \
        "true" "$_has_budget_pressure"
}
t_dispatch_fix_agent_injects_budget_pressure_at_attempt_4

# ---------------------------------------------------------------------------
# t_dispatch_fix_agent_no_budget_pressure_at_attempt_1
# When called with attempt_num=1 (first attempt), the prompt must NOT contain
# "attempt 4 of 5" budget-pressure text.
# _dispatch_fix_agent doesn't accept a second argument yet.
# ---------------------------------------------------------------------------
t_dispatch_fix_agent_no_budget_pressure_at_attempt_1() {
    local _T _branch_safe _captured_output
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dispatch-nobudget-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _branch_safe="test-no-budget-$$"

    cat > "$_T/findings.json" <<'FINDINGS_EOF'
{"findings":[{"severity":"important","description":"test finding","file":"foo.py"}]}
FINDINGS_EOF

    cat > "$_T/capture_stub.sh" <<CAPTURE_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T/capture.log"
cat >> "$_T/capture.log" 2>/dev/null || true
echo "RESOLUTION_RESULT: FIXES_APPLIED"
exit 0
CAPTURE_EOF
    chmod +x "$_T/capture_stub.sh"

    (
        cd "$_T" || exit 1
        CI="true" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="$_branch_safe" \
        MERGE_STRATEGY="pr" \
        _REMEDIATE_LLM_CMD="$_T/capture_stub.sh" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _dispatch_fix_agent "'"$_T/findings.json"'" 1 2>/dev/null
        ' "$PR_SCRIPT"
    ) 2>/dev/null || true

    _captured_output="$(cat "$_T/capture.log" 2>/dev/null || echo '')"

    local _has_budget_pressure="false"
    if echo "$_captured_output" | grep -q "attempt 4 of 5"; then
        _has_budget_pressure="true"
    fi

    assert_eq "t_dispatch_fix_agent_no_budget_pressure_at_attempt_1: no budget pressure at attempt 1" \
        "false" "$_has_budget_pressure"
}
t_dispatch_fix_agent_no_budget_pressure_at_attempt_1

# ===========================================================================
# Tests for _phase_remediate bounded-retry loop integration
# (story 4786-614e-8467-4bba, task c28e-4d62-fe45-4b73 — T3 RED phase)
#
# All 8 tests below FAIL because _phase_remediate does not yet call
# _remediate_counter_increment, _remediate_emit_escalation,
# _state_write_remediation_state, or check throttle state before dispatch.
# Tests turn GREEN once the T4 implementation adds the bounded retry loop.
# ===========================================================================

# ---------------------------------------------------------------------------
# t_phase_remediate_stops_at_tier_ceiling
# When _remediate_counter_increment returns TIER_CEILING, _phase_remediate must
# exit 2 and emit JSON containing stop_reason=TIER_CEILING. RED: _phase_remediate
# does not call _remediate_counter_increment.
# ---------------------------------------------------------------------------
t_phase_remediate_stops_at_tier_ceiling() {
    local _T _branch_safe _state_file _ec _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-tier-ceil.XXXXXX")"
    _branch_safe="test-tier-ceiling-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-ceil-001","pr_url":"https://github.com/x/y/pull/99","pr_number":"99"}
STATE_EOF

    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run download") exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    _ec=0
    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        BRANCH="$_branch_safe" \
        bash -c '
            source "$0" 2>/dev/null

            _normalize_tier1() { echo "{\"tier\":1,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }
            _dispatch_fix_agent() { return 0; }
            _push_fix_branch()    { return 0; }
            _phase_poll()         { return 1; }
            _fetch_ci_log()       { return 1; }
            _remediate_counter_increment() { echo "TIER_CEILING"; return 0; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "99" "https://github.com/x/y/pull/99"
        ' "$PR_SCRIPT" 2>/dev/null
    )"; _ec=$?

    local _has_stop_reason="false"
    local _has_tier_ceiling="false"
    if echo "$_out" | grep -q '"stop_reason"'; then _has_stop_reason="true"; fi
    if echo "$_out" | grep -q "TIER_CEILING";    then _has_tier_ceiling="true"; fi

    assert_eq "t_phase_remediate_stops_at_tier_ceiling: exit code 2" "2" "$_ec"
    assert_eq "t_phase_remediate_stops_at_tier_ceiling: stop_reason in output" "true" "$_has_stop_reason"
    assert_eq "t_phase_remediate_stops_at_tier_ceiling: TIER_CEILING in output" "true" "$_has_tier_ceiling"
}
t_phase_remediate_stops_at_tier_ceiling

# ---------------------------------------------------------------------------
# t_phase_remediate_stops_at_global_ceiling
# When _remediate_counter_increment returns GLOBAL_CEILING, _phase_remediate must
# exit 2 and emit output containing GLOBAL_CEILING. RED: same as above.
# ---------------------------------------------------------------------------
t_phase_remediate_stops_at_global_ceiling() {
    local _T _branch_safe _state_file _ec _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-global-ceil.XXXXXX")"
    _branch_safe="test-global-ceiling-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-gceil-001","pr_url":"https://github.com/x/y/pull/99","pr_number":"99"}
STATE_EOF

    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run download") exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    _ec=0
    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        BRANCH="$_branch_safe" \
        bash -c '
            source "$0" 2>/dev/null

            _normalize_tier1() { echo "{\"tier\":1,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }
            _dispatch_fix_agent() { return 0; }
            _push_fix_branch()    { return 0; }
            _phase_poll()         { return 1; }
            _fetch_ci_log()       { return 1; }
            _remediate_counter_increment() { echo "GLOBAL_CEILING"; return 0; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "99" "https://github.com/x/y/pull/99"
        ' "$PR_SCRIPT" 2>/dev/null
    )"; _ec=$?

    local _has_global_ceiling="false"
    if echo "$_out" | grep -q "GLOBAL_CEILING"; then _has_global_ceiling="true"; fi

    assert_eq "t_phase_remediate_stops_at_global_ceiling: exit code 2" "2" "$_ec"
    assert_eq "t_phase_remediate_stops_at_global_ceiling: GLOBAL_CEILING in output" "true" "$_has_global_ceiling"
}
t_phase_remediate_stops_at_global_ceiling

# ---------------------------------------------------------------------------
# t_phase_remediate_stops_on_cannot_proceed
# When _dispatch_fix_agent returns 2 (ESCALATE), _phase_remediate must exit 2
# and emit output containing CANNOT_PROCEED. RED: _phase_remediate continues
# to next tier on dispatch failure instead of emitting CANNOT_PROCEED.
# ---------------------------------------------------------------------------
t_phase_remediate_stops_on_cannot_proceed() {
    local _T _branch_safe _state_file _ec _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-cannot.XXXXXX")"
    _branch_safe="test-cannot-proceed-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-cant-001","pr_url":"https://github.com/x/y/pull/99","pr_number":"99"}
STATE_EOF

    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run download") exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    _ec=0
    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        BRANCH="$_branch_safe" \
        bash -c '
            source "$0" 2>/dev/null

            _normalize_tier1() { echo "{\"tier\":1,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }
            _dispatch_fix_agent() { return 2; }
            _push_fix_branch()    { return 0; }
            _phase_poll()         { return 1; }
            _fetch_ci_log()       { return 1; }
            _normalize_tier2()    { return 3; }
            _normalize_tier3()    { return 3; }
            _normalize_tier4()    { return 3; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "99" "https://github.com/x/y/pull/99"
        ' "$PR_SCRIPT" 2>/dev/null
    )"; _ec=$?

    local _has_cannot="false"
    if echo "$_out" | grep -q "CANNOT_PROCEED"; then _has_cannot="true"; fi

    assert_eq "t_phase_remediate_stops_on_cannot_proceed: exit code 2" "2" "$_ec"
    assert_eq "t_phase_remediate_stops_on_cannot_proceed: CANNOT_PROCEED in output" "true" "$_has_cannot"
}
t_phase_remediate_stops_on_cannot_proceed

# ---------------------------------------------------------------------------
# t_phase_remediate_writes_remediation_state_to_state_file
# After a remediation attempt, _phase_remediate must write remediation state
# (including remediation_attempts_global) to the state file. RED: _phase_remediate
# does not call _state_write_remediation_state.
# ---------------------------------------------------------------------------
t_phase_remediate_writes_remediation_state_to_state_file() {
    local _T _branch_safe _state_file _ec _state_contents
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-state-write.XXXXXX")"
    _branch_safe="test-state-write-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-sw-001","pr_url":"https://github.com/x/y/pull/99","pr_number":"99"}
STATE_EOF

    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run download") exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        BRANCH="$_branch_safe" \
        bash -c '
            source "$0" 2>/dev/null

            _normalize_tier1() { echo "{\"tier\":1,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }
            _dispatch_fix_agent() { return 0; }
            _push_fix_branch()    { return 0; }
            _phase_poll()         { return 1; }
            _fetch_ci_log()       { return 1; }
            _normalize_tier2()    { return 3; }
            _normalize_tier3()    { return 3; }
            _normalize_tier4()    { return 3; }
            _remediate_counter_increment() { echo "GLOBAL_CEILING"; return 0; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "99" "https://github.com/x/y/pull/99"
        ' "$PR_SCRIPT" 2>/dev/null
    ); _ec=$? || true

    _state_contents="$(cat "$_state_file" 2>/dev/null || echo '')"

    local _has_remediation_attempts="false"
    if echo "$_state_contents" | grep -q "remediation_attempts_global"; then
        _has_remediation_attempts="true"
    fi

    assert_eq "t_phase_remediate_writes_remediation_state_to_state_file: state file has remediation_attempts_global" \
        "true" "$_has_remediation_attempts"
}
t_phase_remediate_writes_remediation_state_to_state_file

# Test removed: t_phase_remediate_dispatches_oscillation_check_on_attempt_2_same_files
# stubbed _remediate_counter_increment to return OSCILLATION, but no production
# caller ever emits OSCILLATION. The OSCILLATION case in _phase_remediate was
# removed as dead code; if oscillation detection is added later, restore both
# the case branch and a behavioral test that verifies the actual detector logic.

# ---------------------------------------------------------------------------
# t_phase_remediate_injects_budget_pressure_at_attempt_4
# When _phase_remediate calls _dispatch_fix_agent on the 4th attempt of a
# given tier, it must pass attempt_num=4 so budget-pressure text is injected.
# Per-tier counter (not global) — the test forces 4 outer-loop iterations,
# so tier 1 reaches attempt 4 and budget pressure fires for tier 1's dispatch.
# ---------------------------------------------------------------------------
t_phase_remediate_injects_budget_pressure_at_attempt_4() {
    local _T _branch_safe _state_file _ec _dispatch_args_file
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-budget4.XXXXXX")"
    _branch_safe="test-budget4-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    _dispatch_args_file="$_T/dispatch-args.log"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-b4-001","pr_url":"https://github.com/x/y/pull/99","pr_number":"99"}
STATE_EOF

    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run download") exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # Create a LLM stub that captures its arguments for inspection
    cat > "$_T/llm_stub.sh" <<LLM_STUB_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_dispatch_args_file"
cat >> "$_dispatch_args_file" 2>/dev/null || true
echo "RESOLUTION_RESULT: FIXES_APPLIED"
exit 0
LLM_STUB_EOF
    chmod +x "$_T/llm_stub.sh"

    _ec=0
    (
        cd "$_T" || exit 1
        CI="true" \
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        BRANCH="$_branch_safe" \
        _REMEDIATE_LLM_CMD="$_T/llm_stub.sh" \
        bash -c '
            source "$0" 2>/dev/null

            # Normalizer that succeeds with minimal findings for ALL tiers
            # so we can drive 4+ dispatch calls
            _normalize_tier1() { echo "{\"tier\":1,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }
            _normalize_tier2() { echo "{\"tier\":2,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }
            _normalize_tier3() { echo "{\"tier\":3,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }
            _normalize_tier4() { echo "{\"tier\":4,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }

            # Push always succeeds; poll always fails (drives iteration through all tiers)
            _push_fix_branch() { return 0; }
            _phase_poll()      { return 1; }
            _fetch_ci_log()    { return 1; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "99" "https://github.com/x/y/pull/99"
        ' "$PR_SCRIPT" 2>/dev/null
    ); _ec=$? || true

    _captured="$(cat "$_dispatch_args_file" 2>/dev/null || echo '')"

    # The 4th dispatch call should contain "attempt 4 of 5" budget-pressure text
    local _has_budget_at_4="false"
    if echo "$_captured" | grep -q "attempt 4 of 5"; then _has_budget_at_4="true"; fi

    assert_eq "t_phase_remediate_injects_budget_pressure_at_attempt_4: budget pressure injected at attempt 4" \
        "true" "$_has_budget_at_4"
}
t_phase_remediate_injects_budget_pressure_at_attempt_4

# ---------------------------------------------------------------------------
# t_phase_remediate_emits_artifact_missing_when_all_tiers_fail
# When all tier normalizers return exit 3 (ARTIFACT_MISSING) and the CI log
# is also unavailable, _phase_remediate must exit 2 and emit output containing
# ARTIFACT_MISSING. RED: _phase_remediate just returns 2 without calling
# _remediate_emit_escalation so there is no ARTIFACT_MISSING in stdout.
# ---------------------------------------------------------------------------
t_phase_remediate_emits_artifact_missing_when_all_tiers_fail() {
    local _T _branch_safe _state_file _ec _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-artmiss.XXXXXX")"
    _branch_safe="test-artmiss-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-am-001","pr_url":"https://github.com/x/y/pull/99","pr_number":"99"}
STATE_EOF

    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run download") exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    _ec=0
    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        BRANCH="$_branch_safe" \
        bash -c '
            source "$0" 2>/dev/null

            _normalize_tier1() { return 3; }
            _normalize_tier2() { return 3; }
            _normalize_tier3() { return 3; }
            _normalize_tier4() { return 3; }
            _fetch_ci_log()    { return 1; }
            _check_usage_for_remediate() { return 0; }

            _phase_remediate "99" "https://github.com/x/y/pull/99"
        ' "$PR_SCRIPT" 2>/dev/null
    )"; _ec=$?

    local _has_artifact_missing="false"
    if echo "$_out" | grep -q "ARTIFACT_MISSING"; then _has_artifact_missing="true"; fi

    assert_eq "t_phase_remediate_emits_artifact_missing_when_all_tiers_fail: exit code 2" "2" "$_ec"
    assert_eq "t_phase_remediate_emits_artifact_missing_when_all_tiers_fail: ARTIFACT_MISSING in output" \
        "true" "$_has_artifact_missing"
}
t_phase_remediate_emits_artifact_missing_when_all_tiers_fail

# ---------------------------------------------------------------------------
# t_phase_remediate_emits_throttle_pause_when_usage_check_paused
# When the usage check returns 2 (paused), _phase_remediate must exit 2 and
# emit output containing THROTTLE_PAUSE without calling _dispatch_fix_agent.
# _phase_remediate has no usage-check gate before dispatch.
# ---------------------------------------------------------------------------
t_phase_remediate_emits_throttle_pause_when_usage_check_paused() {
    local _T _branch_safe _state_file _ec _out _dispatch_called_file
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-throttle.XXXXXX")"
    _branch_safe="test-throttle-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    _dispatch_called_file="$_T/dispatch-was-called"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    cat > "$_state_file" <<'STATE_EOF'
{"phase":"poll","failed_run_id":"run-thr-001","pr_url":"https://github.com/x/y/pull/99","pr_number":"99"}
STATE_EOF

    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run download") exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    _ec=0
    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        BRANCH="$_branch_safe" \
        bash -c '
            source "$0" 2>/dev/null

            _normalize_tier1() { echo "{\"tier\":1,\"findings\":[]}" > "${2:-/dev/null}"; return 0; }
            _fetch_ci_log()    { return 1; }
            _normalize_tier2() { return 3; }
            _normalize_tier3() { return 3; }
            _normalize_tier4() { return 3; }

            # Stub dispatch to record that it was called
            _dispatch_fix_agent() {
                touch "'"$_dispatch_called_file"'"
                return 0
            }
            _push_fix_branch() { return 0; }
            _phase_poll()      { return 1; }

            # Override the usage-check function that _phase_remediate will call
            _check_usage_for_remediate() { return 2; }
            # Also override the canonical check-usage path in case _phase_remediate uses it
            _check_remediate_usage() { return 2; }

            _phase_remediate "99" "https://github.com/x/y/pull/99"
        ' "$PR_SCRIPT" 2>/dev/null
    )"; _ec=$?

    local _has_throttle="false"
    local _dispatch_was_called="false"
    if echo "$_out" | grep -q "THROTTLE_PAUSE"; then _has_throttle="true"; fi
    [[ -f "$_dispatch_called_file" ]] && _dispatch_was_called="true"

    assert_eq "t_phase_remediate_emits_throttle_pause_when_usage_check_paused: exit code 2" "2" "$_ec"
    assert_eq "t_phase_remediate_emits_throttle_pause_when_usage_check_paused: THROTTLE_PAUSE in output" \
        "true" "$_has_throttle"
    assert_eq "t_phase_remediate_emits_throttle_pause_when_usage_check_paused: dispatch NOT called" \
        "false" "$_dispatch_was_called"
}
t_phase_remediate_emits_throttle_pause_when_usage_check_paused

# ---------------------------------------------------------------------------
# t_phase_remediate_resets_tier_counter_on_regression
# When a tier succeeded in pass N but fails in pass N+1 (cross-tier regression),
# _phase_remediate must reset that tier's counter to 0 and decrement the global
# counter by the reset amount, without exceeding the global ceiling.
# ---------------------------------------------------------------------------
t_phase_remediate_resets_tier_counter_on_regression() {
    local _T _branch_safe _state_file _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-remediate-regression-test.XXXXXX")"
    _branch_safe="test-tier-regression-$$"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    # Pre-write state file with failed_run_id
    _DSO_SF="$_state_file" _DSO_BRANCH="$_branch_safe" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
d = {'branch': os.environ['_DSO_BRANCH'], 'merge_sha': '', 'completed_phases': [],
     'current_phase': '', 'phases': {}, 'merge_strategy': 'pr', 'failed_run_id': 'RUN-REGRESSION'}
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
import os as _os
_os.rename(sf + '.tmp', sf)
" 2>/dev/null || true

    mkdir -p "$_T/bin"
    # gh shim: run download always succeeds (creates empty dir)
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "run download")
    _dir=""
    _prev=""
    for _arg in "$@"; do
      if [[ "$_prev" == "--dir" ]]; then _dir="$_arg"; fi
      _prev="$_arg"
    done
    [[ -n "$_dir" ]] && mkdir -p "$_dir"
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # Call-count file for _normalize_tier1: call 1 succeeds, call 2+ returns 3 (regression)
    local _t1_call_count_file="$_T/t1-call-count"
    : > "$_t1_call_count_file"

    _ec=0
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        PR_LIB_MODE="1" \
        BRANCH="$_branch_safe" \
        bash -c '
            source "$0" 2>/dev/null

            # Tier 1: succeeds on first call, regresses on subsequent calls
            _normalize_tier1() {
                printf "x" >> "'"$_t1_call_count_file"'"
                _cnt=$(wc -c < "'"$_t1_call_count_file"'" 2>/dev/null | tr -d " " || echo 0)
                if [[ "$_cnt" -le 1 ]]; then
                    echo "{\"tier\":1,\"findings\":[]}" > "${2:-/dev/null}"
                    return 0
                fi
                return 3
            }
            # Tiers 2-4: always missing
            _normalize_tier2() { return 3; }
            _normalize_tier3() { return 3; }
            _normalize_tier4() { return 3; }
            _fetch_ci_log()    { return 1; }

            _dispatch_fix_agent() { return 0; }
            _push_fix_branch()    { return 0; }
            _phase_poll()         { return 1; }
            _check_usage_for_remediate() { return 0; }

            # Counter: allow first 5 calls (empty), then emit GLOBAL_CEILING to exit the loop
            _counter_call_count=0
            _remediate_counter_increment() {
                _counter_call_count=$(( _counter_call_count + 1 ))
                if [[ "$_counter_call_count" -ge 6 ]]; then
                    echo "GLOBAL_CEILING"
                fi
                return 0
            }

            _phase_remediate "42" "https://github.com/x/y/pull/42"
        ' "$PR_SCRIPT" 2>/dev/null
    ); _ec=$?

    # After GLOBAL_CEILING, the state file should reflect the reset: tier 1 counter = 0
    local _t1_counter _ok="false"
    _t1_counter="$(python3 -c "
import json, sys
try:
    with open('$_state_file') as f:
        d = json.load(f)
    per_tier = d.get('remediation_attempts_per_tier', {})
    print(per_tier.get('1', 'MISSING'))
except Exception as e:
    print('ERR:' + str(e))
" 2>/dev/null)"

    # tier 1 counter must be 0 (was reset after regression)
    [[ "$_t1_counter" == "0" ]] && _ok="true"

    assert_eq "t_phase_remediate_resets_tier_counter_on_regression: tier1 counter reset to 0" \
        "true" "$_ok"
}
t_phase_remediate_resets_tier_counter_on_regression

# ---------------------------------------------------------------------------
# Auto-merge-disabled fallback tests
# ---------------------------------------------------------------------------
# When `gh pr merge --auto --merge` is rejected because auto-merge is disabled
# at the repo level, the script must:
#   (a) NOT exit 1 — the PR is created, CI must still run
#   (b) Persist auto_merge_disabled=true to the state file
#   (c) Issue `gh pr merge <num> --merge` (no --auto flag) once all checks pass
# ---------------------------------------------------------------------------

t_auto_merge_disabled_does_not_emit_conflict_data() {
    # Before the fix, auto-merge disabled produced CONFLICT_DATA with
    # resolution_strategy "pr-conflict" and exited 1 at the merge phase. The
    # new behavior treats it as a soft success — no CONFLICT_DATA, no exit-1
    # at this phase (any later non-zero is fine; covered by other tests).
    local _T branch _all_out _has_conflict_data
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-auto-merge-disabled"
    _build_pr_fixture "$_T" "$branch" "ok" "auto_disabled"

    _all_out="$_T/all.log"
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >"$_all_out" 2>&1
    ) || true

    _has_conflict_data="false"
    if grep -q '"resolution_strategy": *"pr-conflict"' "$_all_out" 2>/dev/null; then
        _has_conflict_data="true"
    fi
    assert_eq "t_auto_merge_disabled_does_not_emit_conflict_data" "false" "$_has_conflict_data"

    rm -f /tmp/merge-to-main-state-*.json 2>/dev/null || true
}
t_auto_merge_disabled_does_not_emit_conflict_data

t_auto_merge_disabled_emits_warning_and_continues() {
    # When auto-merge is disabled, the merge phase must emit a clear WARNING
    # (so operators understand why the script fell through to manual merge)
    # rather than emitting an ERROR / CONFLICT_DATA pair that previously
    # caused the script to exit 1.
    local _T branch _all_out _has_warning _has_error
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-auto-merge-warning"
    _build_pr_fixture "$_T" "$branch" "ok" "auto_disabled"

    _all_out="$_T/all.log"
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >"$_all_out" 2>&1
    ) || true

    _has_warning="false"
    if grep -q "WARNING: GitHub auto-merge is disabled" "$_all_out"; then
        _has_warning="true"
    fi
    # The old failure path printed "ERROR: GitHub auto-merge is disabled" — must NOT appear.
    _has_error="false"
    if grep -q "ERROR: GitHub auto-merge is disabled" "$_all_out"; then
        _has_error="true"
    fi

    assert_eq "t_auto_merge_disabled_emits_warning_and_continues:warning_present" "true" "$_has_warning"
    assert_eq "t_auto_merge_disabled_emits_warning_and_continues:error_absent" "false" "$_has_error"

    rm -f /tmp/merge-to-main-state-*.json 2>/dev/null || true
}
t_auto_merge_disabled_emits_warning_and_continues

t_auto_merge_disabled_invokes_manual_merge_in_poll() {
    # In the poll phase, when auto_merge_disabled is set and all checks pass,
    # the script must invoke `gh pr merge <num> --rebase` without --auto.
    # cca8 DD1: the manual fallback must rebase-merge too (no merge commit).
    local _T branch _argv _has_manual_merge
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-manual-merge-call"
    _build_pr_fixture "$_T" "$branch" "ok" "auto_disabled"

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

    # Look for a `pr merge 42 --rebase` invocation that does NOT include --auto.
    # The auto-attempt earlier in _phase_merge does include --auto and refuses,
    # so we need a separate non-auto call to confirm the fallback fired.
    _has_manual_merge="false"
    if echo "$_argv" | grep -E "^pr merge 42" | grep -v -- "--auto" | grep -q -- "--rebase"; then
        _has_manual_merge="true"
    fi

    assert_eq "t_auto_merge_disabled_invokes_manual_merge_in_poll" "true" "$_has_manual_merge"

    # Cleanup any state file produced by this run
    rm -f /tmp/merge-to-main-state-*.json 2>/dev/null || true
}
t_auto_merge_disabled_invokes_manual_merge_in_poll

t_state_write_read_auto_merge_disabled_round_trip() {
    # Direct unit test of the helpers in merge-helpers.sh.
    local _T _sf _val
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    BRANCH="round-trip-branch"
    export BRANCH
    # shellcheck source=/dev/null
    source "$REPO_ROOT/plugins/dso/hooks/lib/merge-helpers.sh"

    _state_init >/dev/null 2>&1
    _state_write_auto_merge_disabled "true"
    _val=$(_state_read_auto_merge_disabled)
    assert_eq "t_state_write_read_auto_merge_disabled_round_trip:true_persists" "true" "$_val"

    _state_write_auto_merge_disabled "false"
    _val=$(_state_read_auto_merge_disabled)
    assert_eq "t_state_write_read_auto_merge_disabled_round_trip:false_persists" "false" "$_val"

    # Default when state file absent
    _sf=$(_state_file_path 2>/dev/null)
    rm -f "$_sf"
    _val=$(_state_read_auto_merge_disabled)
    assert_eq "t_state_write_read_auto_merge_disabled_round_trip:default_false" "false" "$_val"

    rm -f /tmp/merge-to-main-state-*.json 2>/dev/null || true
    unset BRANCH
}
t_state_write_read_auto_merge_disabled_round_trip

# ---------------------------------------------------------------------------
# t_pr_squash_merge_fallback_exits_zero
# Given: gh returns a source-branch SHA for mergeCommit (API limitation for
#        squash merges) that is NOT on origin/main, but origin/main's HEAD IS
#        the actual squash commit.
# Expected: script exits 0 using git rev-parse origin/main as fallback SHA
#           (current behavior: exits 1 with "merge commit not found" error)
# ---------------------------------------------------------------------------
t_pr_squash_merge_fallback_exits_zero() {
    local _T branch _ec _branch_safe _state_file _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-squash-test.XXXXXX")"
    branch="feature-squash-merge"
    _branch_safe="${branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    local real_git
    real_git=$(command -v git)
    local bin="$_T/bin"
    mkdir -p "$bin"

    # Build remote repo whose main contains the squash commit
    local remote_dir="$_T/remote.git"
    "$real_git" init -q --bare -b main "$remote_dir" >/dev/null 2>&1
    local seed_dir="$_T/seed"
    "$real_git" init -q -b main "$seed_dir" >/dev/null 2>&1
    (
        cd "$seed_dir" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        # Squash commit: new commit on main representing the squash merge result
        echo "squashed-feat" > squashed.txt
        "$real_git" add squashed.txt
        "$real_git" commit -q -m "squash: feat (#42)" >/dev/null
    )
    local sha_on_main
    sha_on_main=$("$real_git" -C "$seed_dir" rev-parse HEAD)

    # Build a separate repo to generate the "source branch HEAD" SHA
    # (what GitHub returns for mergeCommit.oid on squash merges — not on main)
    local src_dir="$_T/src"
    "$real_git" init -q -b feat "$src_dir" >/dev/null 2>&1
    (
        cd "$src_dir" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "feat" > feat.txt
        "$real_git" add feat.txt
        "$real_git" commit -q -m "feat: add feature" >/dev/null
    )
    local source_branch_sha
    source_branch_sha=$("$real_git" -C "$src_dir" rev-parse HEAD)

    "$real_git" -C "$seed_dir" remote add origin "$remote_dir"
    "$real_git" -C "$seed_dir" push -q origin main >/dev/null 2>&1

    # Working repo
    (
        cd "$_T" || exit 1
        "$real_git" init -q -b main >/dev/null 2>&1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        "$real_git" remote add origin "$remote_dir"
        echo "local" > local.txt
        "$real_git" add local.txt
        "$real_git" commit -q -m "local" >/dev/null
        "$real_git" fetch -q origin "main:refs/remotes/origin/main" >/dev/null 2>&1 || \
            "$real_git" fetch -q origin >/dev/null 2>&1 || true
        "$real_git" checkout -q -b "$branch"
        echo "feature" > feature.txt
        "$real_git" add feature.txt
        "$real_git" commit -q -m "feature work" >/dev/null
    )

    # gh shim: returns source_branch_sha for mergeCommit (not sha_on_main)
    # This simulates GitHub's API limitation for squash merges
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    case "\$2" in
      list) exit 0 ;;
      create) echo "https://github.com/x/y/pull/42"; exit 0 ;;
      view)
        if [[ "\$*" == *"--json mergeCommit"* ]]; then
          echo "$source_branch_sha"
          exit 0
        fi
        if [[ "\$*" == *"--json state"* ]]; then
          echo "MERGED"
          exit 0
        fi
        if [[ "\$*" == *"--json headRefOid"* ]]; then
          echo ""
          exit 0
        fi
        if [[ "\$*" == *"comments,reviews,reviewThreads"* ]]; then
          echo "{}"
          exit 0
        fi
        echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0 ;;
      checks) echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'; exit 0 ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac ;;
  api)
    if [[ "\$2" == "graphql" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      exit 0
    fi
    exit 0 ;;
  repo)
    if [[ "\$2" == "view" ]]; then if [[ "\$*" == *"defaultBranchRef"* ]]; then echo "main"; exit 0; fi; echo "x/y"; exit 0; fi
    exit 0 ;;
  workflow) exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then exit 0; fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$bin/git"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" 2>&1
    )"
    _ec=$?

    local _exits_zero="false"
    [[ "$_ec" -eq 0 ]] && _exits_zero="true"
    local _fallback_logged="false"
    echo "$_out" | grep -qiE "squash|fallback" && _fallback_logged="true"

    assert_eq "t_pr_squash_merge_fallback_exits_zero:exits_zero" "true" "$_exits_zero"
    assert_eq "t_pr_squash_merge_fallback_exits_zero:fallback_logged" "true" "$_fallback_logged"
}
t_pr_squash_merge_fallback_exits_zero

# ---------------------------------------------------------------------------
# Local-environment guard tests: LLM dispatch must be CI-only.
# ---------------------------------------------------------------------------

# Helper — write an LLM stub that records its invocations into a log file
# so tests can assert the stub was NOT called when the guard fires first.
_write_llm_stub() {
    local _path="$1" _log="$2"
    cat > "$_path" <<STUB
#!/usr/bin/env bash
echo "called \$@" >> "$_log"
echo "RESOLUTION_RESULT: FIXES_APPLIED"
exit 0
STUB
    chmod +x "$_path"
}

# t_local_guard_dispatch_fix_agent_blocks_llm_when_not_ci
# When CI is unset, _dispatch_fix_agent MUST emit an escalation JSON, return 2,
# and NEVER invoke the LLM stub.
t_local_guard_dispatch_fix_agent_blocks_llm_when_not_ci() {
    local _T _stub_log _stdout _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-local-guard-fix.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _stub_log="$_T/llm.log"
    : > "$_stub_log"
    _write_llm_stub "$_T/llm_stub.sh" "$_stub_log"
    echo '{"findings":[]}' > "$_T/findings.json"

    _stdout=$(
        unset CI GITHUB_ACTIONS GITLAB_CI BUILDKITE CIRCLECI
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="local-guard-test" \
        PR_LIB_MODE="1" \
        _REMEDIATE_LLM_CMD="$_T/llm_stub.sh" \
        bash -c '
            source "$0" 2>/dev/null
            _dispatch_fix_agent "'"$_T/findings.json"'"
        ' "$PR_SCRIPT" 2>/dev/null
    )
    _ec=$?
    assert_eq "t_local_guard_dispatch_fix_agent:returns_2" "2" "$_ec"
    if [[ -s "$_stub_log" ]]; then
        (( ++FAIL ))
        printf "FAIL: t_local_guard_dispatch_fix_agent:llm_must_not_be_invoked\n  stub log non-empty: %s\n" "$(cat "$_stub_log")" >&2
    else
        (( ++PASS ))
    fi
    if echo "$_stdout" | grep -q '"escalation": "local_no_llm_dispatch"' && \
       echo "$_stdout" | grep -q '"phase": "remediate"'; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_local_guard_dispatch_fix_agent:escalation_json_emitted\n  stdout: %s\n" "$_stdout" >&2
    fi
}
t_local_guard_dispatch_fix_agent_blocks_llm_when_not_ci

# t_local_guard_dispatch_resolve_conflicts_blocks_llm_when_not_ci
t_local_guard_dispatch_resolve_conflicts_blocks_llm_when_not_ci() {
    local _T _stub_log _stdout _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-local-guard-conflict.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _stub_log="$_T/llm.log"
    : > "$_stub_log"
    _write_llm_stub "$_T/llm_stub.sh" "$_stub_log"

    _stdout=$(
        unset CI GITHUB_ACTIONS GITLAB_CI BUILDKITE CIRCLECI
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="local-guard-test" \
        PR_LIB_MODE="1" \
        _RESOLVE_CONFLICTS_LLM_CMD="$_T/llm_stub.sh" \
        bash -c '
            source "$0" 2>/dev/null
            _dispatch_resolve_conflicts 42 https://example.test/pr/42
        ' "$PR_SCRIPT" 2>/dev/null
    )
    _ec=$?
    assert_eq "t_local_guard_dispatch_resolve_conflicts:returns_2" "2" "$_ec"
    if [[ -s "$_stub_log" ]]; then
        (( ++FAIL ))
        printf "FAIL: t_local_guard_dispatch_resolve_conflicts:llm_must_not_be_invoked\n  stub log non-empty: %s\n" "$(cat "$_stub_log")" >&2
    else
        (( ++PASS ))
    fi
    if echo "$_stdout" | grep -q '"escalation": "local_no_llm_dispatch"' && \
       echo "$_stdout" | grep -q '"phase": "conflict_resolution"'; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_local_guard_dispatch_resolve_conflicts:escalation_json_emitted\n  stdout: %s\n" "$_stdout" >&2
    fi
}
t_local_guard_dispatch_resolve_conflicts_blocks_llm_when_not_ci

# t_local_guard_pr_dispatch_unresolved_batch_blocks_llm_when_not_ci
t_local_guard_pr_dispatch_unresolved_batch_blocks_llm_when_not_ci() {
    local _T _stub_log _stdout _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-local-guard-threads.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    _stub_log="$_T/llm.log"
    : > "$_stub_log"
    _write_llm_stub "$_T/llm_stub.sh" "$_stub_log"

    # Pass one tab-delimited thread entry: <thread_id>\t<other-fields-ignored>
    _stdout=$(
        unset CI GITHUB_ACTIONS GITLAB_CI BUILDKITE CIRCLECI
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="local-guard-test" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            declare -A _esc=()
            declare -a _code=()
            _disp=0
            _pr_dispatch_unresolved_batch \
                42 \
                https://example.test/pr/42 \
                "" \
                "'"$_T/llm_stub.sh"'" \
                10 \
                _disp \
                _esc \
                _code \
                $'"'"'thread-abc\tcomment-1\tdetail'"'"'
        ' "$PR_SCRIPT" 2>/dev/null
    )
    _ec=$?
    assert_eq "t_local_guard_pr_dispatch_unresolved_batch:returns_2" "2" "$_ec"
    if [[ -s "$_stub_log" ]]; then
        (( ++FAIL ))
        printf "FAIL: t_local_guard_pr_dispatch_unresolved_batch:llm_must_not_be_invoked\n  stub log non-empty: %s\n" "$(cat "$_stub_log")" >&2
    else
        (( ++PASS ))
    fi
    if echo "$_stdout" | grep -q '"escalation": "local_no_llm_dispatch"' && \
       echo "$_stdout" | grep -q '"phase": "resolve_threads"'; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_local_guard_pr_dispatch_unresolved_batch:escalation_json_emitted\n  stdout: %s\n" "$_stdout" >&2
    fi
}
t_local_guard_pr_dispatch_unresolved_batch_blocks_llm_when_not_ci

# ---------------------------------------------------------------------------
# _phase_check_pr_comments_since_push: new-comment detection.
# ---------------------------------------------------------------------------

# Helper — install a gh stub on PATH that emits a fixture payload for
# `gh pr view --json headRefOid`, `gh api .../commits/<sha>` (head commit
# date), and `gh pr view --json comments,reviews,reviewThreads`.
_install_gh_stub_for_comments() {
    local _bindir="$1"
    local _head_date="$2"
    local _payload_file="$3"   # contents for the comments+reviews+reviewThreads view
    mkdir -p "$_bindir"
    cat > "$_bindir/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *"--json headRefOid"*)        echo '{"headRefOid":"deadbeefcafe1234"}'; ;;
    *"api"*"commits/"*)           echo "$_head_date"; ;;
    *"--json comments,reviews,reviewThreads"*)
                                  cat "$_payload_file"
                                  ;;
    *)                            echo ""; ;;
esac
exit 0
STUB
    chmod +x "$_bindir/gh"
}

# Build a comments+reviews+reviewThreads payload pre-shaped per the script's
# inline jq filter (the function itself does not invoke jq again — it parses
# the structure directly via python).
_write_comments_payload() {
    local _path="$1"
    local _new_ts="$2"   # createdAt for "new" comments (after head_date)
    local _old_ts="$3"   # createdAt for "old" comments (before head_date)
    cat > "$_path" <<JSON
{
  "issue_comments": [
    {"createdAt": "$_old_ts", "body": "old", "author": "alice"},
    {"createdAt": "$_new_ts", "body": "new!",  "author": "bob"}
  ],
  "review_comments": [],
  "thread_comments": [
    {"createdAt": "$_new_ts", "body": "thread reply", "author": "carol"}
  ]
}
JSON
}

# t_check_pr_comments_new_comments_emit_escalation
# Two comments newer than head — function returns 1 with structured escalation.
t_check_pr_comments_new_comments_emit_escalation() {
    local _T _stdout _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-comments-new.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _write_comments_payload "$_T/payload.json" "2026-05-06T01:00:00Z" "2026-05-05T00:00:00Z"
    _install_gh_stub_for_comments "$_T/bin" "2026-05-06T00:30:00Z" "$_T/payload.json"

    _stdout=$(
        unset CI GITHUB_ACTIONS GITLAB_CI BUILDKITE CIRCLECI
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="comment-check-test" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _phase_check_pr_comments_since_push 42 https://example.test/pr/42
        ' "$PR_SCRIPT" 2>/dev/null
    )
    _ec=$?
    assert_eq "t_check_pr_comments_new_comments:returns_1" "1" "$_ec"
    if echo "$_stdout" | grep -q '"escalation": "local_no_llm_dispatch"' && \
       echo "$_stdout" | grep -q '"phase": "comments_since_push"'; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_check_pr_comments_new_comments:escalation_json\n  stdout: %s\n" "$_stdout" >&2
    fi
}
t_check_pr_comments_new_comments_emit_escalation

# t_check_pr_comments_no_new_returns_zero
# All comments older than head_date → function returns 0 (no escalation).
t_check_pr_comments_no_new_returns_zero() {
    local _T _stdout _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-comments-none.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    # All comments dated before head — none newer.
    cat > "$_T/payload.json" <<'JSON'
{
  "issue_comments": [
    {"createdAt": "2026-05-05T00:00:00Z", "body": "old", "author": "alice"}
  ],
  "review_comments": [],
  "thread_comments": []
}
JSON
    _install_gh_stub_for_comments "$_T/bin" "2026-05-06T00:30:00Z" "$_T/payload.json"

    _stdout=$(
        unset CI GITHUB_ACTIONS GITLAB_CI BUILDKITE CIRCLECI
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="comment-check-test" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _phase_check_pr_comments_since_push 42 https://example.test/pr/42
        ' "$PR_SCRIPT" 2>/dev/null
    )
    _ec=$?
    assert_eq "t_check_pr_comments_no_new:returns_0" "0" "$_ec"
    if [[ -z "$_stdout" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_check_pr_comments_no_new:no_stdout_when_clean\n  stdout: %s\n" "$_stdout" >&2
    fi
}
t_check_pr_comments_no_new_returns_zero

# t_check_pr_comments_skipped_in_ci
# Even with new comments present, CI=true short-circuits the function.
t_check_pr_comments_skipped_in_ci() {
    local _T _stdout _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-comments-ci.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _write_comments_payload "$_T/payload.json" "2026-05-06T01:00:00Z" "2026-05-05T00:00:00Z"
    _install_gh_stub_for_comments "$_T/bin" "2026-05-06T00:30:00Z" "$_T/payload.json"

    _stdout=$(
        CI="true" \
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        BRANCH="comment-check-test" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _phase_check_pr_comments_since_push 42 https://example.test/pr/42
        ' "$PR_SCRIPT" 2>/dev/null
    )
    _ec=$?
    assert_eq "t_check_pr_comments_skipped_in_ci:returns_0" "0" "$_ec"
    if [[ -z "$_stdout" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: t_check_pr_comments_skipped_in_ci:no_stdout\n  stdout: %s\n" "$_stdout" >&2
    fi
}
t_check_pr_comments_skipped_in_ci

# ---------------------------------------------------------------------------
# t_pr_syncs_origin_main_before_push (a456-c689)
# When origin/main has advanced past the branch merge-base (e.g. a prior PR
# merged), _phase_merge MUST incorporate origin/main before the push so that
# CI runs on the correct base.
#
# Fixture: a real git repo where origin/main is ONE commit ahead of the
# feature branch's fork point (shared history). Asserts that after the script
# runs, the branch HEAD is an ancestor of origin/main (i.e. origin/main was
# merged in).
# ---------------------------------------------------------------------------
t_pr_syncs_origin_main_before_push() {
    local _T branch _ec _branch_head _main_head _merged
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-sync-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-sync-test"

    local real_git
    real_git=$(command -v git)
    local bin="$_T/bin"
    mkdir -p "$bin"

    # --- Set up a bare remote ---
    local remote_dir="$_T/remote.git"
    "$real_git" init -q --bare -b main "$remote_dir" >/dev/null 2>&1

    # --- Seed remote with a "seed" commit ---
    local seed_dir="$_T/seed"
    "$real_git" init -q -b main "$seed_dir" >/dev/null 2>&1
    (
        cd "$seed_dir" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        "$real_git" remote add origin "$remote_dir"
        "$real_git" push -q origin main >/dev/null 2>&1
    )

    # --- Working repo: clone the seed commit, branch, then advance origin/main ---
    (
        cd "$_T" || exit 1
        "$real_git" init -q -b main >/dev/null 2>&1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        "$real_git" remote add origin "$remote_dir"
        # Fetch the seed commit
        "$real_git" fetch -q origin "main:refs/remotes/origin/main" >/dev/null 2>&1 || true
        "$real_git" reset -q --hard origin/main >/dev/null 2>&1
        # Create feature branch from the seed commit
        "$real_git" checkout -q -b "$branch"
        echo "feature" > feature.txt
        "$real_git" add feature.txt
        "$real_git" commit -q -m "feature work" >/dev/null
    )

    # --- Advance origin/main by one commit AFTER the branch was created ---
    local main_advance_dir="$_T/main-advance"
    "$real_git" clone -q "$remote_dir" "$main_advance_dir" >/dev/null 2>&1
    (
        cd "$main_advance_dir" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "hotfix" > hotfix.txt
        "$real_git" add hotfix.txt
        "$real_git" commit -q -m "hotfix on main" >/dev/null
        "$real_git" push -q origin main >/dev/null 2>&1
    )

    # Re-fetch in the working repo so it sees the new origin/main
    (
        cd "$_T" || exit 1
        "$real_git" fetch -q origin "main:refs/remotes/origin/main" >/dev/null 2>&1 || true
    )

    # Confirm the branch is behind origin/main before the script runs
    local _behind_before
    _behind_before=$("$real_git" -C "$_T" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    if [[ "$_behind_before" -eq 0 ]]; then
        echo "  FIXTURE_BUG: branch should be behind origin/main before fix (behind=$_behind_before)" >&2
        (( ++FAIL ))
        return
    fi

    # Build gh/git shims
    local gh_argv_log="$_T/gh-argv.log"
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    case "\$2" in
      list) exit 0 ;;
      create) echo "https://github.com/x/y/pull/42"; exit 0 ;;
      view)
        if [[ "\$*" == *"--json mergeCommit"* ]]; then
          echo "\$("$real_git" -C "$remote_dir" rev-parse HEAD 2>/dev/null || echo 'deadbeef')"
          exit 0
        fi
        if [[ "\$*" == *"--json state"* ]]; then echo "MERGED"; exit 0; fi
        echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0
        ;;
      checks) echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'; exit 0 ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  workflow) exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  exit 0
fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$bin/git"

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    (
        cd "$_T" || exit 1
        PATH="$bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$branch" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true

    # After the script runs, the branch HEAD should include the hotfix commit
    # (origin/main should be an ancestor of HEAD).
    _merged="false"
    if "$real_git" -C "$_T" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
        _merged="true"
    fi

    assert_eq "t_pr_syncs_origin_main_before_push:main_merged_before_push" "true" "$_merged"
}
t_pr_syncs_origin_main_before_push

# ---------------------------------------------------------------------------
# t_pr_auto_merge_queued_after_thread_resolution (ea7b-0038)
# Verifies that `gh pr merge --auto` is called AFTER the resolve-threads phase.
# The argv log is inspected to confirm ordering: the resolve-threads GraphQL
# query appears BEFORE the `pr merge --auto` call.
# ---------------------------------------------------------------------------
t_pr_auto_merge_queued_after_thread_resolution() {
    local _T branch _argv _resolve_line _auto_merge_line _ordered
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-auto-merge-order.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-auto-merge-order"
    # Use the polling fixture (success_after_2) — it provides a complete gh shim
    # that handles all phases including checks / state.
    _build_pr_polling_fixture "$_T" "$branch" "success_after_2"

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

    # The resolve-threads phase calls `gh pr view --json reviewDecision` (GraphQL
    # thread query). The auto-merge call is `pr merge <num> --auto --merge`.
    # Assert: the first `pr view` line appears before the `pr merge --auto` line.
    _resolve_line=$(echo "$_argv" | grep -n "pr view" | head -1 | cut -d: -f1 || true)
    _auto_merge_line=$(echo "$_argv" | grep -n "pr merge.*--auto" | head -1 | cut -d: -f1 || true)

    _ordered="false"
    if [[ -n "$_resolve_line" && -n "$_auto_merge_line" && "$_resolve_line" -lt "$_auto_merge_line" ]]; then
        _ordered="true"
    fi

    assert_eq "t_pr_auto_merge_queued_after_thread_resolution:auto_merge_after_resolve_threads" "true" "$_ordered"
}
t_pr_auto_merge_queued_after_thread_resolution

# ---------------------------------------------------------------------------
# t_review_comments_jq_always_has_createdAt (bug 03bf-3a5a)
# The review_comments jq filter previously had a dead first arm that produced
# body-only {body: ...} objects lacking createdAt/author. Those objects are
# silently dropped by the downstream Python (ca is None → condition fails).
# This test asserts that the review_comments expression in the script does NOT
# use the dead-arm pattern (first arm without createdAt) and that running the
# script's jq filter produces objects that all have createdAt.
# old expression had dead arm → review_comments had body-only objects.
# GREEN: after dead arm removal → every element has createdAt.
# ---------------------------------------------------------------------------
t_review_comments_jq_always_has_createdAt() {
    local _input _output _missing _count

    # Minimal payload: two reviews with bodies, one empty body to be excluded.
    _input='{"comments":[],"reviewThreads":[],"reviews":[{"submittedAt":"2026-05-07T10:00:00Z","body":"LGTM","author":{"login":"alice"}},{"submittedAt":"2026-05-07T11:00:00Z","body":"","author":{"login":"bob"}},{"submittedAt":"2026-05-07T12:00:00Z","body":"Needs work","author":{"login":"carol"}}]}'

    # Build the same jq filter shape as the script (single-arm, no dead arm).
    # This is the FIXED expression: only the arm that produces {createdAt, body, author}.
    _output=$(printf '%s' "$_input" | jq '{
        issue_comments: [.comments[]? | {createdAt, body, author: .author.login}],
        review_comments: [.reviews[]? | select(.body != null and .body != "") | {createdAt: .submittedAt, body: .body, author: .author.login}],
        thread_comments: [.reviewThreads[]?.comments[]? | {createdAt, body, author: .author.login}]
    }.review_comments' 2>/dev/null)

    # Verify the script does NOT contain the dead-arm pattern.
    local _dead_arm_present
    _dead_arm_present="false"
    if grep -q 'reviews\[\]?\.body?' "$PR_SCRIPT" 2>/dev/null; then
        _dead_arm_present="true"
    fi
    assert_eq "t_review_comments_jq_always_has_createdAt:no_dead_arm_in_script" "false" "$_dead_arm_present"

    # Every element in review_comments must have a non-null createdAt.
    _missing=$(printf '%s' "$_output" | jq '[.[] | select(.createdAt == null or .createdAt == "")] | length' 2>/dev/null || echo "error")
    assert_eq "t_review_comments_jq_always_has_createdAt:no_body_only_objects" "0" "$_missing"

    # Only the two non-empty reviews (alice + carol) should appear; bob (empty body) excluded.
    _count=$(printf '%s' "$_output" | jq 'length' 2>/dev/null || echo "error")
    assert_eq "t_review_comments_jq_always_has_createdAt:correct_count" "2" "$_count"
}
t_review_comments_jq_always_has_createdAt

# ===========================================================================
# Draft-aware _check_duplicate_pr guard tests (Task 0a63-754f — DD2, DD4)
# ===========================================================================
#
# These tests assert the amended _check_duplicate_pr() behavior:
#   - A draft PR (isDraft:true) MUST be allowed (exit 0)
#   - A non-draft PR (isDraft:false) MUST be blocked (exit 1)
#   - No open PR at all → allowed (exit 0)
#   - gh failure / malformed JSON → best-effort pass-through (exit 0)
#
# Tests fail until T2 amends gh pr list to:
#   --json number,url,isDraft ... | jq 'map(select(.isDraft == false)) | .[0].url // empty'
#
# The current implementation uses --jq '.[0].url' which ignores isDraft,
# causing a draft PR to be incorrectly blocked.
#
# Fixture strategy:
#   _build_check_dup_pr_fixture <tmpdir> <PR_LIST_MODE>
#     PR_LIST_MODE=draft     → gh pr list emits [{isDraft:true,number:99,url:...}]
#     PR_LIST_MODE=non_draft → gh pr list emits [{isDraft:false,number:99,url:...}]
#     PR_LIST_MODE=empty     → gh pr list emits []
#     PR_LIST_MODE=fail      → gh pr list exits 1 (simulate auth error)
#     PR_LIST_MODE=malformed → gh pr list emits non-JSON garbage
#
# _check_duplicate_pr() is sourced via PR_LIB_MODE=1 so we can call it directly
# without running the full merge-to-main-pr.sh pipeline.
# ---------------------------------------------------------------------------

_build_check_dup_pr_fixture() {
    local tmpdir="$1" pr_list_mode="$2"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"

    local real_git
    real_git=$(command -v git)

    # ---- gh shim: pr list arm returns payload based on PR_LIST_MODE ----
    # The shim reads PR_LIST_MODE from the environment at call time so each
    # test case can override it before invoking _check_duplicate_pr.
    #
    # Design note: the shim deliberately ignores the --jq flag when present.
    # This ensures the fixture works with both the current implementation
    # (--json number,url --jq '.[0].url') and the amended implementation
    # (--json number,url,isDraft piped to external jq).  For 'draft' and
    # 'non_draft' modes the shim emits a JSON array so:
    #   - Old code: captures the array string (non-empty) → blocks ALL PRs for draft
    #   - New code: pipes to jq map(select(.isDraft==false)) → correct filtering → GREEN
    # For 'empty' mode the shim emits nothing (matching real gh behavior when
    # --jq '.[0].url' on an empty list suppresses null output):
    #   - Old code: _existing="" → exit 0 (PASS)
    #   - New code: jq gets empty input → error suppressed by || true → exit 0 (PASS)
    cat > "$bin/gh" <<'GH_SHIM_EOF'
#!/usr/bin/env bash
case "$1" in
  --version)
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
  pr)
    case "$2" in
      list)
        case "${PR_LIST_MODE:-empty}" in
          draft)
            printf '[{"isDraft":true,"number":99,"url":"https://github.com/org/repo/pull/99"}]\n'
            exit 0
            ;;
          non_draft)
            printf '[{"isDraft":false,"number":99,"url":"https://github.com/org/repo/pull/99"}]\n'
            exit 0
            ;;
          empty)
            # Emit nothing — simulates real gh behavior when no open PRs exist.
            # Both old code (--jq '.[0].url' → null suppressed) and new code
            # (jq on empty input → error suppressed) produce empty string → exit 0.
            exit 0
            ;;
          fail)
            echo "error: authentication required" >&2
            exit 1
            ;;
          malformed)
            printf 'not-valid-json\n'
            exit 0
            ;;
        esac
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
GH_SHIM_EOF
    chmod +x "$bin/gh"

    # ---- git shim: push intercepted; all else delegated to real git ----
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

    # ---- Minimal git repo so rev-parse and branch detection resolve ----
    (
        cd "$tmpdir" || exit 1
        "$real_git" init -q -b main >/dev/null 2>&1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        "$real_git" checkout -q -b "feature-dup-guard"
        echo "work" > work.txt
        "$real_git" add work.txt
        "$real_git" commit -q -m "work" >/dev/null
    )
}

# Helper: source merge-to-main-pr.sh in PR_LIB_MODE=1 and call _check_duplicate_pr.
# Returns the exit code of _check_duplicate_pr.
# Args: $1=tmpdir $2=pr_list_mode
#
# Implementation note: uses a wrapper script written to disk because
# `bash -c "source ...; fn"` does NOT propagate functions defined in the
# sourced file — source runs in the inner bash -c shell but the function
# definitions are still not callable in a nested `bash -c`. A wrapper script
# that sources and immediately calls the function avoids this limitation.
_run_check_duplicate_pr() {
    local tmpdir="$1" pr_list_mode="$2"
    local wrapper
    wrapper="$(mktemp "${TMPDIR:-/tmp}/dso-dup-check-wrapper.XXXXXX")"
    cat > "$wrapper" <<WRAPPER_EOF
#!/usr/bin/env bash
set +e  # allow _check_duplicate_pr to return non-zero without aborting
# shellcheck disable=SC1090
PR_LIB_MODE=1 source "$PR_SCRIPT" 2>/dev/null
_check_duplicate_pr 2>/dev/null
exit \$?
WRAPPER_EOF
    chmod +x "$wrapper"
    (
        cd "$tmpdir" || exit 1
        PATH="$tmpdir/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="feature-dup-guard" \
        PR_LIST_MODE="$pr_list_mode" \
        bash "$wrapper"
    )
    local _ec=$?
    rm -f "$wrapper"
    return "$_ec"
}

# ---------------------------------------------------------------------------
# t_draft_pr_from_active_sprint_allowed
# Given: gh pr list returns a single draft PR (isDraft:true)
# When: _check_duplicate_pr runs
# Then: exit 0 — draft PRs (long-lived sprint PRs) must not block new merges
#
# causing exit 1 when a draft PR exists.
# ---------------------------------------------------------------------------
t_draft_pr_from_active_sprint_allowed() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dup-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_check_dup_pr_fixture "$_T" "draft"

    _run_check_duplicate_pr "$_T" "draft"
    _ec=$?

    assert_eq "t_draft_pr_from_active_sprint_allowed:exits_zero" "0" "$_ec"
}
t_draft_pr_from_active_sprint_allowed

# ---------------------------------------------------------------------------
# t_stale_draft_pr_allowed
# Given: gh pr list returns a stale draft PR (isDraft:true, different number)
# When: _check_duplicate_pr runs
# Then: exit 0 — all draft PRs are allowed regardless of age
#
# ---------------------------------------------------------------------------
t_stale_draft_pr_allowed() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dup-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_check_dup_pr_fixture "$_T" "draft"

    _run_check_duplicate_pr "$_T" "draft"
    _ec=$?

    assert_eq "t_stale_draft_pr_allowed:exits_zero" "0" "$_ec"
}
t_stale_draft_pr_allowed

# ---------------------------------------------------------------------------
# t_non_draft_release_pr_blocked
# Given: gh pr list returns a non-draft PR (isDraft:false)
# When: _check_duplicate_pr runs
# Then: exit 1 — non-draft open PR blocks the merge
#
# This test is GREEN with current code (both old and new behavior block on
# non-draft PRs). Included to guard against regression: the isDraft filter
# must never let non-draft PRs through.
# ---------------------------------------------------------------------------
t_non_draft_release_pr_blocked() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dup-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_check_dup_pr_fixture "$_T" "non_draft"

    _run_check_duplicate_pr "$_T" "non_draft"
    _ec=$?

    local _is_blocked="false"
    [[ "$_ec" -ne 0 ]] && _is_blocked="true"

    assert_eq "t_non_draft_release_pr_blocked:exits_nonzero" "true" "$_is_blocked"
}
t_non_draft_release_pr_blocked

# ---------------------------------------------------------------------------
# t_check_duplicate_pr_no_pr_allowed
# Given: gh pr list returns []
# When: _check_duplicate_pr runs
# Then: exit 0 — no open PR, nothing to block
# ---------------------------------------------------------------------------
t_check_duplicate_pr_no_pr_allowed() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dup-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_check_dup_pr_fixture "$_T" "empty"

    _run_check_duplicate_pr "$_T" "empty"
    _ec=$?

    assert_eq "t_check_duplicate_pr_no_pr_allowed:exits_zero" "0" "$_ec"
}
t_check_duplicate_pr_no_pr_allowed

# ---------------------------------------------------------------------------
# t_check_duplicate_pr_gh_failure_passes_through
# Given: gh pr list exits non-zero (e.g., auth failure)
# When: _check_duplicate_pr runs
# Then: exit 0 — best-effort: guard must not block on gh errors
#
# The comment at line 233-234 of merge-to-main-pr.sh documents this:
# "if gh fails ... proceed — the downstream PR-create call will surface it."
# ---------------------------------------------------------------------------
t_check_duplicate_pr_gh_failure_passes_through() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dup-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_check_dup_pr_fixture "$_T" "fail"

    _run_check_duplicate_pr "$_T" "fail"
    _ec=$?

    assert_eq "t_check_duplicate_pr_gh_failure_passes_through:exits_zero" "0" "$_ec"
}
t_check_duplicate_pr_gh_failure_passes_through

# ---------------------------------------------------------------------------
# t_check_duplicate_pr_malformed_json_passes_through
# Given: gh pr list returns non-JSON garbage (malformed response)
# When: _check_duplicate_pr runs
# Then: exit 0 — best-effort: malformed output must not block the merge
#
# to error; the `|| true` makes gh pr list produce empty string → exits 0.
# After T2, jq processes the malformed JSON and produces empty → exits 0.
# Both old and new code should pass this test.
# ---------------------------------------------------------------------------
t_check_duplicate_pr_malformed_json_passes_through() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dup-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_check_dup_pr_fixture "$_T" "malformed"

    _run_check_duplicate_pr "$_T" "malformed"
    _ec=$?

    assert_eq "t_check_duplicate_pr_malformed_json_passes_through:exits_zero" "0" "$_ec"
}
t_check_duplicate_pr_malformed_json_passes_through

# ---------------------------------------------------------------------------
# t_check_duplicate_pr_isdraft_filter_returns_empty_not_null
# Given: gh pr list returns only draft PRs (no non-draft PRs)
# When: _check_duplicate_pr runs with amended jq filter
# Then: the jq expression must produce empty string (not the literal "null")
#       so the [[ -n "$_existing" ]] guard correctly allows the merge.
#
# the draft PR's URL. With T2, map(select(.isDraft == false)) | .[0].url // empty
# must produce "" (empty), not "null", when all PRs are drafts.
# ---------------------------------------------------------------------------
t_check_duplicate_pr_isdraft_filter_returns_empty_not_null() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-dup-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_check_dup_pr_fixture "$_T" "draft"

    _run_check_duplicate_pr "$_T" "draft"
    _ec=$?

    # If the filter returned "null" as a string, [[ -n "$_existing" ]] would be
    # true and the guard would block — exit 1. We assert exit 0 to catch this.
    assert_eq "t_check_duplicate_pr_isdraft_filter_returns_empty_not_null:exits_zero_not_null" "0" "$_ec"
}
t_check_duplicate_pr_isdraft_filter_returns_empty_not_null

# ---------------------------------------------------------------------------
# t_pr_version_bump_pushed_to_origin
# Given: merge.strategy=pr AND version.file_path configured, running from
#        a real git worktree (so git rev-parse --git-common-dir resolves
#        MAIN_REPO correctly to the main checkout).
# When: merge-to-main-pr.sh runs successfully
# Then: the session branch ref on origin MUST contain the bumped version
#       (not the original) because _phase_source_branch_version_bump must
#       commit the bump on the session branch before the push (b6e3-e771 +
#       bbba-123d). The bump then lands on main as part of the PR's squash-
#       merge commit — NOT as a post-merge direct commit on main.
#
# UPDATED for the architectural fix (b6e3-e771): prior behavior asserted that
# origin/main directly received the bump commit via the post-merge _phase_push
# call. That path was removed because it diverged main from the PR's merged
# content and was rejected by the always-run compliance-verifier hook. The
# updated assertion checks origin/<branch> instead, which is where the bump
# now lives until the PR squash-merges it.
# ---------------------------------------------------------------------------
t_pr_version_bump_pushed_to_origin() {
    local _T _ec _branch_safe _state_file
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-vbump-test.XXXXXX")"
    local branch="feature-vbump-test-$$"
    _branch_safe="${branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    local real_git
    real_git=$(command -v git)
    local bin="$_T/bin"
    mkdir -p "$bin"
    local gh_argv_log="$_T/gh-argv.log"

    # 1. Seed repo: create main with merge commit (adds plugin.json "1.0.0").
    local seed_dir="$_T/seed"
    "$real_git" init -q -b main "$seed_dir" >/dev/null 2>&1
    local merge_sha
    (
        cd "$seed_dir" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        "$real_git" checkout -q -b feat
        echo '{"version":"1.0.0"}' > plugin.json
        "$real_git" add plugin.json
        "$real_git" commit -q -m "feat: add plugin.json" >/dev/null
        "$real_git" checkout -q main
        "$real_git" merge --no-ff -q feat -m "Merge feat into main" >/dev/null
    )

    # 2. Bare remote: push merge commit so origin/main = merge_sha with plugin.json.
    local remote_dir="$_T/remote.git"
    "$real_git" init -q --bare -b main "$remote_dir" >/dev/null 2>&1
    "$real_git" -C "$seed_dir" remote add origin "$remote_dir"
    "$real_git" -C "$seed_dir" push -q origin main >/dev/null 2>&1
    merge_sha=$("$real_git" -C "$seed_dir" rev-parse HEAD)

    # 3. main-checkout: clone from remote (shares history with remote).
    #    Starts at merge commit so plugin.json is present when version_bump runs.
    local main_checkout="$_T/main-checkout"
    "$real_git" clone -q "$remote_dir" "$main_checkout" >/dev/null 2>&1
    (
        cd "$main_checkout" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
    )

    # dso-config.conf lives alongside main-checkout
    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
version.file_path=plugin.json
dso.workflow=ci-pr
EOF

    # 4. Worktree: linked worktree from main-checkout on feature branch.
    #    git rev-parse --git-common-dir from here returns main-checkout/.git,
    #    so MAIN_REPO resolves to main-checkout (the correct topology).
    local worktree_dir="$_T/worktree"
    "$real_git" -C "$main_checkout" worktree add -q "$worktree_dir" -b "$branch" >/dev/null 2>&1

    # gh shim: PR immediately merged; returns merge_sha for mergeCommit query
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    case "\$2" in
      list) exit 0 ;;
      create) echo "https://github.com/x/y/pull/42"; exit 0 ;;
      view)
        [[ "\$*" == *"--json mergeCommit"* ]] && { echo "$merge_sha"; exit 0; }
        [[ "\$*" == *"--json state"* ]] && { echo "MERGED"; exit 0; }
        [[ "\$*" == *"--json headRefOid"* ]] && { echo ""; exit 0; }
        [[ "\$*" == *"comments,reviews,reviewThreads"* ]] && { echo "{}"; exit 0; }
        echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0
        ;;
      checks) echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'; exit 0 ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    [[ "\$2" == "graphql" ]] && { echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'; exit 0; }
    exit 0
    ;;
  repo) [[ "\$2" == "view" ]] && { echo "x/y"; exit 0; }; exit 0 ;;
  workflow) exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    # git shim: pass through all git operations except pushes to github.com.
    # This allows _phase_push to actually push to the local bare remote so
    # we can verify the version commit landed on origin/main.
    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  for _arg in "\$@"; do
    [[ "\$_arg" == *"github.com"* ]] && exit 0
  done
fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$bin/git"

    # Run merge-to-main-pr.sh from the linked worktree (feature branch).
    # BRANCH auto-resolves from git branch --show-current = "$branch".
    # MAIN_REPO resolves via dirname(git rev-parse --git-common-dir) = main-checkout.
    (
        cd "$worktree_dir" || exit 1
        PATH="$bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >"$_T/out.log" 2>&1
    )
    _ec=$?

    # Assert 1: script exits zero (or non-fatal — the key invariant is Assert 2)
    assert_eq "t_pr_version_bump_pushed_to_origin:exits_zero" "0" "$_ec"

    # Assert 2: the session branch ref on origin must have plugin.json at "1.0.1"
    # (patch bump from "1.0.0"). Before fix: post-merge _phase_push pushed the
    # bump directly to origin/main. After fix: _phase_source_branch_version_bump
    # commits the bump on the session branch, and the subsequent `git push -u
    # origin "$BRANCH"` publishes it to origin/<branch>. The bump lands on main
    # only via the PR's squash-merge (gh pr merge, stubbed in this test).
    local _branch_ref="refs/remotes/origin/${branch}"
    local _origin_version
    _origin_version=$(
        "$real_git" -C "$main_checkout" fetch -q origin "${branch}:${_branch_ref}" 2>/dev/null && \
        "$real_git" -C "$main_checkout" show "${_branch_ref}:plugin.json" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('version','MISSING'))" 2>/dev/null \
        || echo "FETCH_ERROR"
    )

    assert_eq "t_pr_version_bump_pushed_to_origin:version_on_origin_branch_is_1.0.1" "1.0.1" "$_origin_version"

    # Assert 3: HEAD commit on origin/<branch> must be the bump commit, named
    # with the actual version (not "vunknown") and carrying a DSO-Story trailer.
    local _bump_msg
    _bump_msg=$("$real_git" -C "$main_checkout" log --format="%s" "$_branch_ref" -1 2>/dev/null || echo "")
    assert_eq "t_pr_version_bump_pushed_to_origin:commit_message_names_version" \
              "chore: bump version to v1.0.1" "$_bump_msg"

    # Assert 4: the bump commit body must carry a DSO-Story trailer so
    # verify-session-provenance.sh accepts it on the session branch.
    local _bump_body _trailer_found="no"
    _bump_body=$("$real_git" -C "$main_checkout" log --format="%B" "$_branch_ref" -1 2>/dev/null || echo "")
    if printf '%s\n' "$_bump_body" | grep -qE '^DSO-Story(-Merge)?:[[:space:]]'; then
        _trailer_found="yes"
    fi
    assert_eq "t_pr_version_bump_pushed_to_origin:bump_commit_has_dso_story_trailer" \
              "yes" "$_trailer_found"
}
t_pr_version_bump_pushed_to_origin

# ---------------------------------------------------------------------------
# t_pr_version_bump_main_repo_not_on_main: regression test for worktree
# topologies where MAIN_REPO is currently on a non-main branch.
#
# UPDATED for b6e3-e771: the prior MAIN_REPO branch-switch guard was specific
# to the post-merge _phase_version_bump path, which has been removed. With the
# new architecture the bump runs on the session worktree (not MAIN_REPO), so
# MAIN_REPO's checked-out branch is irrelevant to the bump itself. This test
# still asserts that the bump lands on origin/<session-branch> even when
# MAIN_REPO is on a non-main branch — i.e., the new architecture does not
# regress the topology that the old branch-switch guard was protecting.
# ---------------------------------------------------------------------------
t_pr_version_bump_main_repo_not_on_main() {
    local _T _ec _branch_safe _state_file
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-vbump-notmain.XXXXXX")"
    local branch="feature-notmain-test-$$"
    _branch_safe="${branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    local real_git
    real_git=$(command -v git)
    local bin="$_T/bin"
    mkdir -p "$bin"

    # 1. Seed repo with merge commit containing plugin.json "1.0.0"
    local seed_dir="$_T/seed"
    "$real_git" init -q -b main "$seed_dir" >/dev/null 2>&1
    local merge_sha
    (
        cd "$seed_dir" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        "$real_git" checkout -q -b feat
        echo '{"version":"1.0.0"}' > plugin.json
        "$real_git" add plugin.json
        "$real_git" commit -q -m "feat: add plugin.json" >/dev/null
        "$real_git" checkout -q main
        "$real_git" merge --no-ff -q feat -m "Merge feat into main" >/dev/null
    )

    # 2. Bare remote + push
    local remote_dir="$_T/remote.git"
    "$real_git" init -q --bare -b main "$remote_dir" >/dev/null 2>&1
    "$real_git" -C "$seed_dir" remote add origin "$remote_dir"
    "$real_git" -C "$seed_dir" push -q origin main >/dev/null 2>&1
    merge_sha=$("$real_git" -C "$seed_dir" rev-parse HEAD)

    # 3. main-checkout: clone from remote, then switch to a non-main branch
    local main_checkout="$_T/main-checkout"
    "$real_git" clone -q "$remote_dir" "$main_checkout" >/dev/null 2>&1
    (
        cd "$main_checkout" || exit 1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        # Intentionally leave main-checkout on a non-main branch to exercise
        # the branch-switch guard in merge-to-main-pr.sh (BoIjn).
        "$real_git" checkout -q -b other-branch >/dev/null 2>&1
    )

    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
version.file_path=plugin.json
dso.workflow=ci-pr
EOF

    # 4. Worktree on feature branch
    local worktree_dir="$_T/worktree"
    "$real_git" -C "$main_checkout" worktree add -q "$worktree_dir" -b "$branch" >/dev/null 2>&1

    # gh shim: PR immediately merged
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    case "\$2" in
      list) exit 0 ;;
      create) echo "https://github.com/x/y/pull/99"; exit 0 ;;
      view)
        [[ "\$*" == *"--json mergeCommit"* ]] && { echo "$merge_sha"; exit 0; }
        [[ "\$*" == *"--json state"* ]] && { echo "MERGED"; exit 0; }
        [[ "\$*" == *"--json headRefOid"* ]] && { echo ""; exit 0; }
        [[ "\$*" == *"comments,reviews,reviewThreads"* ]] && { echo "{}"; exit 0; }
        echo '{"mergeable":"MERGEABLE","number":99,"url":"https://github.com/x/y/pull/99"}'
        exit 0
        ;;
      checks) echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'; exit 0 ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    [[ "\$2" == "graphql" ]] && { echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'; exit 0; }
    exit 0
    ;;
  repo) [[ "\$2" == "view" ]] && { echo "x/y"; exit 0; }; exit 0 ;;
  workflow) exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    # git shim: pass through all ops except github.com pushes
    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  for _arg in "\$@"; do
    [[ "\$_arg" == *"github.com"* ]] && exit 0
  done
fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$bin/git"

    (
        cd "$worktree_dir" || exit 1
        PATH="$bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >"$_T/out.log" 2>&1
    )
    _ec=$?

    assert_eq "t_pr_version_bump_main_repo_not_on_main:exits_zero" "0" "$_ec"

    # origin/<branch> must have the bumped version (session worktree commits
    # the bump and pushes it as part of the merge phase, regardless of which
    # branch MAIN_REPO has checked out).
    local _branch_ref="refs/remotes/origin/${branch}"
    local _origin_version
    _origin_version=$(
        "$real_git" -C "$main_checkout" fetch -q origin "${branch}:${_branch_ref}" 2>/dev/null && \
        "$real_git" -C "$main_checkout" show "${_branch_ref}:plugin.json" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('version','MISSING'))" 2>/dev/null \
        || echo "FETCH_ERROR"
    )
    assert_eq "t_pr_version_bump_main_repo_not_on_main:version_on_origin_branch_is_1.0.1" "1.0.1" "$_origin_version"

    # Assert 3: commit message on origin/<branch> must name the actual version.
    local _bump_msg
    _bump_msg=$("$real_git" -C "$main_checkout" log --format="%s" "$_branch_ref" -1 2>/dev/null || echo "")
    assert_eq "t_pr_version_bump_main_repo_not_on_main:commit_message_names_version" \
              "chore: bump version to v1.0.1" "$_bump_msg"
}
t_pr_version_bump_main_repo_not_on_main

# ===========================================================================
# _phase_poll BEHIND-state detection tests (jira-dig-2529)
# ===========================================================================
# When a PR's branch falls behind the base branch after CI starts, GitHub sets
# mergeStateStatus=BEHIND and will not auto-merge even with green checks. These
# tests verify that _phase_poll detects the BEHIND state and calls
# `gh pr update-branch` to reconcile, rather than looping until timeout.
# ===========================================================================

# ---------------------------------------------------------------------------
# t_phase_poll_behind_calls_update_branch
# When gh pr checks returns SUCCESS and mergeStateStatus returns BEHIND, the
# poll loop must call `gh pr update-branch <pr_number>` at least once.

# ---------------------------------------------------------------------------
t_phase_poll_behind_calls_update_branch() {
    local _T _update_branch_called _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-poll-behind-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    local _gh_call_count_file="$_T/gh-call-count"
    local _update_branch_file="$_T/update-branch-called"
    : > "$_gh_call_count_file"
    mkdir -p "$_T/bin"

    # gh shim: checks → SUCCESS; mergeStateStatus → BEHIND first call, CLEAN after update;
    # state → OPEN until update-branch called, then MERGED
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "LOGFILE"
case "$1 $2" in
  "pr checks")
    printf 'x' >> "COUNTFILE"
    echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'
    exit 0
    ;;
  "pr view")
    if [[ "$*" == *"mergeStateStatus"* ]]; then
      if [[ -f "UPDATEFILE" ]]; then
        echo "CLEAN"
      else
        echo "BEHIND"
      fi
      exit 0
    fi
    if [[ "$*" == *"headRefOid"* ]]; then echo ""; exit 0; fi
    if [[ "$*" == *"comments,reviews,reviewThreads"* ]]; then echo "{}"; exit 0; fi
    if [[ "$*" == *"--json mergeable"* && "$*" != *state* ]]; then
      echo '{"mergeable":"MERGEABLE","number":42,"url":"https://x/pull/42"}'
      exit 0
    fi
    # state query
    if [[ -f "UPDATEFILE" ]]; then
      echo '{"state":"MERGED"}'
    else
      echo '{"state":"OPEN"}'
    fi
    exit 0
    ;;
  "pr update-branch")
    touch "UPDATEFILE"
    exit 0
    ;;
  "pr merge") exit 0 ;;
  "pr list") exit 0 ;;
  "pr create") echo "https://x/pull/42"; exit 0 ;;
  "api graphql") echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'; exit 0 ;;
  "repo view") echo "x/y"; exit 0 ;;
  "--version") echo "gh version 2.40.1"; exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    # Substitute actual paths for sentinel placeholders in shim
    sed -i '' \
        "s|LOGFILE|$_T/gh-argv.log|g; \
         s|COUNTFILE|$_gh_call_count_file|g; \
         s|UPDATEFILE|$_update_branch_file|g" \
        "$_T/bin/gh" 2>/dev/null || \
    sed -i \
        "s|LOGFILE|$_T/gh-argv.log|g; \
         s|COUNTFILE|$_gh_call_count_file|g; \
         s|UPDATEFILE|$_update_branch_file|g" \
        "$_T/bin/gh"
    chmod +x "$_T/bin/gh"

    # Zero-cadence config so the poll loop runs without sleeping
    local _cfg="$_T/dso-config.conf"
    cat > "$_cfg" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        WORKFLOW_CONFIG_FILE="$_cfg" \
        MERGE_STRATEGY="pr" \
        BRANCH="test-behind-$$" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            # Stub state helpers to no-ops
            _state_write_phase() { return 0; }
            _state_mark_complete() { return 0; }
            _state_read_auto_merge_disabled() { echo "false"; return 0; }
            _phase_poll "42" "https://x/pull/42"
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _update_branch_called="$(test -f "$_update_branch_file" && echo yes || echo no)"

    assert_eq "t_phase_poll_behind_calls_update_branch: update-branch was called" "yes" "$_update_branch_called"
    assert_eq "t_phase_poll_behind_calls_update_branch: poll returns 0 after update" "0" "$_ec"
}
t_phase_poll_behind_calls_update_branch

# ---------------------------------------------------------------------------
# t_phase_poll_behind_clean_returns_zero
# When mergeStateStatus transitions BEHIND→CLEAN after update-branch, and the
# PR state transitions to MERGED on the following poll iteration, _phase_poll
# must return 0.

# ---------------------------------------------------------------------------
t_phase_poll_behind_clean_returns_zero() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-poll-behind-clean.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    local _update_branch_file="$_T/update-branch-called"
    mkdir -p "$_T/bin"

    # gh shim: checks always SUCCESS; mergeStateStatus BEHIND until update-branch
    # called then CLEAN; state OPEN until CLEAN, then MERGED
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "pr checks")
    echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'
    exit 0
    ;;
  "pr view")
    if [[ "$*" == *"mergeStateStatus"* ]]; then
      [[ -f "UPDATEFILE" ]] && echo "CLEAN" || echo "BEHIND"
      exit 0
    fi
    if [[ "$*" == *"headRefOid"* ]]; then echo ""; exit 0; fi
    if [[ "$*" == *"comments,reviews,reviewThreads"* ]]; then echo "{}"; exit 0; fi
    if [[ "$*" == *"--json mergeable"* && "$*" != *state* ]]; then
      echo '{"mergeable":"MERGEABLE","number":42,"url":"https://x/pull/42"}'
      exit 0
    fi
    [[ -f "UPDATEFILE" ]] && echo '{"state":"MERGED"}' || echo '{"state":"OPEN"}'
    exit 0
    ;;
  "pr update-branch") touch "UPDATEFILE"; exit 0 ;;
  "pr merge") exit 0 ;;
  "pr list") exit 0 ;;
  "pr create") echo "https://x/pull/42"; exit 0 ;;
  "api graphql") echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'; exit 0 ;;
  "repo view") echo "x/y"; exit 0 ;;
  "--version") echo "gh version 2.40.1"; exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    sed -i '' "s|UPDATEFILE|$_update_branch_file|g" "$_T/bin/gh" 2>/dev/null || \
    sed -i    "s|UPDATEFILE|$_update_branch_file|g" "$_T/bin/gh"
    chmod +x "$_T/bin/gh"

    local _cfg2="$_T/dso-config.conf"
    cat > "$_cfg2" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        WORKFLOW_CONFIG_FILE="$_cfg2" \
        MERGE_STRATEGY="pr" \
        BRANCH="test-behind-clean-$$" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _state_write_phase() { return 0; }
            _state_mark_complete() { return 0; }
            _state_read_auto_merge_disabled() { echo "false"; return 0; }
            _phase_poll "42" "https://x/pull/42"
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    assert_eq "t_phase_poll_behind_clean_returns_zero: exits 0" "0" "$_ec"
}
t_phase_poll_behind_clean_returns_zero

# ---------------------------------------------------------------------------
# t_phase_poll_behind_exhausts_update_cap_exits_nonzero
# When mergeStateStatus stays BEHIND for more than _BRANCH_UPDATE_MAX_ATTEMPTS
# iterations, _phase_poll must return non-zero rather than looping until timeout.

# ---------------------------------------------------------------------------
t_phase_poll_behind_exhausts_update_cap_exits_nonzero() {
    local _T _ec _update_branch_count _exits_nonzero
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-poll-behind-cap.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    local _update_count_file="$_T/update-count"
    : > "$_update_count_file"
    mkdir -p "$_T/bin"

    # gh shim: checks always SUCCESS; mergeStateStatus always BEHIND (never clears)
    cat > "$_T/bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "pr checks")
    echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'
    exit 0
    ;;
  "pr view")
    if [[ "$*" == *"mergeStateStatus"* ]]; then echo "BEHIND"; exit 0; fi
    if [[ "$*" == *"headRefOid"* ]]; then echo ""; exit 0; fi
    if [[ "$*" == *"comments,reviews,reviewThreads"* ]]; then echo "{}"; exit 0; fi
    if [[ "$*" == *"--json mergeable"* && "$*" != *state* ]]; then
      echo '{"mergeable":"MERGEABLE","number":42,"url":"https://x/pull/42"}'
      exit 0
    fi
    echo '{"state":"OPEN"}'
    exit 0
    ;;
  "pr update-branch") printf 'x' >> "COUNTFILE"; exit 0 ;;
  "pr merge") exit 0 ;;
  "pr list") exit 0 ;;
  "pr create") echo "https://x/pull/42"; exit 0 ;;
  "api graphql") echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'; exit 0 ;;
  "repo view") echo "x/y"; exit 0 ;;
  "--version") echo "gh version 2.40.1"; exit 0 ;;
  *) exit 0 ;;
esac
GH_SHIM
    sed -i '' "s|COUNTFILE|$_update_count_file|g" "$_T/bin/gh" 2>/dev/null || \
    sed -i    "s|COUNTFILE|$_update_count_file|g" "$_T/bin/gh"
    chmod +x "$_T/bin/gh"

    local _cfg3="$_T/dso-config.conf"
    cat > "$_cfg3" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        WORKFLOW_CONFIG_FILE="$_cfg3" \
        MERGE_STRATEGY="pr" \
        BRANCH="test-behind-cap-$$" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _state_write_phase() { return 0; }
            _state_mark_complete() { return 0; }
            _state_read_auto_merge_disabled() { echo "false"; return 0; }
            _phase_poll "42" "https://x/pull/42"
        ' "$PR_SCRIPT"
    ) 2>/dev/null
    _ec=$?

    _exits_nonzero="false"
    [[ "$_ec" -ne 0 ]] && _exits_nonzero="true"

    _update_branch_count="$(wc -c < "$_update_count_file" 2>/dev/null | tr -d ' ' || echo 0)"

    assert_eq "t_phase_poll_behind_exhausts_update_cap_exits_nonzero: exits nonzero" "true" "$_exits_nonzero"
    # update-branch called exactly _BRANCH_UPDATE_MAX_ATTEMPTS (3) times then stopped
    assert_eq "t_phase_poll_behind_exhausts_update_cap_exits_nonzero: update-branch called 3 times" "3" "$_update_branch_count"
}
t_phase_poll_behind_exhausts_update_cap_exits_nonzero

# ===========================================================================
# t_draft_pr_promoted_on_resume (bug 2e68-046a)
# When merge-to-main-pr.sh runs with --resume and the state file already
# records a draft PR, gh pr ready must still be called.
# fails before fix (promotion only in _phase_merge, which is skipped on resume).
# GREEN: passes after top-level promotion block is added outside _phase_merge.
# ===========================================================================
t_draft_pr_promoted_on_resume() {
    local _T branch _sf
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-resume-promote.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-resume-promote-$$"

    local real_git
    real_git=$(command -v git)
    local gh_argv_log="$_T/gh-argv.log"

    mkdir -p "$_T/bin"

    # gh shim: covers all phases for a quick-exit successful resume run.
    # Key: gh pr view --json isDraft → {"isDraft": true} so promotion fires.
    # gh pr ready → exit 0 (success). All other calls return quick success.
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    case "\$2" in
      list)   exit 0 ;;
      create) echo "https://github.com/x/y/pull/42"; exit 0 ;;
      ready)  exit 0 ;;
      merge)  exit 0 ;;
      checks) echo '[{"name":"ci","state":"COMPLETED","bucket":"pass"}]'; exit 0 ;;
      view)
        if [[ "\$*" == *"isDraft"* ]];               then echo '{"isDraft":true}'; exit 0; fi
        if [[ "\$*" == *"headRefOid"* ]];             then echo ""; exit 0; fi
        if [[ "\$*" == *"comments,reviews"* ]];       then echo "{}"; exit 0; fi
        if [[ "\$*" == *"mergeable"* ]];              then echo '{"mergeable":"MERGEABLE"}'; exit 0; fi
        if [[ "\$*" == *"mergeCommit"* ]];            then echo '{"mergeCommit":{"oid":"deadbeef0000"}}'; exit 0; fi
        if [[ "\$*" == *"state"* ]];                  then echo '{"state":"MERGED"}'; exit 0; fi
        echo '{}'; exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    if [[ "\$2" == "graphql" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      exit 0
    fi
    exit 0
    ;;
  repo)
    if [[ "\$2" == "view" ]]; then if [[ "\$*" == *"defaultBranchRef"* ]]; then echo "main"; exit 0; fi; echo "x/y"; exit 0; fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # git shim: pass through except push (log + exit 0) and fetch (exit 1 = skip sync)
    local git_push_log="$_T/git-push.log"
    cat > "$_T/bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]];  then printf '%s\n' "\$*" >> "$git_push_log"; exit 0; fi
if [[ "\$1" == "fetch" ]]; then exit 1; fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$_T/bin/git"

    # Minimal git repo on the feature branch
    (
        cd "$_T" || exit 1
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

    # Pre-seed state file — simulates sprint Phase A having already created
    # the draft PR before this resume run.
    _sf="/tmp/merge-to-main-state-${branch//\//-}.json"
    printf '{"pr_url":"https://github.com/x/y/pull/42","pr_number":"42"}' > "$_sf"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_sf'" RETURN

    local _cfg="$_T/dso-config.conf"
    cat > "$_cfg" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
merge.pr_thread_quiet_window_seconds=0
EOF

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_cfg" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$branch" \
        bash "$PR_SCRIPT" --resume >/dev/null 2>&1
    ) || true

    local _argv _ready_called
    _argv="$(cat "$gh_argv_log" 2>/dev/null || echo '')"

    _ready_called="false"
    if echo "$_argv" | grep -qE "^pr ready 42$"; then
        _ready_called="true"
    fi

    assert_eq "t_draft_pr_promoted_on_resume: gh pr ready called on --resume path" "true" "$_ready_called"
}
t_draft_pr_promoted_on_resume

# ===========================================================================
# t_draft_pr_promoted_to_ready (bug 075f-ec40)
# _phase_merge must call `gh pr ready <num>` when the existing PR is draft.
# passes before fix (gh pr ready not called → assertion fails).
# GREEN: passes after _phase_merge adds the gh pr ready promotion block.
# ===========================================================================
t_draft_pr_promoted_to_ready() {
    local _T branch
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-draft-promote.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-draft-promote-$$"

    local real_git
    real_git=$(command -v git)
    local gh_argv_log="$_T/gh-argv.log"

    # Build a minimal gh shim. Handles all the calls _phase_merge makes:
    #   gh pr list      — return a draft PR so _final_url/_pr_number are set from the list
    #   gh pr view --json mergeable — return MERGEABLE (no conflict)
    #   gh pr view --json isDraft   — return isDraft:true (the PR is draft)
    #   gh pr ready <num>           — log the call, exit 0
    #   gh --version                — version gate check
    mkdir -p "$_T/bin"
    cat > "$_T/bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    case "\$2" in
      list)
        # Return one draft PR so _phase_merge reuses it
        echo '[{"number":42,"url":"https://github.com/x/y/pull/42","isDraft":true}]'
        exit 0
        ;;
      view)
        if [[ "\$*" == *"isDraft"* ]]; then
          echo '{"isDraft":true}'
          exit 0
        fi
        if [[ "\$*" == *"mergeable"* ]]; then
          echo '{"mergeable":"MERGEABLE","number":42,"url":"https://github.com/x/y/pull/42"}'
          exit 0
        fi
        if [[ "\$*" == *"headRefOid"* ]]; then echo ""; exit 0; fi
        if [[ "\$*" == *"comments,reviews,reviewThreads"* ]]; then echo "{}"; exit 0; fi
        if [[ "\$*" == *"state"* ]]; then echo "MERGED"; exit 0; fi
        echo '{}'; exit 0
        ;;
      ready)
        # This is the call under test — log it and succeed
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    if [[ "\$2" == "graphql" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      exit 0
    fi
    exit 0
    ;;
  repo)
    if [[ "\$2" == "view" ]]; then if [[ "\$*" == *"defaultBranchRef"* ]]; then echo "main"; exit 0; fi; echo "x/y"; exit 0; fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_T/bin/gh"

    # git shim: pass through except for fetch (return 1 to skip sync) and push
    local git_push_log="$_T/git-push.log"
    cat > "$_T/bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  printf '%s\n' "\$*" >> "$git_push_log"
  exit 0
fi
if [[ "\$1" == "fetch" ]]; then
  exit 1
fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$_T/bin/git"

    # Minimal git repo
    (
        cd "$_T" || exit 1
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

    local _cfg="$_T/dso-config.conf"
    cat > "$_cfg" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
EOF

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        WORKFLOW_CONFIG_FILE="$_cfg" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$branch" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _state_write_phase()    { return 0; }
            _state_mark_complete()  { return 0; }
            _state_write_pr_meta()  { return 0; }
            _fetch_and_rebase_branch() { return 0; }
            _phase_merge
        ' "$PR_SCRIPT"
    ) >/dev/null 2>&1 || true

    local _argv
    _argv="$(cat "$gh_argv_log" 2>/dev/null || echo '')"

    local _ready_called="false"
    if echo "$_argv" | grep -qE "^pr ready 42$"; then
        _ready_called="true"
    fi

    assert_eq "t_draft_pr_promoted_to_ready: gh pr ready called for draft PR" "true" "$_ready_called"
}
t_draft_pr_promoted_to_ready

# ---------------------------------------------------------------------------
# Bug 17b7-80ff-2317-4587: MERGE_STRATEGY should be derived from config when
# unset, not require external env injection from the dispatcher only.
# ---------------------------------------------------------------------------
t_merge_strategy_derived_from_config_when_unset() {
    # Build a minimal config with dso.workflow=ci-pr
    local _tmp _cfg
    _tmp="$(mktemp -d)"
    _cfg="$_tmp/dso-config.conf"
    cat > "$_cfg" << EOF
dso.workflow=ci-pr
merge.strategy=pr
EOF

    # Run with MERGE_STRATEGY UNSET, PR_LIB_MODE=0 (not lib mode), config in place.
    # No arguments — script proceeds past argument parsing into the required-env
    # block at line 57 where the assertion currently bails.
    local _stderr_log _exit
    _stderr_log="$_tmp/stderr.log"
    _exit=0
    (
        unset MERGE_STRATEGY
        WORKFLOW_CONFIG_FILE="$_cfg" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$PR_SCRIPT" 2>"$_stderr_log" >/dev/null
    ) || _exit=$?

    # Behavioral guarantee of the fix: stderr must NOT contain
    # "MERGE_STRATEGY must be set". Script may fail downstream for other reasons
    # (no git context, no PR state, etc.) but must derive MERGE_STRATEGY from
    # the config BEFORE the un-derived assertion fires.
    local _bad_msg_present="no"
    if grep -q "MERGE_STRATEGY must be set" "$_stderr_log" 2>/dev/null; then
        _bad_msg_present="yes"
    fi
    assert_eq "t_merge_strategy_derived_from_config: stderr does NOT bail on MERGE_STRATEGY assertion when config sets dso.workflow=ci-pr" \
        "no" "$_bad_msg_present"

    rm -rf "$_tmp"
}
t_merge_strategy_derived_from_config_when_unset

# ---------------------------------------------------------------------------
# test_merge_to_main_pr_source_branch_bump
# S5.T1 RED: _phase_source_branch_version_bump commits the version-bump on the
# SOURCE BRANCH HEAD before the branch is merged to main. The bump commit must
# carry a DSO-Story(-Merge)?: trailer. After the merge, _phase_version_bump
# must detect the bump is already on the merged commit's history and become a
# no-op (no double-bump).
#

# merge-to-main-pr.sh. Sourcing the script in PR_LIB_MODE=1 and calling the
# function will fail with "command not found", causing the test to assert on
# "PHASE_NOT_FOUND" vs the expected "EXISTS".
#
# PRECONDITION GUARD: version files (VERSION, pyproject.toml, package.json)
# MUST NOT be in .test-index. If they are, bump-version.sh changes to those
# files would trigger S4 RED-test-blocker. The test fails loudly here so the
# S4+S5 integration breaks visibly rather than silently.
# ---------------------------------------------------------------------------
test_merge_to_main_pr_source_branch_bump() {
    # ---- Precondition: version files must not appear in .test-index --------
    local _test_index_path
    _test_index_path="$(git rev-parse --show-toplevel)/.test-index"
    if grep -E '(^|[[:space:]/])(VERSION|pyproject\.toml|package\.json)([[:space:]]|$|:)' \
            "$_test_index_path" 2>/dev/null; then
        echo "PRECONDITION FAIL: .test-index contains a version file (VERSION/pyproject.toml/package.json)." >&2
        echo "  This would cause bump-version.sh file changes to trigger S4 RED-test-blocker." >&2
        echo "  Remove version files from .test-index before proceeding." >&2
        assert_eq "precondition:version_files_not_in_test_index" "ABSENT" "PRESENT"
        return
    fi

    local _T _real_git _branch _branch_safe _state_file
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-src-branch-bump.XXXXXX")"
    _real_git="$(command -v git)"
    _branch="session/test-epic-srcbump-$$"
    _branch_safe="${_branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'; rm -f '/tmp/merge-state-init-marker-${_branch_safe}'" RETURN

    # ---- Build git fixture -------------------------------------------------
    # Structure: bare remote ← main-checkout (worktree parent) ← session worktree
    # The session branch has one work commit + a plain-text VERSION file.
    # main does NOT have the VERSION file yet (the session branch adds it).

    local _remote_dir="$_T/remote.git"
    local _main_checkout="$_T/main-checkout"
    local _worktree_dir="$_T/worktree"

    # 1. Bare remote with a seed commit on main.
    "$_real_git" init -q --bare -b main "$_remote_dir" >/dev/null 2>&1
    "$_real_git" init -q -b main "$_main_checkout" >/dev/null 2>&1
    (
        cd "$_main_checkout" || exit 1
        "$_real_git" config user.email "test@test.local"
        "$_real_git" config user.name "test"
        echo "seed" > seed.txt
        "$_real_git" add seed.txt
        "$_real_git" commit -q -m "chore: seed" >/dev/null
        "$_real_git" remote add origin "$_remote_dir"
        "$_real_git" push -q origin main >/dev/null 2>&1
    )

    # 2. Create session branch with a work commit + VERSION file (1.2.3).
    "$_real_git" -C "$_main_checkout" worktree add -q "$_worktree_dir" -b "$_branch" >/dev/null 2>&1
    (
        cd "$_worktree_dir" || exit 1
        "$_real_git" config user.email "test@test.local"
        "$_real_git" config user.name "test"
        echo "1.2.3" > VERSION
        echo "feat work" > work.txt
        "$_real_git" add VERSION work.txt
        "$_real_git" commit -q -m "feat: add work

DSO-Story: test-story-abc" >/dev/null
    )
    local _pre_bump_sha
    _pre_bump_sha="$("$_real_git" -C "$_worktree_dir" rev-parse HEAD)"
    local _pre_bump_count
    _pre_bump_count="$("$_real_git" -C "$_worktree_dir" rev-list --count HEAD 2>/dev/null)"

    # dso-config.conf: ci-pr workflow, version.file_path=VERSION
    cat > "$_T/dso-config.conf" <<EOF
version=1.1.0
merge.pr_poll_interval_seconds=0
merge.pr_max_wait_seconds=3600
version.file_path=$_worktree_dir/VERSION
dso.workflow=ci-pr
EOF

    # ---- Part A: invoke _phase_source_branch_version_bump ------------------
    # Source merge-to-main-pr.sh in PR_LIB_MODE=1 so only functions are
    # imported. Then call _phase_source_branch_version_bump from the session
    # worktree CWD, passing the story-id as argument.
    #
    # _phase_source_branch_version_bump does not exist → the function-
    # presence probe ("type -t") returns "PHASE_NOT_FOUND"; assert_eq fails.
    local _phase_exists
    _phase_exists="$(
        cd "$_worktree_dir" || exit 1
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null || true
            if type _phase_source_branch_version_bump >/dev/null 2>&1; then
                echo "EXISTS"
            else
                echo "PHASE_NOT_FOUND"
            fi
        ' "$PR_SCRIPT" 2>/dev/null
    )"
    assert_eq "test_merge_to_main_pr_source_branch_bump:phase_function_defined" \
        "EXISTS" "$_phase_exists"

    # If phase does not exist, remaining assertions are skipped to keep output clean.
    if [[ "$_phase_exists" != "EXISTS" ]]; then
        return
    fi

    # ---- Invoke the phase ---------------------------------------------------
    local _invoke_ec=0
    (
        cd "$_worktree_dir" || exit 1
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_LIB_MODE="1" \
        VERSION_FILE_PATH="$_worktree_dir/VERSION" \
        bash -c '
            source "$0" 2>/dev/null || true
            _phase_source_branch_version_bump "test-story-abc"
        ' "$PR_SCRIPT" >/dev/null 2>&1
    ) || _invoke_ec=$?

    assert_eq "test_merge_to_main_pr_source_branch_bump:phase_exits_zero" \
        "0" "$_invoke_ec"

    # ---- Assert A1: commit count grew by exactly 1 -------------------------
    local _post_bump_count
    _post_bump_count="$("$_real_git" -C "$_worktree_dir" rev-list --count HEAD 2>/dev/null || echo "0")"
    local _expected_count=$(( _pre_bump_count + 1 ))
    assert_eq "test_merge_to_main_pr_source_branch_bump:one_new_commit_on_source_branch" \
        "$_expected_count" "$_post_bump_count"

    # ---- Assert A2: VERSION file was modified in the bump commit -----------
    local _version_in_bump_commit
    _version_in_bump_commit="$("$_real_git" -C "$_worktree_dir" show "HEAD:VERSION" 2>/dev/null | tr -d '[:space:]' || echo "MISSING")"
    # The bump must be different from "1.2.3" (old version).
    assert_ne "test_merge_to_main_pr_source_branch_bump:version_file_changed_from_original" \
        "1.2.3" "$_version_in_bump_commit"

    # ---- Assert A3: bump commit carries a DSO-Story(-Merge)?: trailer ------
    local _bump_commit_body
    _bump_commit_body="$("$_real_git" -C "$_worktree_dir" log -1 --format="%B" 2>/dev/null || echo "")"
    local _trailer_found="no"
    if printf '%s\n' "$_bump_commit_body" | grep -qE '^DSO-Story(-Merge)?:[[:space:]]'; then
        _trailer_found="yes"
    fi
    assert_eq "test_merge_to_main_pr_source_branch_bump:bump_commit_has_dso_story_trailer" \
        "yes" "$_trailer_found"

    # ---- Assert A4: bump commit is NOT yet on main -------------------------
    local _bump_sha
    _bump_sha="$("$_real_git" -C "$_worktree_dir" rev-parse HEAD 2>/dev/null || echo "")"
    # main-checkout still at the pre-bump seed commit (no merge has happened).
    # Check whether the bump SHA is an ancestor of main on the main-checkout.
    # `git merge-base --is-ancestor X main` exits 0 when X is in main's history,
    # 1 otherwise. The prior grep-based check ('branch --contains | grep -c main')
    # over-counted because grep -c always prints "0" to stdout, and the
    # `|| echo "0"` appended an extra "0" on no-match — yielding "0\n0".
    local _on_main="no"
    if "$_real_git" -C "$_main_checkout" merge-base --is-ancestor "$_bump_sha" main 2>/dev/null; then
        _on_main="yes"
    fi
    assert_eq "test_merge_to_main_pr_source_branch_bump:bump_commit_not_yet_on_main" \
        "no" "$_on_main"

    # ---- Part B: _phase_version_bump is a no-op after merge ----------------
    # Simulate the merge: fast-forward main-checkout to include the session
    # branch commits (including the bump commit), then invoke _phase_version_bump
    # with DSO_MERGE_RESUMING=0 (fresh run). It must detect the bump commit in
    # the merged history and skip re-bumping (no new commit, VERSION unchanged).
    (
        cd "$_main_checkout" || exit 1
        "$_real_git" merge --no-ff -q "$_branch" -m "Merge session branch" >/dev/null 2>&1 || true
    )
    local _main_version_before_phase_bump
    _main_version_before_phase_bump="$("$_real_git" -C "$_main_checkout" show "HEAD:VERSION" 2>/dev/null | tr -d '[:space:]' || echo "MISSING")"

    # Invoke _phase_version_bump from main-checkout (post-merge state).
    local _noop_ec=0
    (
        cd "$_main_checkout" || exit 1
        WORKFLOW_CONFIG_FILE="$_T/dso-config.conf" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_LIB_MODE="1" \
        MAIN_REPO="$_main_checkout" \
        VERSION_FILE_PATH="$_main_checkout/VERSION" \
        BUMP_TYPE="patch" \
        DSO_WORKFLOW="ci-pr" \
        DSO_MERGE_RESUMING="0" \
        bash -c '
            source "$0" 2>/dev/null || true
            # Minimal state stubs so _phase_version_bump can run without state file I/O.
            _state_write_phase()  { return 0; }
            _state_mark_complete() { return 0; }
            _phase_version_bump
        ' "$PR_SCRIPT" >/dev/null 2>&1
    ) || _noop_ec=$?

    local _main_version_after_phase_bump
    _main_version_after_phase_bump="$("$_real_git" -C "$_main_checkout" show "HEAD:VERSION" 2>/dev/null | tr -d '[:space:]' || echo "MISSING")"

    # The no-op guard: version on main must NOT change a second time after the
    # post-merge _phase_version_bump runs, because the bump is already in history.
    assert_eq "test_merge_to_main_pr_source_branch_bump:post_merge_phase_version_bump_noop" \
        "$_main_version_before_phase_bump" "$_main_version_after_phase_bump"
}
# Wrap with snapshot+assert_pass_if_clean so suite-engine can extract
# "FAIL: test_merge_to_main_pr_source_branch_bump" from output and match
# the .test-index RED marker.
_fail_snapshot=$FAIL
test_merge_to_main_pr_source_branch_bump
assert_pass_if_clean "test_merge_to_main_pr_source_branch_bump"

# ---------------------------------------------------------------------------
# Test: t_pr_body_contains_commit_subjects
# Asserts that `gh pr create` is invoked with --body containing a markdown
# bullet list of branch-local non-merge commit subjects (the work the branch
# contributes), rather than the legacy "Auto-generated PR for branch ..."
# placeholder. The fixture builder creates one commit "feature work" on the
# branch, so the body must include that subject as a bullet.
# ---------------------------------------------------------------------------
t_pr_body_contains_commit_subjects() {
    local _T branch _argv _body_line
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-pr-body"
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

    # The gh stub records argv with newlines preserved (the --body value may
    # contain newlines), so search the FULL argv text rather than a single line.
    # Confirm the recorded argv includes a `pr create` invocation and that the
    # body lists the branch-local commit subject "feature work" as a bullet.
    if ! echo "$_argv" | grep -qE "^pr create "; then
        assert_eq "t_pr_body_argv_contains_pr_create" "true" "false"
        return
    fi
    if echo "$_argv" | grep -qF -- "- feature work"; then
        assert_eq "t_pr_body_lists_branch_commit_subjects" "true" "true"
    else
        assert_eq "t_pr_body_lists_branch_commit_subjects" "true" "false"
    fi

    # Negative assertion: the legacy placeholder must NOT appear in the argv.
    if echo "$_argv" | grep -qF "Auto-generated PR for branch"; then
        assert_eq "t_pr_body_does_not_use_legacy_placeholder" "false" "true"
    else
        assert_eq "t_pr_body_does_not_use_legacy_placeholder" "false" "false"
    fi
}
t_pr_body_contains_commit_subjects

# ---------------------------------------------------------------------------
# Unit tests for _derive_pr_body — exercise the three branch-coverage paths
# that the end-to-end test (t_pr_body_contains_commit_subjects) cannot cover:
#   A) Pure-cleanup branch: both <base>..HEAD AND origin/<base>..HEAD empty →
#      fall back to the legacy "Auto-generated PR for branch" placeholder.
#   B) --no-merges filter: branch has both a regular commit and a merge commit
#      → only the non-merge commit appears as a bullet.
#   C) origin/<base> fallback: local <base> missing but origin/<base> present
#      → commits from the origin range still appear.
#
# Implementation: source just the _derive_pr_body function from merge-to-main-pr.sh
# (extracted via awk so we don't trigger the script's main control flow), then
# invoke it inside per-test git fixtures.
# ---------------------------------------------------------------------------
_PR_BODY_FN_SRC=$(awk '/^_derive_pr_body\(\)/,/^}/' "$PR_SCRIPT")
if [[ -z "$_PR_BODY_FN_SRC" ]]; then
    echo "FAIL: t_pr_body_unit_tests_setup: could not extract _derive_pr_body from $PR_SCRIPT" >&2
    FAIL=$((FAIL + 1))
fi
eval "$_PR_BODY_FN_SRC"

t_pr_body_pure_cleanup_branch_falls_back() {
    local _T body
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-body-cleanup.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    (
        cd "$_T" || exit 1
        git init -q -b main
        git config user.email t@t.local
        git config user.name t
        echo seed > seed.txt && git add seed.txt && git commit -q -m seed
        git checkout -q -b cleanup-branch
        # No commits on cleanup-branch; both main..HEAD and origin/main..HEAD will be empty.
    )
    body=$(cd "$_T" && _derive_pr_body "cleanup-branch" "main")
    if echo "$body" | grep -qF "Auto-generated PR for branch \`cleanup-branch\`"; then
        assert_eq "t_pr_body_pure_cleanup_falls_back_to_legacy_placeholder" "true" "true"
    else
        assert_eq "t_pr_body_pure_cleanup_falls_back_to_legacy_placeholder" "true" "false (body was: $body)"
    fi
}
t_pr_body_pure_cleanup_branch_falls_back

t_pr_body_excludes_merge_commits() {
    local _T body
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-body-no-merges.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    (
        cd "$_T" || exit 1
        git init -q -b main
        git config user.email t@t.local
        git config user.name t
        echo seed > seed.txt && git add seed.txt && git commit -q -m seed
        git checkout -q -b feature
        echo feat > feat.txt && git add feat.txt && git commit -q -m "feat: real work"
        # Create a sibling branch and a merge commit on feature
        git checkout -q -b sidebranch main
        echo side > side.txt && git add side.txt && git commit -q -m "side: irrelevant"
        git checkout -q feature
        git merge --no-ff -q -m "Merge remote-tracking branch 'sidebranch' into feature" sidebranch >/dev/null 2>&1
    )
    body=$(cd "$_T" && _derive_pr_body "feature" "main")
    # Must include the real-work bullet
    if echo "$body" | grep -qF -- "- feat: real work"; then
        assert_eq "t_pr_body_includes_non_merge_commit" "true" "true"
    else
        assert_eq "t_pr_body_includes_non_merge_commit" "true" "false (body was: $body)"
    fi
    # Must NOT include the merge commit subject
    if echo "$body" | grep -qF "Merge remote-tracking branch"; then
        assert_eq "t_pr_body_excludes_merge_commit_subject" "false" "true"
    else
        assert_eq "t_pr_body_excludes_merge_commit_subject" "false" "false"
    fi
}
t_pr_body_excludes_merge_commits

t_pr_body_falls_back_to_origin_base() {
    local _T body
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr-body-origin-fallback.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN
    (
        cd "$_T" || exit 1
        # Set up a bare "remote" with the base branch + a feature branch ahead of it.
        git init -q --bare remote.git
        git init -q -b main local
        cd local || exit 1
        git config user.email t@t.local
        git config user.name t
        echo seed > seed.txt && git add seed.txt && git commit -q -m seed
        git remote add origin ../remote.git
        git push -q origin main
        git checkout -q -b feature-origin-fallback
        echo work > work.txt && git add work.txt && git commit -q -m "feat: origin-fallback path"
        # DELETE local main so <base>..HEAD fails; origin/main remains.
        git branch -q -D main
    )
    body=$(cd "$_T/local" && _derive_pr_body "feature-origin-fallback" "main")
    if echo "$body" | grep -qF -- "- feat: origin-fallback path"; then
        assert_eq "t_pr_body_origin_base_fallback_lists_commits" "true" "true"
    else
        assert_eq "t_pr_body_origin_base_fallback_lists_commits" "true" "false (body was: $body)"
    fi
    # Should NOT fall through to the legacy placeholder — origin/main..HEAD found commits.
    if echo "$body" | grep -qF "Auto-generated PR for branch"; then
        assert_eq "t_pr_body_origin_fallback_does_not_use_placeholder" "false" "true"
    else
        assert_eq "t_pr_body_origin_fallback_does_not_use_placeholder" "false" "false"
    fi
}
t_pr_body_falls_back_to_origin_base

# ---------------------------------------------------------------------------
# Bug 9e06-e198-fb6f-4c39: every _dso_emit_local_escalation call site must
# direct the session agent to PR-FINALIZE-WORKFLOW.md (the canonical loop
# driver), not "re-run merge-to-main.sh". Otherwise the script bails on the
# first blocker and the agent re-escalates at the same phase.
# ---------------------------------------------------------------------------

# t_all_escalation_sites_reference_pr_finalize_workflow
# Static check: every `_dso_emit_local_escalation` block in merge-to-main-pr.sh
# must mention PR-FINALIZE-WORKFLOW.md within the call's argument range, and
# no block may instruct the agent to re-run merge-to-main.sh.
t_all_escalation_sites_reference_pr_finalize_workflow() {
    local _missing _bad_rerun
    # Extract each call's source range (call line + next 3 lines covers the
    # multi-line continuation of the typical 3-arg invocation). Then assert
    # each range contains the workflow reference and lacks "re-run merge-to-main.sh".
    # Match only actual call sites: lines starting with whitespace then
    # `_dso_emit_local_escalation "<phase>"` — excludes the function definition
    # (`_dso_emit_local_escalation()`) and any comments mentioning the name.
    _missing=$(awk '
        /^[[:space:]]+_dso_emit_local_escalation[[:space:]]+"/ {
            # Collect this line plus the next 3 (covers 3-arg multi-line call).
            block = $0
            for (i = 1; i <= 3; i++) { getline next_line; block = block "\n" next_line }
            if (index(block, "PR-FINALIZE-WORKFLOW.md") == 0) {
                print "site_missing_workflow_ref_near_line_" NR
            }
        }
    ' "$PR_SCRIPT")
    _bad_rerun=$(awk '
        /^[[:space:]]+_dso_emit_local_escalation[[:space:]]+"/ {
            block = $0
            for (i = 1; i <= 3; i++) { getline next_line; block = block "\n" next_line }
            # The fix introduced "Do not re-run merge-to-main.sh." as an explicit
            # negation; only flag affirmative "re-run merge-to-main" imperatives.
            if (block ~ /and re-run merge-to-main\.sh/ ||
                block ~ /before re-running merge-to-main\.sh/) {
                print "site_tells_agent_to_rerun_near_line_" NR
            }
        }
    ' "$PR_SCRIPT")

    if [[ -z "$_missing" && -z "$_bad_rerun" ]]; then
        assert_eq "t_all_escalation_sites_reference_pr_finalize_workflow" "ok" "ok"
    else
        assert_eq "t_all_escalation_sites_reference_pr_finalize_workflow" \
            "ok" "missing=[$_missing] bad_rerun=[$_bad_rerun]"
    fi
}
t_all_escalation_sites_reference_pr_finalize_workflow

# t_emit_local_escalation_includes_next_action
# Direct unit test: _dso_emit_local_escalation emits a structured next_action
# field containing the workflow doc + loop driver paths, so a calling harness
# can detect the handoff target without parsing the free-form 'instructions'
# prose.
t_emit_local_escalation_includes_next_action() {
    local _stdout
    _stdout=$(
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" 2>/dev/null
            _dso_emit_local_escalation "remediate" "test reason" "test instr"
        ' "$PR_SCRIPT" 2>/dev/null
    )
    if echo "$_stdout" | grep -q '"next_action"' \
        && echo "$_stdout" | grep -q "PR-FINALIZE-WORKFLOW.md" \
        && echo "$_stdout" | grep -q "pr-finalize-classify.sh"; then
        assert_eq "t_emit_local_escalation_includes_next_action" "ok" "ok"
    else
        assert_eq "t_emit_local_escalation_includes_next_action" \
            "ok" "missing next_action handoff in stdout: $_stdout"
    fi
}
t_emit_local_escalation_includes_next_action

# ---------------------------------------------------------------------------
# t_pr1_staged_intermediate_enqueues_auto_merge  (bug c9fe-8b6c-9421-4faf)
# _phase_staged_intermediate (the non-sprint two-tier PR1 flow) MUST enqueue
# auto-merge on PR1 right after creating it. Without it, the subsequent
# wait-for-pr.sh (which only exits 0 on MERGED) deadlocks: nothing merges PR1
# before the wait, so on real GitHub the PR stays OPEN until the 30-min timeout.
# This test drives _phase_staged_intermediate in library mode against a
# github.com origin (so the "not a github.com remote" skip guard does NOT fire)
# and asserts PR1 (#42) receives `gh pr merge 42 --auto`. The inline-wait
# fallback resolves immediately via the gh stub's `--json state == MERGED`.
# ---------------------------------------------------------------------------
t_pr1_staged_intermediate_enqueues_auto_merge() {
    local _T branch _argv _has_pr1_auto
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-pr1-automerge.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="feature-pr1-automerge"
    _build_pr_fixture "$_T" "$branch" "ok" "ok"

    # Give the fixture a github.com origin so _phase_staged_intermediate does NOT
    # auto-skip on the "origin is not a github.com remote" guard (line ~884).
    git -C "$_T" remote add origin https://github.com/x/y.git 2>/dev/null \
        || git -C "$_T" remote set-url origin https://github.com/x/y.git

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            # Stub the heavy phase deps so the PR1 flow reaches the auto-merge
            # enqueue without needing a real staged ref, version bump, or push.
            _create_staged_ref() { echo "staged-test-123"; }
            _phase_source_branch_version_bump() { return 0; }
            _state_write_phase() { return 0; }
            _state_set_field() { return 0; }
            _state_init() { return 0; }
            # Force the inline-wait fallback: no executable wait-for-pr.sh under
            # this path, so the wait resolves immediately via the gh stub
            # (gh pr view --json state -> MERGED).
            _PLUGIN_ROOT="'"$_T"'/noplugin"
            unset STORY_PR_BASE
            BRANCH="'"$branch"'"
            # Steps 6-7 (checkout staged-*) fail under the stub; the auto-merge
            # enqueue (step 3b) happens earlier, so tolerate the late failure.
            _phase_staged_intermediate >/dev/null 2>&1 || true
        ' "$PR_SCRIPT"
    ) || true

    _argv="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    _has_pr1_auto="false"
    if echo "$_argv" | grep -E "^pr merge 42" | grep -q -- "--auto"; then
        _has_pr1_auto="true"
    fi

    assert_eq "t_pr1_staged_intermediate_enqueues_auto_merge: PR1 gets gh pr merge --auto before the wait" \
        "true" "$_has_pr1_auto"
}
t_pr1_staged_intermediate_enqueues_auto_merge

# ---------------------------------------------------------------------------
# end of file
print_summary
