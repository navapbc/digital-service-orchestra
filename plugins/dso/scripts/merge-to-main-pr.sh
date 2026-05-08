#!/usr/bin/env bash
# merge-to-main-pr.sh — PR merge mode (skeleton).
#
# Skeleton implementation that satisfies:
#   * gh CLI version gate (requires >= 2.0.0 for GraphQL features used by
#     downstream PR-create logic in Task 3 — DD7).
#   * Duplicate-PR guard: refuse to run when an open PR already exists for
#     the current branch (DD4).
#   * CONFLICT_DATA contract parity with merge-to-main-direct.sh: when the
#     (placeholder) merge phase fails, emit the same JSON line via the
#     shared _emit_conflict_data helper in merge-helpers.sh (DD6 — PR side).
#
# Full PR-creation flow (gh pr create, auto-merge enable, status polling)
# lands in Task 3. This skeleton makes the T1 dispatcher routing and PR
# CONFLICT_DATA tests turn GREEN without committing to that flow yet.
#
# Usage: merge-to-main-pr.sh [--resume|--help]
# Exit codes: 0=success, 1=error
set -euo pipefail

# Require bash 4.3+ for nameref support (local -n used in helper functions)
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 3 ]]; }; then
    echo "ERROR: merge-to-main-pr.sh requires bash 4.3+ (current: ${BASH_VERSION})" >&2
    exit 1
fi

# --- CLI: --resume / --help argv parsing (early — before any context checks) ---
_RESUME=0
for _arg in "$@"; do
    case "$_arg" in
        --help)
            cat <<'USAGE'
Usage: merge-to-main-pr.sh [--resume|--help]

  --resume        Resume from last incomplete phase (state file in /tmp).
                  Skips _check_duplicate_pr and _phase_merge when the state
                  file already records a pr_url (i.e. PR was created in a
                  prior run); jumps directly to the polling phase.
  --help          Print this usage message and exit.

  (no args)       Run all phases sequentially.

PR mode creates a pull request against main, enables auto-merge, and waits
for required status checks to pass. Requires gh CLI 2.0.0+ for GraphQL.
USAGE
            exit 0
            ;;
        --resume)
            _RESUME=1
            ;;
    esac
done

# --- Required env vars (set by the dispatcher) ---
: "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set}"
if [[ "${PR_LIB_MODE:-0}" != "1" ]]; then
    : "${MERGE_STRATEGY:?MERGE_STRATEGY must be set (expected: pr)}"
fi

# --- Resolve repo root (best-effort; PR mode can run outside a git repo for
# certain failure paths in skeleton form, but most production paths require it). ---
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [[ -n "$REPO_ROOT" ]]; then
    cd "$REPO_ROOT"
fi

# --- Resolve current branch (best-effort) ---
# Falls back to "unknown" outside a git repo so downstream helpers (e.g.,
# _emit_conflict_data, _state_init) still receive a non-empty value.
# Honor BRANCH if already set (e.g., injected by tests or the dispatcher).
BRANCH="${BRANCH:-$(git branch --show-current 2>/dev/null || true)}"
BRANCH="${BRANCH:-unknown}"

# --- Load merge utility helpers (state file, lock, recovery, CONFLICT_DATA) ---
# shellcheck source=${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-helpers.sh
_MERGE_HELPERS_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-helpers.sh"
if [[ -f "$_MERGE_HELPERS_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$_MERGE_HELPERS_LIB"
fi

# --- Load CI findings normalization library ---
# shellcheck source=${CLAUDE_PLUGIN_ROOT}/scripts/lib/ci-findings-normalize.sh
_FINDINGS_NORMALIZE_LIB="${CLAUDE_PLUGIN_ROOT}/scripts/lib/ci-findings-normalize.sh"
if [[ -f "$_FINDINGS_NORMALIZE_LIB" ]]; then
    # shellcheck disable=SC1090
    CI_FINDINGS_LIB_MODE=1 source "$_FINDINGS_NORMALIZE_LIB"  # shim-exempt: internal plugin script
fi

# --- _dso_is_ci_environment: detect whether we're running inside a CI runner ---
# Returns 0 when running in a recognized CI environment (CI=true, GITHUB_ACTIONS=true,
# or one of the common CI markers). Returns 1 in all other cases (interactive sessions,
# local automation, etc.). LLM dispatch is permitted ONLY when this returns 0.
_dso_is_ci_environment() {
    [[ "${CI:-}" == "true" ]] && return 0
    [[ "${GITHUB_ACTIONS:-}" == "true" ]] && return 0
    [[ -n "${GITLAB_CI:-}" ]] && return 0
    [[ -n "${BUILDKITE:-}" ]] && return 0
    [[ -n "${CIRCLECI:-}" ]] && return 0
    return 1
}

# --- _dso_emit_local_escalation: structured exit when LLM dispatch is requested locally ---
# Args: $1=phase (resolve_threads|conflict_resolution|remediate),
#       $2=reason (one-line),
#       $3=instructions (what the session agent should do)
# Emits a JSON object to stdout describing the escalation. Caller chooses exit code.
_dso_emit_local_escalation() {
    local _phase="${1:-unknown}"
    local _reason="${2:-LLM dispatch requested in local environment (disallowed)}"
    local _instructions="${3:-Session agent must remediate the failure(s) manually.}"
    PHASE="$_phase" REASON="$_reason" INSTR="$_instructions" python3 -c "
import json, os, datetime, sys
if sys.version_info >= (3, 2):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
else:
    ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
print(json.dumps({
    'schema_version': 1,
    'escalation': 'local_no_llm_dispatch',
    'phase': os.environ.get('PHASE', ''),
    'reason': os.environ.get('REASON', ''),
    'instructions': os.environ.get('INSTR', ''),
    'timestamp': ts,
}))
" 2>/dev/null || true
}

# --- _phase_check_pr_comments_since_push: detect reviewer comments since last push ---
#
# Local-environment safety check: when running outside CI, fetch all PR comments
# (issue comments + review comments + review-thread comments) created AFTER the
# current head SHA was pushed. If any are present, emit an escalation and return
# non-zero so the session agent addresses them before merging.
#
# In CI this function returns 0 immediately — CI does not have a session agent
# to address comments, and the LLM-driven thread-resolution phase already covers
# review-thread comments under CI semantics.
#
# Args: $1=pr_number, $2=pr_url
# Returns: 0 = no new comments (or running in CI), 1 = new comments require attention.
_phase_check_pr_comments_since_push() {
    local _pr_number="${1:-}" _pr_url="${2:-}"

    # CI bypass: only enforce the comment check in local sessions. CI runs the
    # existing thread-resolution phase (LLM-driven) and treats top-level PR
    # conversation as out-of-scope for autonomous remediation.
    if _dso_is_ci_environment; then
        return 0
    fi

    [[ -z "$_pr_number" ]] && return 0

    # Establish "last push time" — use the committedDate of the current head
    # commit as a stable proxy for when the branch state most recently changed.
    local _head_sha _last_push_ts
    _head_sha=$(gh pr view "$_pr_number" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
    [[ -z "$_head_sha" ]] && return 0
    _last_push_ts=$(gh api "repos/{owner}/{repo}/commits/${_head_sha}" --jq '.commit.committer.date' 2>/dev/null || true)
    [[ -z "$_last_push_ts" || "$_last_push_ts" == "null" ]] && return 0

    # Collect comment counts since _last_push_ts across all three comment surfaces.
    local _gh_payload
    _gh_payload=$(gh pr view "$_pr_number" \
        --json comments,reviews,reviewThreads \
        --jq '{
            issue_comments: [.comments[]? | {createdAt, body, author: .author.login}],
            review_comments: [.reviews[]? | select(.body != null and .body != "") | {createdAt: .submittedAt, body: .body, author: .author.login}],
            thread_comments: [.reviewThreads[]?.comments[]? | {createdAt, body, author: .author.login}]
        }' 2>/dev/null || true)
    [[ -z "$_gh_payload" ]] && return 0

    # Filter to comments newer than _last_push_ts using python (avoids brittle bash date math).
    local _new_count
    _new_count=$(LAST_PUSH_TS="$_last_push_ts" PAYLOAD="$_gh_payload" python3 -c "
import json, os, sys
ts = os.environ.get('LAST_PUSH_TS', '')
try:
    d = json.loads(os.environ.get('PAYLOAD', '{}'))
except Exception:
    print(0); sys.exit(0)
n = 0
for key in ('issue_comments', 'review_comments', 'thread_comments'):
    for c in d.get(key, []) or []:
        ca = c.get('createdAt') or ''
        if ca and ca > ts:
            n += 1
print(n)
" 2>/dev/null || echo 0)

    if [[ "$_new_count" -gt 0 ]]; then
        _dso_emit_local_escalation "comments_since_push" \
            "PR #${_pr_number} has ${_new_count} new comment(s) since the last push (head=${_head_sha:0:8}, since=${_last_push_ts}; PR: ${_pr_url})" \
            "Session agent must read each new PR comment, address the feedback (push fixes or reply), and re-run merge-to-main.sh."
        return 1
    fi
    return 0
}

# --- gh CLI version gate (DD7) ---
# Parse `gh --version` first line: "gh version 2.40.1 (2024-...)" → "2.40.1".
# Compare against minimum 2.0.0 via `sort -V`. On too-old / missing gh: exit 1.
_check_gh_version() {
    local _min="2.0.0"
    local _found
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh CLI not found on PATH (required for PR-mode merge)" >&2
        return 1
    fi
    _found=$(gh --version 2>/dev/null | awk 'NR==1 {print $3; exit}')
    if [[ -z "$_found" ]]; then
        echo "ERROR: gh CLI 2.0.0+ required for PR-mode merge (could not parse \`gh --version\` output)" >&2
        return 1
    fi
    # `printf "%s\n%s\n" "$_min" "$_found" | sort -V | head -n1` → smaller of the two.
    # When equal, sort -V emits _min first (input order is _min then _found, and
    # sort -V is stable on equal keys), so _smallest == _min covers both
    # _found > _min and _found == _min. If _smallest != _min, _found is older
    # than the minimum required.
    local _smallest
    _smallest=$(printf '%s\n%s\n' "$_min" "$_found" | sort -V | head -n1)
    if [[ "$_smallest" != "$_min" ]]; then
        # _found is the smaller → too old
        echo "ERROR: gh CLI 2.0.0+ required for PR-mode merge (found $_found)" >&2
        return 1
    fi
    return 0
}

# --- Duplicate-PR guard (DD4) ---
# `gh pr list --head $BRANCH --state open --json number,url --jq '.[0].url'`.
# Non-empty result → an open PR already exists for this branch → exit non-zero.
# Best-effort: if gh fails (no auth, no remote, etc.), proceed — the downstream
# PR-create call in Task 3 will surface the underlying error with full context.
_check_duplicate_pr() {
    local _existing
    _existing=$(gh pr list --head "$BRANCH" --state open --json number,url --jq '.[0].url' 2>/dev/null || true)
    if [[ -n "$_existing" ]]; then
        echo "ERROR: open PR already exists for branch $BRANCH: $_existing" >&2
        return 1
    fi
    return 0
}

# --- State writer: persist PR url + number into the state file ---
# Best-effort; mirrors merge-helpers.sh's other _state_* writers.
_state_write_pr_meta() {
    local _pr_url="$1"
    local _pr_number="$2"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    PR_URL="$_pr_url" PR_NUMBER="$_pr_number" SF="$_sf" python3 -c "
import json, os
sf = os.environ['SF']
with open(sf) as f:
    d = json.load(f)
d['pr_url'] = os.environ.get('PR_URL', '')
try:
    d['pr_number'] = int(os.environ.get('PR_NUMBER', '0'))
except Exception:
    d['pr_number'] = os.environ.get('PR_NUMBER', '')
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

# --- _fetch_and_rebase_branch: helper for pre-push synchronization ---
# Fetches origin/$BRANCH and rebases local HEAD onto it when local is behind.
# Used by _phase_merge before the initial push and again on push-rejection
# retry (b56b-14e9). Returns 0 on success (or fast-forward not needed), 1 on
# rebase failure (caller must decide whether to abort the rebase and bail).
#
# REVIEW-DEFENSE (PR #65 round-2 important finding "post-rebase-abort retry
# masks original failure"): when rebase fails the helper runs `git rebase
# --abort` (line below) which restores HEAD to the pre-rebase commit, then
# returns 1 — the caller _phase_merge does `_fetch_and_rebase_branch ||
# return 1` BEFORE the push, so a rebase failure on the first call exits
# immediately and the retry path is NEVER reached. The retry path is only
# entered when the FIRST helper call returned 0 (no rebase needed OR rebase
# succeeded) and the push subsequently failed for a non-rebase reason
# (auth, transient network, NFF race). After a successful rebase + failed
# push, the second helper call's merge-base --is-ancestor check correctly
# detects the new fast-forward state and returns 0 without re-running
# rebase, which is the intended retry-the-push behavior. The reviewer's
# scenario "rebase fails first call → second helper call masks via FF
# check" cannot occur because rebase --abort restores pre-rebase HEAD, so
# `origin/$BRANCH` is still NOT an ancestor of HEAD on the second call,
# and rebase is reattempted (and fails the same way, returning 1).
_fetch_and_rebase_branch() {
    if ! git fetch origin "$BRANCH" 2>/dev/null; then
        # Remote ref absent yet — fresh branch, nothing to rebase against.
        return 0
    fi
    # Already a fast-forward → no rebase needed.
    if git merge-base --is-ancestor "origin/$BRANCH" HEAD 2>/dev/null; then
        return 0
    fi
    # Local is behind; attempt rebase. Capture rebase output so the caller can
    # distinguish merge-conflict failures from other rebase errors via stderr.
    local _rebase_out _rebase_rc=0
    _rebase_out=$(git pull --rebase origin "$BRANCH" 2>&1) || _rebase_rc=$?
    if [[ "$_rebase_rc" -ne 0 ]]; then
        git rebase --abort 2>/dev/null || true
        local _hint="(rebase failed)"
        if [[ "$_rebase_out" == *"CONFLICT"* || "$_rebase_out" == *"merge conflict"* ]]; then
            _hint="(merge conflicts — run /dso:resolve-conflicts)"
        fi
        echo "ERROR: git pull --rebase origin $BRANCH failed $_hint" >&2
        return 1
    fi
    return 0
}

# --- _phase_merge (PR mode): sync to main, push branch, create PR ---
# DD1: gh pr create
# DD6: emit CONFLICT_DATA when gh reports mergeable=CONFLICTING
#
# Steps:
#   1. git fetch origin main                  — ensure origin/main is current
#   1b. merge origin/main into HEAD if branch is behind (a456-c689)
#   2. git push -u origin "$BRANCH"           — publish branch
#   3. gh pr create --base main --head "$BRANCH" --title <derived> --body <auto>
#      → capture PR url + number
#   4. Persist pr_url, pr_number into state file
#   5. gh pr view <num> --json mergeable      — detect CONFLICTING up-front
#
# Auto-merge is NOT enqueued here. It is enqueued by _phase_queue_auto_merge
# in the top-level flow, AFTER _phase_resolve_threads completes (ea7b-0038).
#
# Returns 0 on success,
# 1 on conflict / push-failure / pr-create-failure / unrecoverable error.
# CONFLICT_DATA emission is performed by the caller (top-level error handler
# below) so the contract surface is identical to direct mode.
_phase_merge() {
    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "merge" 2>/dev/null || true
    fi

    # --- 1. Sync against origin/main before push (a456-c689) ---
    # Ensure the branch incorporates the current origin/main tip so CI runs on
    # the same base that will be used at merge time. Without this, a PR created
    # after a prior PR merged to main would be immediately out-of-date and the
    # subsequent merge-queue sync would invalidate the just-completed CI run.
    if git fetch origin "main:refs/remotes/origin/main" --quiet 2>/dev/null || \
       git fetch origin main --quiet 2>/dev/null; then
        if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
            # Only attempt the merge when a common ancestor exists. Unrelated
            # histories (no common ancestor) means the worktree was initialised
            # independently of origin/main and forcing a merge would be wrong.
            local _common_ancestor
            _common_ancestor=$(git merge-base HEAD origin/main 2>/dev/null || true)
            if [[ -n "$_common_ancestor" ]]; then
                echo "INFO: Branch is behind origin/main — merging before push to avoid stale CI." >&2
                local _merge_main_out _merge_main_rc=0
                _merge_main_out=$(git merge --no-edit origin/main 2>&1) || _merge_main_rc=$?
                if [[ "$_merge_main_rc" -ne 0 ]]; then
                    git merge --abort 2>/dev/null || true
                    local _merge_hint="(merge failed)"
                    if echo "$_merge_main_out" | grep -qiE "CONFLICT|merge conflict"; then
                        _merge_hint="(merge conflicts — run /dso:resolve-conflicts)"
                    fi
                    echo "ERROR: git merge origin/main failed $_merge_hint" >&2
                    return 1
                fi
            fi
            # No common ancestor → skip sync; branch and main are unrelated histories.
        fi
    else
        echo "WARNING: git fetch origin main failed — skipping origin/main sync; proceeding with current HEAD." >&2
    fi

    # --- 1b. Publish branch ---
    # Pre-push sync: when the remote ref already exists and has advanced
    # past our local HEAD (e.g. a previous "Merge branch 'main' into <branch>"
    # landed via UI or another session), `git push -u` will be rejected
    # non-fast-forward. Fetch and rebase before push so the workflow recovers
    # automatically instead of halting and forcing manual `git pull --rebase`.
    # (b56b-14e9)
    _fetch_and_rebase_branch || return 1

    if ! git push -u origin "$BRANCH" 2>&1; then
        # Retry once on rejection: another push may have landed between fetch and push.
        if _fetch_and_rebase_branch && git push -u origin "$BRANCH" 2>&1; then
            : # retry succeeded
        else
            git rebase --abort 2>/dev/null || true
            echo "ERROR: git push -u origin $BRANCH failed (after fetch+rebase retry)" >&2
            return 1
        fi
    fi

    # --- 3. Derive PR title from last meaningful commit subject ---
    local _title
    _title=$(git log -1 --pretty=%s 2>/dev/null || echo "Merge $BRANCH")
    if [[ -z "$_title" ]]; then
        _title="Merge $BRANCH"
    fi

    local _body
    _body="Auto-generated PR for branch \`$BRANCH\` (created by merge-to-main-pr.sh)."

    # --- 4. Create the PR ---
    local _pr_url _pr_create_rc=0
    _pr_url=$(gh pr create --base main --head "$BRANCH" \
                          --title "$_title" --body "$_body" 2>&1) || _pr_create_rc=$?
    if [[ "$_pr_create_rc" -ne 0 ]]; then
        echo "ERROR: gh pr create failed: $_pr_url" >&2
        # _pr_url may contain the error text — still return 1 so caller emits
        # CONFLICT_DATA (best-effort) for upstream orchestrators.
        return 1
    fi

    # gh pr create may print extra log lines before the URL; extract the
    # last line that looks like a PR url.
    local _final_url
    _final_url=$(echo "$_pr_url" | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -n1)
    if [[ -z "$_final_url" ]]; then
        # Fallback: trust the entire stdout as the URL (some gh versions emit
        # only the URL with no surrounding text).
        _final_url=$(echo "$_pr_url" | tail -n1 | tr -d '[:space:]')
    fi

    local _pr_number
    _pr_number=$(echo "$_final_url" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+$')
    if [[ -z "$_pr_number" ]]; then
        echo "ERROR: could not parse PR number from gh pr create output: $_pr_url" >&2
        return 1
    fi

    # --- 5. Persist PR url + number to state file (best-effort) ---
    _state_write_pr_meta "$_final_url" "$_pr_number" 2>/dev/null || true

    echo "INFO: Created PR #${_pr_number}: $_final_url"

    # --- 6. Detect CONFLICTING up-front via `gh pr view --json mergeable` ---
    # If GitHub reports the PR as CONFLICTING, return 1 so the caller emits
    # CONFLICT_DATA. We do not enqueue auto-merge for a known-conflicting PR.
    local _mergeable_json _mergeable
    _mergeable_json=$(gh pr view "$_pr_number" --json mergeable 2>/dev/null || true)
    _mergeable=$(echo "$_mergeable_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('mergeable', ''))
except Exception:
    print('')
" 2>/dev/null || true)

    if [[ "$_mergeable" == "CONFLICTING" ]]; then
        echo "ERROR: PR #${_pr_number} is CONFLICTING — cannot enqueue auto-merge" >&2
        return 1
    fi

    # Auto-merge is NOT enqueued here. It is deferred to _phase_queue_auto_merge,
    # called in the top-level flow AFTER _phase_resolve_threads completes (ea7b-0038).
    # This ensures that if thread resolution fails or produces a new push, auto-merge
    # has not already been queued and cannot fire prematurely.

    if type _state_mark_complete >/dev/null 2>&1; then
        _state_mark_complete "merge" 2>/dev/null || true
    fi

    return 0
}

# --- _phase_queue_auto_merge: enqueue auto-merge AFTER thread resolution (ea7b-0038) ---
# Called in the top-level flow after _phase_resolve_threads succeeds.
# Moved out of _phase_merge so that if thread resolution fails or produces a
# new push, auto-merge is not already queued GitHub-side.
#
# When auto-merge is disabled at the repo level, falls through to manual-merge
# mode: the PR exists, CI will run, and _phase_poll will issue `gh pr merge`
# itself once all required checks pass.
#
# Returns 0 on success (including auto-merge-disabled fall-through),
# 1 on unrecoverable error.
_phase_queue_auto_merge() {
    local _pr_number="$1"

    local _merge_out _merge_rc=0
    _merge_out=$(gh pr merge "$_pr_number" --auto --merge 2>&1) || _merge_rc=$?
    if [[ "$_merge_rc" -ne 0 ]]; then
        if echo "$_merge_out" | grep -qiE "auto.?merge.*(not allowed|disabled|cannot be enabled)"; then
            echo "WARNING: GitHub auto-merge is disabled for this repository — falling through to manual merge after CI." >&2
            echo "         (To enable for future runs: Settings → General → 'Allow auto-merge'.)" >&2
            if type _state_write_auto_merge_disabled >/dev/null 2>&1; then
                _state_write_auto_merge_disabled "true" 2>/dev/null || true
            fi
        else
            echo "ERROR: gh pr merge ${_pr_number} --auto --merge failed: $_merge_out" >&2
            return 1
        fi
    else
        echo "INFO: Auto-merge queued for PR #${_pr_number}."
    fi

    return 0
}

# tests (test-merge-to-main-pr-thread-resolution.sh) which exercise the _phase_resolve_threads
# entry point end-to-end. Individual unit tests for each extracted helper would be
# change-detector tests that test implementation structure rather than behavior.
# --- _pr_validate_file_path: sanitize a reviewer-supplied file path ---
# Reviewer-supplied input from PR review threads is untrusted. Reject paths
# that could be used for path traversal, absolute-path access outside the
# repo, or argument injection (paths starting with `-` would be parsed as
# a flag by `git diff` or the LLM dispatch command).
#
# Returns 0 if path is safe, 1 otherwise. Empty string is treated as safe
# (callers handle empty by skipping diff context).
#
# Allowed: alphanumerics, `/`, `.`, `_`, `-` (not as first char), and the
# typical filename character set. Rejects:
#   * leading `-`           — would be parsed as a flag
#   * leading `/`           — absolute path
#   * any `..` segment      — path traversal
#   * characters outside    [A-Za-z0-9._/-]
_pr_validate_file_path() {
    local _p="${1:-}"
    [[ -z "$_p" ]] && return 0
    # Reject leading dash (flag injection)
    [[ "$_p" == -* ]] && return 1
    # Reject absolute paths
    [[ "$_p" == /* ]] && return 1
    # Reject any `..` segment (path traversal). Regex matches `..` as a complete
    # path component (preceded by start-of-string or '/', followed by end-of-string
    # or '/'). Using regex avoids the literal `..\/` string that fails the
    # plugin-scripts no-relative-paths lint.
    [[ "$_p" =~ (^|/)\.\.(/|$) ]] && return 1
    # Whitelist character set
    [[ "$_p" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    return 0
}

# --- _pr_resolve_threads_read_config: read loop config with env-override support ---
# Outputs four variables into the caller's scope via nameref-style assignments.
# Call as: _pr_resolve_threads_read_config <max_dispatches_var> <max_wait_var> <quiet_window_var> <interval_var>
# Populates each named variable with the resolved value.
# printf -v is used here because this function predates the bash 4.3+ version
# guard added at the top of the script. While local -n would be consistent with
# _pr_dispatch_unresolved_batch and _pr_commit_code_change_threads, the
# printf -v approach is functionally equivalent and avoids nameref pitfalls with
# array-typed caller variables. Harmonization deferred to follow-up refactor.
_pr_resolve_threads_read_config() {
    local _rc_max_dispatches_var="$1"
    local _rc_max_wait_var="$2"
    local _rc_quiet_window_var="$3"
    local _rc_interval_var="$4"
    local _read_config
    _read_config="${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh"  # shim-exempt: internal plugin script

    local _v_max_dispatches="${PR_THREAD_LOOP_MAX_DISPATCHES:-}"
    if [[ -z "$_v_max_dispatches" ]]; then
        _v_max_dispatches=$(bash "$_read_config" merge.pr_max_thread_dispatches 2>/dev/null || true)
        [[ -z "$_v_max_dispatches" ]] && _v_max_dispatches=10
    fi

    local _v_max_wait="${PR_THREAD_LOOP_MAX_WALL_SECONDS:-}"
    if [[ -z "$_v_max_wait" ]]; then
        _v_max_wait=$(bash "$_read_config" merge.pr_thread_resolution_max_wait_seconds 2>/dev/null || true)
        [[ -z "$_v_max_wait" ]] && _v_max_wait=1800
    fi

    local _v_quiet_window
    _v_quiet_window=$(bash "$_read_config" merge.pr_thread_quiet_window_seconds 2>/dev/null || true)
    [[ -z "$_v_quiet_window" ]] && _v_quiet_window=120

    local _v_interval="${PR_THREAD_LOOP_INTERVAL:-}"
    if [[ -z "$_v_interval" ]]; then
        _v_interval=$(bash "$_read_config" merge.pr_poll_interval_seconds 2>/dev/null || true)
        [[ -z "$_v_interval" ]] && _v_interval=30
    fi

    # Assign into caller-provided variable names via printf+eval (bash-portable nameref alternative).
    printf -v "$_rc_max_dispatches_var" '%s' "$_v_max_dispatches"
    printf -v "$_rc_max_wait_var"       '%s' "$_v_max_wait"
    printf -v "$_rc_quiet_window_var"   '%s' "$_v_quiet_window"
    printf -v "$_rc_interval_var"       '%s' "$_v_interval"
}

# --- _pr_handle_head_sha_reset: detect head SHA change and reset wall-clock window ---
# Args: _pr_number, _last_head_sha_var (nameref), _start_var (nameref),
#       _last_thread_seen_ts_var (nameref), _last_thread_count_var (nameref)
# Emits INFO:POLL_WINDOW_RESET on a change. Returns 0 normally; returns 2 when
# PR_THREAD_LOOP_TEST_STOP_AFTER_RESET=1 (test escape hatch).
_pr_handle_head_sha_reset() {
    # in tests/integration/test-merge-to-main-pr-thread-resolution.sh, which stubs gh to
    # return a changed headRefOid and asserts that the poll window is reset (POLL_WINDOW_RESET
    # log line detected). The function also exposes PR_THREAD_LOOP_TEST_STOP_AFTER_RESET=1
    # as a test escape hatch (return 2) that the test uses to stop the loop after one reset.
    # Transient gh failure handling (empty _curr_head_sha) is validated by not updating
    # the stored SHA, which can be asserted via the escape hatch in a targeted test.
    local _phr_pr_number="$1"
    local _phr_last_sha_var="$2"
    local _phr_start_var="$3"
    local _phr_last_thread_seen_ts_var="$4"
    local _phr_last_thread_count_var="$5"

    local _curr_head_sha=""
    _curr_head_sha=$(gh pr view "$_phr_pr_number" --json headRefOid 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('headRefOid', ''))
except Exception:
    print('')
" 2>/dev/null || true)

    local _last_sha="${!_phr_last_sha_var}"
    if [[ -n "$_last_sha" && -n "$_curr_head_sha" && "$_curr_head_sha" != "$_last_sha" ]]; then
        echo "INFO: POLL_WINDOW_RESET — head SHA changed from ${_last_sha} to ${_curr_head_sha}; resetting wall-clock window"
        printf -v "$_phr_start_var"                  '%s' "$SECONDS"
        printf -v "$_phr_last_thread_seen_ts_var"    '%s' "0"
        printf -v "$_phr_last_thread_count_var"      '%s' "0"
        if [[ "${PR_THREAD_LOOP_TEST_STOP_AFTER_RESET:-0}" == "1" ]]; then
            return 2
        fi
    fi
    # Only update tracked head SHA when we got a non-empty value from gh.
    # A transient `gh` failure produces an empty _curr_head_sha; overwriting
    # would mask a real subsequent push and silently defeat the wall-clock cap.
    if [[ -n "$_curr_head_sha" ]]; then
        printf -v "$_phr_last_sha_var" '%s' "$_curr_head_sha"
    fi
    return 0
}

# --- _pr_dispatch_unresolved_batch: dispatch LLM for each unresolved thread in one loop iteration ---
# Args: _pr_number, _pr_url, _repo_root, _llm_cmd, _max_dispatches,
#       _dispatches_var (nameref), _escalated_threads_var (nameref to assoc array name),
#       _code_change_threads_var (nameref to indexed array name), _threads_arr (by value via "$@")
# The _threads_arr elements are passed as positional args starting at arg 9.
# Returns 0. Updates _dispatches, _escalated_threads, and _code_change_threads in the caller.
# tests/integration/test-merge-to-main-pr-thread-resolution.sh:
# test_dispatch_count_cap_triggers_escalation (exercises the full dispatch→escalation
# path including tab-delimited parsing and thread routing) and
# test_wall_clock_cap_triggers_escalation (exercises the wall-clock exit condition
# through the same code path). Dedicated unit tests for tab-parsing edge cases
# would be fragile change-detector tests; behavioral coverage via the cap tests
# is the appropriate boundary.
_pr_dispatch_unresolved_batch() {
    local _pdb_pr_number="$1"
    local _pdb_pr_url="$2"
    local _pdb_repo_root="$3"
    local _pdb_llm_cmd="$4"
    local _pdb_max_dispatches="$5"
    local _pdb_dispatches_var="$6"
    local _pdb_escalated_var="$7"     # name of the caller's associative array
    local _pdb_code_change_var="$8"   # name of the caller's indexed array
    shift 8
    # Remaining positional args are the thread entries (tab-delimited).
    local _pdb_threads=("$@")

    # Local-environment guard: thread resolution dispatches LLM agents and is
    # therefore CI-only. When invoked outside CI, emit an escalation JSON and
    # return non-zero so _phase_resolve_threads exits and the session agent
    # remediates the unresolved threads via /dso:fix-bug or manual review.
    if ! _dso_is_ci_environment; then
        local _pdb_unresolved_ids="" _pdb_entry _pdb_eid
        for _pdb_entry in "${_pdb_threads[@]:-}"; do
            [[ -z "$_pdb_entry" ]] && continue
            _pdb_eid="${_pdb_entry%%$'\t'*}"
            _pdb_unresolved_ids+="${_pdb_eid},"
        done
        _pdb_unresolved_ids="${_pdb_unresolved_ids%,}"
        _dso_emit_local_escalation "resolve_threads" \
            "PR #${_pdb_pr_number} has unresolved review threads; LLM-driven thread resolution is CI-only (PR: ${_pdb_pr_url}; threads: ${_pdb_unresolved_ids})" \
            "Session agent must address the open PR review threads (resolve, comment, or push fixes) before re-running merge-to-main.sh."
        return 2
    fi

    # Use namerefs to access the caller's associative/indexed arrays directly,
    # avoiding eval on variable names that originate from parameter input.
    # shellcheck disable=SC2178
    local -n _pdb_escalated_ref="$_pdb_escalated_var"
    # shellcheck disable=SC2178
    local -n _pdb_code_change_ref="$_pdb_code_change_var"
    # shellcheck disable=SC2178
    local -n _pdb_dispatches_ref="$_pdb_dispatches_var"

    # Guard against non-numeric max_dispatches (config parse failure returns empty).
    # _max_d_safe is loop-invariant: _pdb_max_dispatches does not change across iterations.
    local _max_d_safe="${_pdb_max_dispatches:-10}"
    if ! [[ "$_max_d_safe" =~ ^[0-9]+$ ]]; then _max_d_safe=10; fi
    # test_dispatch_count_cap_triggers_escalation in test-merge-to-main-pr-thread-resolution.sh,
    # which sets PR_THREAD_LOOP_MAX_DISPATCHES=10 (valid integer) and asserts exactly 10 dispatches
    # occur before escalation. The fallback to 10 on invalid input preserves the same cap behavior
    # as the tested case, so the numeric path is exercised by the same test. A dedicated test for
    # the non-numeric/empty path would be a change-detector (it only asserts the fallback value
    # is used, not observable behavior).

    local _t
    for _t in "${_pdb_threads[@]:-}"; do
        [[ -z "$_t" ]] && continue
        local _cur_dispatches="${_pdb_dispatches_ref}"
        if (( _cur_dispatches >= _max_d_safe )); then break; fi

        # Parse tab-delimited thread fields: thread_id, file, line, comment_id, body_b64
        local _thread_id="${_t%%$'\t'*}"
        # Skip threads already escalated in a prior loop iteration.
        [[ -n "${_pdb_escalated_ref[$_thread_id]:-}" ]] && continue

        local _file_path="" _line_range="" _comment_id="" _thread_body_b64=""
        IFS=$'\t' read -r _ _file_path _line_range _comment_id _thread_body_b64 <<< "$_t" || true
        local _thread_body=""
        [[ -n "$_thread_body_b64" ]] && _thread_body=$(echo "$_thread_body_b64" | base64 -d 2>/dev/null || true)

        # Validate reviewer-supplied file path before using it. _file_path
        # comes from the GraphQL response (untrusted reviewer input). An
        # invalid path is dropped: we skip the diff fetch and pass an empty
        # string to the LLM dispatch so neither `git diff` nor
        # the LLM dispatch command ever sees the malicious value.
        local _safe_file_path=""
        if _pr_validate_file_path "$_file_path"; then
            _safe_file_path="$_file_path"
        else
            echo "WARNING: rejecting unsafe file_path from thread ${_thread_id}: $(printf '%q' "$_file_path")" >&2
        fi

        # Generate a short diff_context for the file (best-effort; empty if unavailable).
        # Use a repo-relative path with git run from the repo root to avoid path doubling.
        local _diff_context=""
        if [[ -n "$_safe_file_path" && -n "$_pdb_repo_root" ]]; then
            # Even after _pr_validate_file_path, the path could resolve to
            # outside the repo via symlinks or simply not exist as a tracked
            # file. Restrict diff fetch to git-tracked paths so a reviewer
            # cannot trick us into reading arbitrary working-tree files.
            if git -C "$_pdb_repo_root" ls-files --error-unmatch -- "$_safe_file_path" >/dev/null 2>&1; then
                _diff_context=$(git -C "$_pdb_repo_root" diff HEAD -- "$_safe_file_path" 2>/dev/null | head -30 || true)
            fi
        fi

        # Build a structured user message containing all thread context.
        # This avoids sed injection from reviewer-supplied values (thread_body, etc.)
        # while giving the LLM all inputs it needs per pr-comment-responder.md.
        local _user_msg
        _user_msg=$(printf 'thread_id: %s\nthread_body: %s\npr_url: %s\nrepo_root: %s\nfile_path: %s\nline_range: %s\ndiff_context:\n%s' \
            "$_thread_id" \
            "${_thread_body:-[no body]}" \
            "$_pdb_pr_url" \
            "$_pdb_repo_root" \
            "${_safe_file_path:-}" \
            "${_line_range:-}" \
            "${_diff_context:-[none]}")

        local _llm_result=""
        local _llm_rc=0
        local _responder_prompt="${CLAUDE_PLUGIN_ROOT}/scripts/prompts/pr-comment-responder.md"  # shim-exempt: internal plugin script
        _llm_result=$("$_pdb_llm_cmd" \
            "$_responder_prompt" \
            "$_user_msg" \
            "standard" \
            2>/dev/null) || _llm_rc=$?

        # Every LLM dispatch attempt counts against the cap, regardless of
        # outcome. Otherwise a thread that consistently fails (non-zero exit
        # or empty result) would be retried indefinitely without ever
        # tripping the dispatch cap, defeating its purpose.
        _pdb_dispatches_ref=$(( _cur_dispatches + 1 ))

        # On infrastructure failure (non-zero exit, empty result), skip
        # action handling for this thread — it will be retried next
        # iteration (subject to the dispatch cap above).
        if [[ $_llm_rc -ne 0 || -z "$_llm_result" ]]; then
            echo "WARNING: LLM dispatch failed (exit ${_llm_rc}) for thread ${_thread_id} — will retry next iteration." >&2
            continue
        fi

        # Parse the terminal ACTION: line from the LLM output
        local _action_line=""
        _action_line=$(echo "$_llm_result" | grep -E "^ACTION:" | tail -1 || true)

        case "$_action_line" in
            ACTION:code_change*)
                # Track threads with code changes; batch commit happens after the loop
                # so one commit and one push covers all code_change threads per iteration.
                _pdb_code_change_ref+=("$_thread_id")
                ;;
            ACTION:reply\ REPLY:*)
                local _reply_body=""
                _reply_body="${_action_line#ACTION:reply REPLY:}"
                # Trim all leading whitespace (LLM may emit 'REPLY: text' with space(s)/tab after colon)
                _reply_body="${_reply_body#"${_reply_body%%[![:space:]]*}"}"
                [[ -z "$_reply_body" ]] && _reply_body="Acknowledged"
                local _reply_rc=0
                if type _pr_post_thread_reply >/dev/null 2>&1; then
                    _pr_post_thread_reply "$_pdb_pr_number" "$_comment_id" "$_reply_body" >/dev/null 2>&1 || _reply_rc=$?
                fi
                if [[ $_reply_rc -eq 0 ]]; then
                    # Only resolve after a successful reply to prevent duplicate replies
                    # if the resolve mutation fails and this thread is retried next iteration.
                    if type _pr_resolve_thread >/dev/null 2>&1; then
                        _pr_resolve_thread "$_thread_id" >/dev/null 2>&1 || {
                            # Resolve failed — escalate so next iteration skips re-posting
                            _pdb_escalated_ref[$_thread_id]=1
                        }
                    fi
                fi
                ;;
            ACTION:escalate*|""|*)
                echo "INFO: Thread ${_thread_id} escalated — leaving for user review." >&2
                _pdb_escalated_ref[$_thread_id]=1
                ;;
        esac
    done
    return 0
}

# --- _pr_commit_code_change_threads: batch commit + push for code_change threads ---
# All code_change threads in one iteration share one commit + push to avoid
# triggering N CI runs for N concurrent changes. Threads are only resolved on
# GitHub after a successful commit AND push — never mark resolved when the fix
# hasn't reached the remote.
#
# This raw git commit is intentional and CI-only: merge-to-main-pr.sh runs in
# CI environments (e.g. GitHub Actions) where the project pre-commit hook suite
# is not installed. In interactive/local sessions the review gate would block
# this commit; guard below escalates code_change threads instead of committing.
#
# Args: _repo_root, _escalated_threads_var (nameref), _code_change_threads_var (nameref)
# Modifies _escalated_threads and _code_change_threads in place via the namerefs.
_pr_commit_code_change_threads() {
    local _pcct_repo_root="$1"
    local _pcct_escalated_var="$2"
    local _pcct_code_change_var="$3"

    # Use namerefs to avoid eval on caller-supplied variable names.
    # shellcheck disable=SC2178
    local -n _pcct_escalated_ref="$_pcct_escalated_var"
    # shellcheck disable=SC2178
    local -n _pcct_code_change_ref="$_pcct_code_change_var"

    local _pcct_count="${#_pcct_code_change_ref[@]}"
    (( _pcct_count == 0 )) && return 0

    if [[ "${CI:-}" != "true" ]]; then
        echo "WARNING: code_change threads require CI mode (CI=true) for auto-commit — escalating threads to avoid review-gate conflict." >&2
        local _pcct_ct
        for _pcct_ct in "${_pcct_code_change_ref[@]}"; do
            _pcct_escalated_ref[$_pcct_ct]=1
        done
        _pcct_code_change_ref=()
        return 0
    fi

    local _commit_rc=0
    local _thread_list="${_pcct_code_change_ref[*]}"
    # Stage all tracked file changes before committing.
    # (dispatched for code_change action in _pr_dispatch_unresolved_batch) applies
    # file edits to the working tree without staging them. merge-to-main-pr.sh runs
    # only in automated PR-merge mode — no unrelated working-tree modifications exist
    # at this point; all unstaged modifications are from the LLM's code_change.
    # Targeted add (git add <specific-files>) is not feasible because the LLM dispatch
    # does not return a list of modified paths. The staging scope is therefore
    # bounded by the PR-merge execution context, not by the staging command itself.
    # Verified by test_per_thread_resolve_failure_emits_warn: the git commit succeeds
    # only when add-u runs; removing it causes the commit to be empty (FIXTURE_BUG).
    git -C "$_pcct_repo_root" add -u || \
        echo "WARNING: git add -u failed — code_change commit may be empty or incomplete." >&2
    git -C "$_pcct_repo_root" commit -m "fix: address PR review threads ${_thread_list}" 2>/dev/null || _commit_rc=$?
    if [[ $_commit_rc -eq 0 ]]; then
        local _push_rc=0
        git -C "$_pcct_repo_root" push origin HEAD 2>/dev/null || _push_rc=$?
        if [[ $_push_rc -eq 0 ]]; then
            if type _pr_resolve_thread >/dev/null 2>&1; then
                local _pcct_ct
                for _pcct_ct in "${_pcct_code_change_ref[@]}"; do
                    # t_per_thread_resolve_failure_emits_warn, which specifically stubs _pr_resolve_thread to return
                    # non-zero and asserts that a WARNING message is emitted on stderr. The test was added as part of
                    # this bug fix (1920-c513) and exercises this exact code path.
                    local _resolve_rc=0
                    _pr_resolve_thread "$_pcct_ct" >/dev/null 2>&1 || _resolve_rc=$?
                    if [[ $_resolve_rc -ne 0 ]]; then
                        echo "WARNING: thread ${_pcct_ct} resolution failed (rc=${_resolve_rc}) — will retry next iteration." >&2
                    fi
                done
            fi
        else
            echo "WARNING: push failed (exit ${_push_rc}) — escalating code_change threads to prevent retry loop." >&2
            # Escalate all code_change threads on push failure — the commit landed locally
            # but didn't reach the remote, so the threads cannot be resolved via GraphQL.
            # Escalating moves them to the user-visible escalation list rather than silently
            # dropping them or retrying indefinitely in the next iteration.
            # commit-failure escalation below and follows the same invariant (threads must be
            # escalated or resolved, never left pending after a failed operation). The commit-failure
            # path is covered by test_dispatch_count_cap_triggers_escalation (indirectly, via the
            # cap loop). A dedicated push-failure test would require a remote-configured git fixture —
            # the same setup complexity as the commit-failure fixture. Both paths are validated by
            # the behavioral contract: dispatch cap still fires within MAX_DISPATCHES iterations.
            local _pcct_pe
            for _pcct_pe in "${_pcct_code_change_ref[@]}"; do
                _pcct_escalated_ref[$_pcct_pe]=1
            done
            _pcct_code_change_ref=()
        fi
    else
        # test_dispatch_count_cap_triggers_escalation in test-merge-to-main-pr-thread-resolution.sh:
        # the dispatch cap fires after MAX_DISPATCHES code_change attempts, which requires
        # code_change threads to be properly re-enqueued or escalated after each failed iteration.
        # A dedicated unit test for this branch would require a real git repo fixture with
        # no staged changes — covered by the behavioral contract above.
        echo "WARNING: batch commit failed (exit ${_commit_rc}) — escalating code_change threads to prevent retry loop." >&2
        # Escalate all code_change threads since the commit failed (e.g., nothing staged).
        # Leaving them in _pcct_code_change_ref would cause infinite retry until dispatch cap.
        local _pcct_ce
        for _pcct_ce in "${_pcct_code_change_ref[@]}"; do
            _pcct_escalated_ref[$_pcct_ce]=1
        done
        _pcct_code_change_ref=()
    fi
    return 0
}

# --- _phase_resolve_threads: loop to resolve all PR review threads before poll ---
# Settling heuristic: done when zero unresolved threads AND quiet window elapsed.
# Bounds: max dispatch count (merge.pr_max_thread_dispatches, default 10) and
#         wall-clock budget (merge.pr_thread_resolution_max_wait_seconds, default 1800).
# Emits ESCALATE:thread_resolution on stderr with PR url + thread IDs when bounds hit.
# Env overrides for tests:
#   PR_THREAD_LOOP_MAX_DISPATCHES     — overrides config default (10)
#   PR_THREAD_LOOP_MAX_WALL_SECONDS   — overrides config default (1800)
#   PR_THREAD_LOOP_INTERVAL           — overrides config default (30)
#   PR_THREAD_LOOP_START_OVERRIDE_SECONDS — simulate elapsed time at start (default 0)
#   PR_THREAD_LOOP_TEST_STOP_AFTER_RESET  — exit 0 after first POLL_WINDOW_RESET (testing)
#   _LLM_DISPATCH_CMD                 — REQUIRED LLM dispatch command (no default; unset → ESCALATE+exit 1)
_phase_resolve_threads() {
    local _pr_number="$1" _pr_url="$2"

    local _max_dispatches _max_wait _quiet_window _interval
    _pr_resolve_threads_read_config _max_dispatches _max_wait _quiet_window _interval

    local _dispatches=0
    local _start_offset="${PR_THREAD_LOOP_START_OVERRIDE_SECONDS:-0}"
    local _start=$(( SECONDS - _start_offset ))
    local _last_thread_seen_ts=0
    local _last_thread_count=0
    local _last_head_sha=""
    # compat-shim: LLM helper was deleted in S3; _LLM_DISPATCH_CMD must be set
    # IF unresolved threads actually require dispatch. The previous entry-time
    # guard fired before any thread fetch and blocked every PR even when there
    # were zero unresolved threads (bug 1a83-46c5). The check is now deferred to
    # just before the dispatch call (line ~1010 of this function), so a PR with
    # no review threads completes cleanly without requiring the helper, while a
    # PR with unresolved threads still fails loud rather than silently skipping
    # (the safety property requested by bug 9e04-0eb6).
    local _llm_cmd="${_LLM_DISPATCH_CMD:-}"
    # Track threads the LLM escalated so they are skipped on subsequent iterations
    # instead of burning the dispatch budget repeatedly on unresolvable threads.
    declare -A _escalated_threads=()

    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "resolve_threads" 2>/dev/null || true
    fi

    while :; do
        # --- Fetch unresolved threads ---
        local _threads_raw=""
        local _threads_arr=()
        local _threads_count=0
        if type _pr_fetch_unresolved_threads >/dev/null 2>&1; then
            local _fetch_rc=0
            _threads_raw=$(_pr_fetch_unresolved_threads "$_pr_number" 2>/dev/null) || _fetch_rc=$?
            if [[ "$_fetch_rc" -ne 0 ]]; then
                echo "ESCALATE:thread_resolution REASON:gh_api_failure PR:${_pr_url} FETCH_RC:${_fetch_rc}" >&2
                return 1
            fi
        fi
        if [[ -n "$_threads_raw" ]]; then
            mapfile -t _threads_arr <<< "$_threads_raw"
            _threads_count="${#_threads_arr[@]}"
        fi

        # --- Detect head SHA change (push-induced dismissal reset) ---
        local _sha_reset_rc=0
        _pr_handle_head_sha_reset \
            "$_pr_number" \
            _last_head_sha \
            _start \
            _last_thread_seen_ts \
            _last_thread_count || _sha_reset_rc=$?
        if [[ "$_sha_reset_rc" -eq 2 ]]; then
            return 0
        fi

        local _now_ts=$SECONDS

        # --- Track last-thread-seen time ---
        if (( _threads_count > _last_thread_count )); then
            _last_thread_seen_ts=$_now_ts
        fi
        _last_thread_count=$_threads_count

        # --- Settling heuristic ---
        local _quiet_elapsed="false"
        if (( _last_thread_seen_ts == 0 )); then
            (( (_now_ts - _start) >= _quiet_window )) && _quiet_elapsed="true"
        else
            (( (_now_ts - _last_thread_seen_ts) >= _quiet_window )) && _quiet_elapsed="true"
        fi

        if type _pr_settling_check >/dev/null 2>&1; then
            if _pr_settling_check --threads="$_threads_count" --quiet-window-elapsed="$_quiet_elapsed"; then
                echo "INFO: PR #${_pr_number} thread resolution settled."
                if type _state_mark_complete >/dev/null 2>&1; then
                    _state_mark_complete "resolve_threads" 2>/dev/null || true
                fi
                return 0
            fi
        fi

        # Build comma-separated unresolved (non-escalated) thread IDs for ESCALATE messages.
        local _unresolved_ids="" _entry
        for _entry in "${_threads_arr[@]:-}"; do
            [[ -z "$_entry" ]] && continue
            local _eid="${_entry%%$'\t'*}"
            [[ -n "${_escalated_threads[$_eid]:-}" ]] && continue
            _unresolved_ids+="${_eid},"
        done
        _unresolved_ids="${_unresolved_ids%,}"

        # Early-exit: if all active threads are escalated, no dispatches are
        # possible on this iteration or any future one — emit ESCALATE immediately
        # rather than spinning out the full wall-clock budget.
        if (( _threads_count > 0 )) && [[ -z "$_unresolved_ids" ]]; then
            echo "ESCALATE:thread_resolution REASON:all_escalated PR:${_pr_url} DISPATCHES:${_dispatches}" >&2
            return 1
        fi

        # --- Bounds: wall-clock ---
        local _elapsed=$(( _now_ts - _start ))
        if (( _elapsed >= _max_wait )); then
            echo "ESCALATE:thread_resolution REASON:wall_clock PR:${_pr_url} UNRESOLVED:${_unresolved_ids} DISPATCHES:${_dispatches}" >&2
            return 1
        fi

        # --- Bounds: dispatch cap ---
        # which validates the value falls back to the integer 10 when empty or missing from
        # config. The arithmetic at this call site is safe under the same constraint.
        if (( _dispatches >= _max_dispatches )); then
            echo "ESCALATE:thread_resolution REASON:dispatch_cap PR:${_pr_url} UNRESOLVED:${_unresolved_ids} DISPATCHES:${_dispatches}" >&2
            return 1
        fi

        # --- LLM helper required from this point — fail-loud if unset (1a83-46c5) ---
        # We only reach this point if there are actual unresolved, non-escalated
        # threads that need LLM dispatch. PRs with zero review threads exit cleanly
        # via _pr_settling_check above without ever requiring the helper.
        if [[ -z "$_llm_cmd" ]]; then
            echo "ESCALATE: _LLM_DISPATCH_CMD not set; no LLM helper available (deleted in S3). Configure _LLM_DISPATCH_CMD to a compat-shim or override per-environment to enable PR thread resolution. Refusing to silently skip. UNRESOLVED:${_unresolved_ids} PR:${_pr_url}" >&2
            return 1
        fi

        # --- Dispatch sub-agent for each unresolved thread ---
        local _repo_root
        _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        local _code_change_threads=()
        local _dispatch_batch_rc=0
        _pr_dispatch_unresolved_batch \
            "$_pr_number" \
            "$_pr_url" \
            "$_repo_root" \
            "$_llm_cmd" \
            "$_max_dispatches" \
            _dispatches \
            _escalated_threads \
            _code_change_threads \
            "${_threads_arr[@]:-}" || _dispatch_batch_rc=$?
        # _pr_dispatch_unresolved_batch returns 2 when LLM dispatch is requested
        # outside a CI environment (the local-escalation guard fired). Propagate
        # so the caller (and the session agent) sees the structured ESCALATE.
        if [[ "$_dispatch_batch_rc" -eq 2 ]]; then
            return 1
        fi

        # --- Batch commit + push for code_change threads ---
        _pr_commit_code_change_threads \
            "$_repo_root" \
            _escalated_threads \
            _code_change_threads

        # --- Sleep ---
        if [[ "$_interval" != "0" && "$_interval" != "0.0" ]]; then
            sleep "$_interval" 2>/dev/null || sleep 1
        fi
    done
}

# --- _phase_poll: poll CI checks + merge state until success / failure / timeout ---
# DD1: configurable poll cadence (merge.pr_poll_interval_seconds, default 30)
# DD2: ONE `gh pr checks` call per iteration (no fan-out)
# DD3: configurable max-wait timeout (merge.pr_max_wait_seconds, default 3600)
#
# Each iteration:
#   1. `gh pr checks <num> --json name,state,conclusion`
#      - any FAILURE/CANCELLED conclusion → exit 1 with PR url
#      - all SUCCESS → query merge state (step 2)
#   2. `gh pr view <num> --json state --jq .state`
#      - state == MERGED → break, success
#      - else → continue
#   3. Check elapsed: SECONDS - _start >= max_wait → exit 1 with PR url
#   4. sleep $interval
_phase_poll() {
    local _pr_number="$1" _pr_url="$2"
    local _interval _max_wait _read_config
    _read_config="${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh"  # shim-exempt: internal plugin script

    _interval=$(bash "$_read_config" merge.pr_poll_interval_seconds 2>/dev/null || true)
    _max_wait=$(bash "$_read_config" merge.pr_max_wait_seconds 2>/dev/null || true)
    [[ -z "$_interval" ]] && _interval=30
    [[ -z "$_max_wait" ]] && _max_wait=3600

    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "poll" 2>/dev/null || true
    fi

    local _start=$SECONDS
    while :; do
        # --- Step 1: ONE pr checks call ---
        local _checks_json _checks_rc=0
        _checks_json=$(gh pr checks "$_pr_number" --json name,state,conclusion 2>&1) || _checks_rc=$?

        # When PR has no checks, `gh pr checks` exits 8 with stderr "no checks reported".
        # Treat as "no failures yet" — continue polling for merge state.
        if [[ "$_checks_rc" -eq 0 ]]; then
            # Detect any failed conclusion
            local _has_failure
            _has_failure=$(echo "$_checks_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, list):
        print('false'); sys.exit(0)
    for c in d:
        concl = (c.get('conclusion') or '').upper()
        if concl in ('FAILURE', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED'):
            print('true'); sys.exit(0)
    print('false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")

            if [[ "$_has_failure" == "true" ]]; then
                echo "ERROR: required check failed for PR ${_pr_url}" >&2
                # Record the failed run ID so _phase_remediate can download artifacts.
                # Filter by branch AND status=failure: a concurrent in-progress run on
                # the same branch (e.g., from a manual workflow_dispatch) would otherwise
                # return as the most-recent run and steer remediation at the wrong findings.
                # BRANCH is set at script init from the current git branch.
                local _run_list _run_id=''
                _run_list=$(gh run list --branch "$BRANCH" --status failure --limit 1 --json databaseId 2>/dev/null || true)
                _run_id=$(echo "$_run_list" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if isinstance(d, list) and d:
        print(str(d[0].get('databaseId', '')))
except Exception:
    pass
" 2>/dev/null || true)
                if [[ -n "$_run_id" ]] && type _state_record_failed_run_id >/dev/null 2>&1; then
                    _state_record_failed_run_id "$_run_id" 2>/dev/null || true
                fi
                return 1
            fi

            # --- Auto-merge disabled fallback: manually merge once all checks pass ---
            # When the repo has auto-merge disabled, GitHub will never flip the PR to
            # MERGED on its own. Detect "all checks complete and successful" and issue
            # `gh pr merge --merge` ourselves so the loop's MERGED check below succeeds
            # on the next iteration.
            local _auto_merge_disabled="false"
            if type _state_read_auto_merge_disabled >/dev/null 2>&1; then
                _auto_merge_disabled=$(_state_read_auto_merge_disabled 2>/dev/null || echo "false")
            fi
            if [[ "$_auto_merge_disabled" == "true" ]]; then
                # Manual-merge readiness: require SUCCESS for every reported check.
                # We intentionally do NOT accept NEUTRAL or SKIPPED here, even though
                # they often indicate "passed" — branch protection rules may treat
                # them as not-passing-required, and a manual `gh pr merge --merge`
                # would be rejected. Falling through to the next poll iteration is
                # cheaper than loop-thrashing on a rejected merge attempt.
                local _all_done
                _all_done=$(echo "$_checks_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, list) or not d:
        print('false'); sys.exit(0)
    for c in d:
        state = (c.get('state') or '').upper()
        concl = (c.get('conclusion') or '').upper()
        if state in ('IN_PROGRESS', 'QUEUED', 'PENDING') or not concl:
            print('false'); sys.exit(0)
        if concl != 'SUCCESS':
            print('false'); sys.exit(0)
    print('true')
except Exception:
    print('false')
" 2>/dev/null || echo "false")
                if [[ "$_all_done" == "true" ]]; then
                    local _manual_out _manual_rc=0
                    _manual_out=$(gh pr merge "$_pr_number" --merge 2>&1) || _manual_rc=$?
                    if [[ "$_manual_rc" -eq 0 ]]; then
                        echo "INFO: Manual merge issued for PR #${_pr_number} (auto-merge disabled)."
                    else
                        # Don't fail hard: a transient gh error or "already merged" message is fine —
                        # the next iteration's state check will resolve.
                        echo "WARNING: gh pr merge ${_pr_number} --merge returned non-zero: $_manual_out" >&2
                    fi
                fi
            fi
        fi

        # --- Step 2: check PR state for MERGED ---
        local _state_raw _state
        _state_raw=$(gh pr view "$_pr_number" --json state --jq .state 2>/dev/null || true)
        # Strip whitespace
        _state=$(echo "$_state_raw" | tr -d '[:space:]')
        # Some gh versions output JSON-wrapped; fall back to grep
        if [[ -z "$_state" || "$_state" == "{"*  ]]; then
            _state=$(echo "$_state_raw" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('state', '') if isinstance(d, dict) else str(d))
except Exception:
    print('')
" 2>/dev/null || true)
        fi

        if [[ "$_state" == "MERGED" ]]; then
            echo "INFO: PR #${_pr_number} merged successfully."
            if type _state_mark_complete >/dev/null 2>&1; then
                _state_mark_complete "poll" 2>/dev/null || true
            fi
            return 0
        fi

        # --- Step 3: timeout check (computed on elapsed wall time) ---
        local _elapsed=$(( SECONDS - _start ))
        if (( _elapsed >= _max_wait )); then
            echo "ERROR: max-wait exceeded (${_max_wait}s) — PR URL: ${_pr_url}" >&2
            return 1
        fi

        # --- Step 4: sleep then continue ---
        # When interval is 0 or sub-second, skip sleep entirely (used in tests).
        if [[ "$_interval" != "0" && "$_interval" != "0.0" ]]; then
            sleep "$_interval" 2>/dev/null || sleep 1
        fi
    done
}

# --- _dispatch_resolve_conflicts: call LLM to resolve merge conflicts ---
# Returns: 0=resolved, 1=unknown, 2=ESCALATE
# Overridable via _RESOLVE_CONFLICTS_LLM_CMD for tests.
_dispatch_resolve_conflicts() {
    local _pr_number="$1" _pr_url="$2"
    if ! _dso_is_ci_environment; then
        _dso_emit_local_escalation "conflict_resolution" \
            "PR #${_pr_number} is CONFLICTING; LLM-driven conflict resolution is CI-only (PR: ${_pr_url})" \
            "Session agent must run /dso:resolve-conflicts (or rebase manually), push, and re-run merge-to-main.sh."
        return 2
    fi
    # compat-shim: LLM helper was deleted in S3; _RESOLVE_CONFLICTS_LLM_CMD must be set.
    # Fail-loud (return 2 = ESCALATE per this function's exit-code contract)
    # when unset: a silent skip would leave a CONFLICTING PR queued for
    # auto-merge with no resolution attempt. Bug 9e04-0eb6.
    local _llm_cmd="${_RESOLVE_CONFLICTS_LLM_CMD:-}"
    if [[ -z "$_llm_cmd" ]]; then
        echo "ESCALATE: _RESOLVE_CONFLICTS_LLM_CMD not set; no LLM helper available (deleted in S3). Configure _RESOLVE_CONFLICTS_LLM_CMD to enable LLM-driven conflict resolution. Refusing to silently skip." >&2
        return 2
    fi
    local _prompt_file="${CLAUDE_PLUGIN_ROOT}/docs/workflows/prompts/resolve-conflicts-dispatch.md"
    local _context_file
    _context_file="$(mktemp /tmp/dso-conflict-context.XXXXXX)"
    printf '{"pr_number": "%s", "pr_url": "%s"}' "$_pr_number" "$_pr_url" > "$_context_file"
    local _result
    _result=$("$_llm_cmd" "$_prompt_file" "$_context_file" "sonnet" 2>&1) || true
    rm -f "$_context_file"
    case "$_result" in
        *"RESOLUTION_RESULT: FIXES_APPLIED"*) return 0 ;;
        *"RESOLUTION_RESULT: ESCALATE"*)      return 2 ;;
        *)                                    return 1 ;;
    esac
}

# --- _phase_conflict_resolution: detect CONFLICTING PR state and dispatch resolve-conflicts ---
# Returns: 0=no conflict or conflict resolved, 1=conflict remains (escalation needed)
_phase_conflict_resolution() {
    local _pr_number="$1" _pr_url="$2"
    local _merge_state
    _merge_state=$(gh pr view "$_pr_number" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || true)
    [[ "$_merge_state" != "CONFLICTING" ]] && return 0
    # Capture rc and propagate stderr so an ESCALATE: from _dispatch_resolve_conflicts
    # (e.g., _RESOLVE_CONFLICTS_LLM_CMD unset → return 2) reaches the caller and
    # is visible in logs. A bare `2>/dev/null || true` would swallow both, making
    # the fail-loud guard in _dispatch_resolve_conflicts ineffective. Bug 9e04-0eb6.
    local _dispatch_rc=0
    _dispatch_resolve_conflicts "$_pr_number" "$_pr_url" || _dispatch_rc=$?
    if (( _dispatch_rc == 2 )); then
        echo "ESCALATION_REASON: Conflict resolution dispatch escalated (rc=2)" >&2
        return 1
    fi
    _merge_state=$(gh pr view "$_pr_number" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null || true)
    if [[ "$_merge_state" == "CONFLICTING" ]]; then
        echo "ESCALATION_REASON: Conflict resolution failed" >&2
        return 1
    fi
    return 0
}

# --- _remediate_counter_increment: check tier and global ceilings ---
# Args: $1=tier (1-4), $2=t1_count, $3=t2_count, $4=t3_count, $5=t4_count, $6=global_count
# Prints TIER_CEILING or GLOBAL_CEILING on stdout when a stop condition is met.
# Prints nothing (empty stdout) when counts are under all ceilings.
# Returns 0 in all cases.
_remediate_counter_increment() {
    local _tier="${1:-1}"
    local _t1="${2:-0}"
    local _t2="${3:-0}"
    local _t3="${4:-0}"
    local _t4="${5:-0}"
    local _global="${6:-0}"
    local _tier_ceiling=5
    local _global_ceiling=15

    # Select the tier-specific count
    local _tier_count
    case "$_tier" in
        1) _tier_count="$_t1" ;;
        2) _tier_count="$_t2" ;;
        3) _tier_count="$_t3" ;;
        4) _tier_count="$_t4" ;;
        *) _tier_count="$_t1" ;;
    esac

    # Check tier ceiling first
    if (( _tier_count >= _tier_ceiling )); then
        echo "TIER_CEILING"
        return 0
    fi

    # Check global ceiling
    if (( _global >= _global_ceiling )); then
        echo "GLOBAL_CEILING"
        return 0
    fi

    return 0
}

# --- _remediate_emit_escalation: emit a structured escalation JSON object ---
# Args: $1=stop_reason, $2=tiers_attempted (CSV), $3=attempts_per_tier (JSON string),
#       $4=remaining_findings_path, $5=suggested_next_step
# Emits a JSON object to stdout.
_remediate_emit_escalation() {
    local _stop_reason="${1:-}"
    local _tiers_attempted="${2:-}"
    local _per_tier_json="${3:-{}}"
    local _remaining_path="${4:-}"
    local _next_step="${5:-}"

    STOP="$_stop_reason" TIERS="$_tiers_attempted" PER_TIER="$_per_tier_json" \
    RPATH="$_remaining_path" NEXT="$_next_step" python3 -c "
import json, os, datetime, sys
stop = os.environ.get('STOP', '')
tiers = os.environ.get('TIERS', '')
per_tier_raw = os.environ.get('PER_TIER', '{}')
rpath = os.environ.get('RPATH', '')
nxt = os.environ.get('NEXT', '')
try:
    per_tier = json.loads(per_tier_raw)
except Exception:
    per_tier = {}
# Use timezone-aware UTC (datetime.utcnow() is deprecated in Python 3.12+)
if sys.version_info >= (3, 2):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
else:
    ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
d = {
    'schema_version': 1,
    'stop_reason': stop,
    'tiers_attempted': tiers,
    'attempts_per_tier': per_tier,
    'remaining_findings': rpath,
    'suggested_next_step': nxt,
    'timestamp': ts,
}
print(json.dumps(d))
" 2>/dev/null || true
    return 0
}

# --- _dispatch_fix_agent: invoke LLM sub-agent to apply fixes from findings ---
#
# ENV OVERRIDES (for testing):
#   _REMEDIATE_LLM_CMD  — REQUIRED LLM command (no default; unset → ESCALATE+return 2)
#                         Separate from _LLM_DISPATCH_CMD to avoid colliding with
#                         the thread-resolution override in _phase_resolve_threads.
#
# Args: $1=findings_path, $2=attempt_num (optional; when ==4, injects budget-pressure text)
# Returns: 0=FIXES_APPLIED, 1=FAIL/unknown, 2=ESCALATE
_dispatch_fix_agent() {
    local _findings_path="$1"
    local _attempt_num="${2:-}"
    if ! _dso_is_ci_environment; then
        _dso_emit_local_escalation "remediate" \
            "CI failed; LLM-driven fix dispatch is CI-only (findings: ${_findings_path})" \
            "Session agent must invoke /dso:fix-bug on the failing CI run, push the fix, and re-run merge-to-main.sh."
        return 2
    fi
    # compat-shim: LLM helper was deleted in S3; _REMEDIATE_LLM_CMD must be set.
    # Fail-loud (return 2 = ESCALATE per this function's exit-code contract)
    # when unset: a silent skip would leave failing CI checks unaddressed and
    # the PR queued for auto-merge with no remediation attempt. Bug 9e04-0eb6.
    local _llm_cmd="${_REMEDIATE_LLM_CMD:-}"
    if [[ -z "$_llm_cmd" ]]; then
        echo "ESCALATE: _REMEDIATE_LLM_CMD not set; no LLM helper available (deleted in S3). Configure _REMEDIATE_LLM_CMD to enable LLM-driven CI remediation. Refusing to silently skip." >&2
        return 2
    fi
    local _prompt_file="${CLAUDE_PLUGIN_ROOT}/docs/workflows/prompts/review-fix-dispatch.md"
    local _result
    local _user_msg="$_findings_path"
    if [[ "$_attempt_num" == "4" ]]; then
        # Append budget-pressure context to the user message so the LLM receives it.
        # The LLM dispatch cmd arg 2 is the user-message string — appending here ensures it
        # reaches the model regardless of whether the caller is a real LLM or a test stub.
        _user_msg="${_findings_path}
This is attempt 4 of 5 - if you cannot resolve this finding, return ESCALATE with a clear explanation"
    fi
    _result=$("$_llm_cmd" "$_prompt_file" "$_user_msg" "sonnet" 2>&1) || true
    case "$_result" in
        *"RESOLUTION_RESULT: FIXES_APPLIED"*) return 0 ;;
        *"RESOLUTION_RESULT: ESCALATE"*)      return 2 ;;
        *)                                     return 1 ;;
    esac
}

# --- _push_fix_branch: commit and push remediation fixes (CI-only) ---
# merge-to-main-pr.sh runs exclusively in automated CI environments where the
# project pre-commit hook suite is not installed. The CI guard below ensures
# this branch is never taken in interactive/local sessions, preventing
# review-gate conflicts. Mirrors the pattern in _pr_commit_code_change_threads.
#
# Args: <tier_number>
# Returns: 0 on success, 1 on failure
_push_fix_branch() {
    local _tier="${1:-0}"
    if [[ "${CI:-}" != "true" ]]; then
        echo "WARNING: remediate push skipped outside CI" >&2
        return 1
    fi
    git add -u 2>/dev/null || true
    # No `[skip ci]` tag: the push MUST trigger a new CI run so _phase_poll can
    # re-poll the post-fix run state. With the tag, GitHub Actions ignores the
    # commit and the remediation loop deadlocks waiting for a run that never starts.
    git commit -m "fix: CI remediation tier${_tier}" 2>/dev/null || return 1
    git push origin HEAD 2>/dev/null || return 1
    return 0
}

# --- _phase_remediate: autonomous CI fix loop ---
# Bounded retry loop: outer while-true / inner for-tier-in-1-2-3-4.
# Per-tier ceiling=5, global ceiling=15. Budget-pressure injected at attempt 4.
# Normalizes failures via lib/ci-findings-normalize.sh (Tier 1=LLM review JSON,
# Tier 2=test results, Tier 3=lint, Tier 4=generic log). Exit 3=ARTIFACT_MISSING.
# State persisted across iterations via _state_write_remediation_state.
#
# Args: <pr_number> <pr_url>
# Returns: 0 = CI passed after fix; 2 = any escalation (JSON on stdout).
# Escalation stop_reason values: TIER_CEILING, GLOBAL_CEILING, CANNOT_PROCEED,
#   OSCILLATION, THROTTLE_PAUSE, CONFLICT_RESOLUTION_FAILED, ARTIFACT_MISSING.
# Never returns 1. Caller exits 2 on non-zero return.
_phase_remediate() {
    local _pr_number="${1:-}" _pr_url="${2:-}"

    # Step 1: get failed_run_id from state file. When the field is absent or
    # empty the function cannot proceed — emit a structured escalation so the
    # caller (and operators reading logs) can see WHY remediation aborted,
    # rather than a silent `return 2`. The most likely cause is _phase_poll
    # not having captured a failed run id yet (e.g., running remediate without
    # a preceding poll-failure).
    local _sf _failed_run_id
    _sf=$(_state_file_path) 2>/dev/null || {
        _remediate_emit_escalation "ARTIFACT_MISSING" "" "{}" "" "State file unavailable — cannot read failed_run_id"
        return 2
    }
    _failed_run_id=$(_DSO_SF="$_sf" python3 -c "
import json, os, sys
try:
    with open(os.environ['_DSO_SF']) as f:
        d = json.load(f)
    rid = d.get('failed_run_id', '')
    if rid:
        print(rid)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null) || {
        _remediate_emit_escalation "ARTIFACT_MISSING" "" "{}" "" "No failed_run_id recorded in state — _phase_poll may not have captured a CI failure"
        return 2
    }

    # Step 2: download CI artifacts
    local _artifacts_dir
    _artifacts_dir=$(mktemp -d /tmp/dso-remediate-artifacts.XXXXXX)
    gh run download "$_failed_run_id" --dir "$_artifacts_dir" 2>/dev/null || { rm -rf "$_artifacts_dir"; return 2; }

    # Bounded retry loop: cycles through all 4 normalizer tiers with per-tier and
    # global attempt ceilings. Each outer iteration is one full pass over all tiers.
    local _attempts_t1=0 _attempts_t2=0 _attempts_t3=0 _attempts_t4=0
    local _attempts_global=0
    local _tiers_attempted=''
    local _per_tier_json
    local _tier _tier_artifact _tier_log _tier_normalized _tier_rc _dispatch_rc
    local _all_tiers_artifact_missing _counter_signal _attempt_num_for_tier
    local _prev_pass_successes='' _cur_pass_successes='' _old_count

    while true; do
        _prev_pass_successes="$_cur_pass_successes"
        _cur_pass_successes=''
        _all_tiers_artifact_missing=1

        # If _phase_poll captured a NEW failed_run_id during the prior pass
        # (i.e., a fix was pushed and CI re-ran with a fresh failure), re-download
        # artifacts so the next pass operates on current findings. Without this,
        # the loop reuses the original artifacts indefinitely and dispatches
        # fix-agents against stale findings.
        local _current_run_id
        _current_run_id=$(_state_read_failed_run_id 2>/dev/null || echo "")
        if [[ -n "$_current_run_id" ]] && [[ "$_current_run_id" != "$_failed_run_id" ]]; then
            rm -rf "$_artifacts_dir"
            _artifacts_dir=$(mktemp -d /tmp/dso-remediate-artifacts.XXXXXX)
            if ! gh run download "$_current_run_id" --dir "$_artifacts_dir" 2>/dev/null; then
                # Fresh download failed — escalate as ARTIFACT_MISSING rather than
                # silently reuse stale data. The orchestrator can retry manually.
                rm -rf "$_artifacts_dir"
                _per_tier_json="{\"1\":${_attempts_t1},\"2\":${_attempts_t2},\"3\":${_attempts_t3},\"4\":${_attempts_t4}}"
                _remediate_emit_escalation "ARTIFACT_MISSING" "$_tiers_attempted" "$_per_tier_json" "" "Could not download artifacts for run ${_current_run_id}"
                return 2
            fi
            _failed_run_id="$_current_run_id"
        fi

        for _tier in 1 2 3 4; do

            # --- throttle check before any dispatch ---
            local _usage_rc=0
            _check_usage_for_remediate 2>/dev/null || _usage_rc=$?
            if [[ "$_usage_rc" -eq 2 ]]; then
                _per_tier_json="{\"1\":${_attempts_t1},\"2\":${_attempts_t2},\"3\":${_attempts_t3},\"4\":${_attempts_t4}}"
                _remediate_emit_escalation "THROTTLE_PAUSE" "$_tiers_attempted" "$_per_tier_json" "" "Usage throttle hit; retry later"
                rm -rf "$_artifacts_dir"
                return 2
            fi

            # --- ceiling check ---
            _counter_signal=$(_remediate_counter_increment "$_tier" "$_attempts_t1" "$_attempts_t2" "$_attempts_t3" "$_attempts_t4" "$_attempts_global")
            case "$_counter_signal" in
                TIER_CEILING)
                    _per_tier_json="{\"1\":${_attempts_t1},\"2\":${_attempts_t2},\"3\":${_attempts_t3},\"4\":${_attempts_t4}}"
                    _remediate_emit_escalation "TIER_CEILING" "$_tiers_attempted" "$_per_tier_json" "" "Tier ${_tier} attempt ceiling reached"
                    rm -rf "$_artifacts_dir"
                    return 2
                    ;;
                GLOBAL_CEILING)
                    _per_tier_json="{\"1\":${_attempts_t1},\"2\":${_attempts_t2},\"3\":${_attempts_t3},\"4\":${_attempts_t4}}"
                    _state_write_remediation_state "remediate" "$_per_tier_json" "$_attempts_global" 2>/dev/null || true
                    _remediate_emit_escalation "GLOBAL_CEILING" "$_tiers_attempted" "$_per_tier_json" "" "Global retry limit reached"
                    rm -rf "$_artifacts_dir"
                    return 2
                    ;;
            esac
            # Note: OSCILLATION was a planned signal for fix/revert cycles, but
            # no production caller emits it. If detection is added later, restore
            # an OSCILLATION) branch above and ensure _remediate_counter_increment
            # (or another producer) actually returns the signal. Tests for the
            # `_remediate_emit_escalation` emitter still cover the OSCILLATION
            # stop_reason value as a generic enum case.

            # --- increment counters (using assignment to avoid set -e exit on 0→1) ---
            case "$_tier" in
                1) _attempts_t1=$(( _attempts_t1 + 1 )) ;;
                2) _attempts_t2=$(( _attempts_t2 + 1 )) ;;
                3) _attempts_t3=$(( _attempts_t3 + 1 )) ;;
                4) _attempts_t4=$(( _attempts_t4 + 1 )) ;;
            esac
            _attempts_global=$(( _attempts_global + 1 ))
            _tiers_attempted="${_tiers_attempted:+${_tiers_attempted},}${_tier}"

            # --- persist state ---
            _per_tier_json="{\"1\":${_attempts_t1},\"2\":${_attempts_t2},\"3\":${_attempts_t3},\"4\":${_attempts_t4}}"
            _state_write_remediation_state "remediate" "$_per_tier_json" "$_attempts_global" 2>/dev/null || true

            # Budget pressure fires at attempt 4 of THIS tier (per-tier ceiling=5).
            # Using the per-tier counter, not the global one — global crosses 4 on the
            # 4th distinct tier visit, which often corresponds to tier-1 attempt 1
            # and gives the agent misleading time-pressure context.
            case "$_tier" in
                1) _attempt_num_for_tier="$_attempts_t1" ;;
                2) _attempt_num_for_tier="$_attempts_t2" ;;
                3) _attempt_num_for_tier="$_attempts_t3" ;;
                4) _attempt_num_for_tier="$_attempts_t4" ;;
            esac

            _tier_normalized=$(mktemp /tmp/dso-normalized.XXXXXX)

            # Locate tier-specific artifact
            _tier_artifact=''
            case "$_tier" in
                1) _tier_artifact=$(find "$_artifacts_dir" -name 'reviewer-findings.json' -maxdepth 3 2>/dev/null | head -1) ;;
                2) _tier_artifact=$(find "$_artifacts_dir" -name 'test-results*.json' -maxdepth 3 2>/dev/null | head -1) ;;
                3) _tier_artifact=$(find "$_artifacts_dir" -name 'lint-results*.json' -maxdepth 3 2>/dev/null | head -1) ;;
                4) : ;;  # tier4 always uses CI log
            esac

            # Tiers 2-4 only: log fallback when no structured artifact
            _tier_log=''
            if [[ -z "$_tier_artifact" ]] && [[ "$_tier" -gt 1 ]]; then
                _tier_log=$(mktemp /tmp/dso-ci-log.XXXXXX)
                if _fetch_ci_log "$_failed_run_id" "$_tier_log" 2>/dev/null; then
                    _tier_artifact="$_tier_log"
                else
                    rm -f "$_tier_log"
                    _tier_log=''
                fi
            fi

            # Normalize — normalizers handle empty/missing input with exit 3 (ARTIFACT_MISSING)
            _tier_rc=0
            case "$_tier" in
                1) _normalize_tier1 "$_tier_artifact" "$_tier_normalized" 2>/dev/null || _tier_rc=$? ;;
                2) _normalize_tier2 "$_tier_artifact" "$_tier_normalized" 2>/dev/null || _tier_rc=$? ;;
                3) _normalize_tier3 "$_tier_artifact" "$_tier_normalized" 2>/dev/null || _tier_rc=$? ;;
                4) _normalize_tier4 "$_tier_artifact" "$_tier_normalized" 2>/dev/null || _tier_rc=$? ;;
            esac
            [[ -n "$_tier_log" ]] && { rm -f "$_tier_log"; _tier_log=''; }

            if [[ "$_tier_rc" -ne 0 ]]; then
                rm -f "$_tier_normalized"
                # Cross-tier regression: tier succeeded last pass but fails now — reset its counter
                if echo " ${_prev_pass_successes} " | grep -q " ${_tier} "; then
                    case "$_tier" in
                        1) _old_count="$_attempts_t1"; _attempts_t1=0 ;;
                        2) _old_count="$_attempts_t2"; _attempts_t2=0 ;;
                        3) _old_count="$_attempts_t3"; _attempts_t3=0 ;;
                        4) _old_count="$_attempts_t4"; _attempts_t4=0 ;;
                    esac
                    _attempts_global=$(( _attempts_global > _old_count ? _attempts_global - _old_count : 0 ))
                    _per_tier_json="{\"1\":${_attempts_t1},\"2\":${_attempts_t2},\"3\":${_attempts_t3},\"4\":${_attempts_t4}}"
                    _state_write_remediation_state "remediate" "$_per_tier_json" "$_attempts_global" 2>/dev/null || true
                fi
                continue  # ARTIFACT_MISSING or other error — try next tier
            fi

            # At least one tier did NOT return ARTIFACT_MISSING
            _all_tiers_artifact_missing=0
            _cur_pass_successes="${_cur_pass_successes:+${_cur_pass_successes} }${_tier}"

            # Dispatch fix agent; pass global attempt count for budget-pressure injection
            _dispatch_rc=0
            _dispatch_fix_agent "$_tier_normalized" "$_attempt_num_for_tier" 2>/dev/null || _dispatch_rc=$?
            rm -f "$_tier_normalized"

            if [[ "$_dispatch_rc" -eq 2 ]]; then
                # ESCALATE / CANNOT_PROCEED
                _per_tier_json="{\"1\":${_attempts_t1},\"2\":${_attempts_t2},\"3\":${_attempts_t3},\"4\":${_attempts_t4}}"
                _remediate_emit_escalation "CANNOT_PROCEED" "$_tiers_attempted" "$_per_tier_json" "" "Manual intervention required"
                rm -rf "$_artifacts_dir"
                return 2
            fi
            [[ "$_dispatch_rc" -ne 0 ]] && continue  # dispatch failed — try next tier

            # Push and re-poll
            _push_fix_branch "$_tier" 2>/dev/null || continue
            if _phase_poll "$_pr_number" "$_pr_url"; then
                rm -rf "$_artifacts_dir"
                return 0
            fi
            # Repoll failed — continue to next tier (or wrap around in next outer iteration)
        done

        # End of inner for-loop pass: if every tier returned ARTIFACT_MISSING, escalate
        if [[ "$_all_tiers_artifact_missing" -eq 1 ]]; then
            _per_tier_json="{\"1\":${_attempts_t1},\"2\":${_attempts_t2},\"3\":${_attempts_t3},\"4\":${_attempts_t4}}"
            _remediate_emit_escalation "ARTIFACT_MISSING" "$_tiers_attempted" "$_per_tier_json" "" "All tier artifacts unavailable"
            rm -rf "$_artifacts_dir"
            return 2
        fi
    done

    # Unreachable — while true exits via return above
    rm -rf "$_artifacts_dir"
    return 2
}

# --- _check_usage_for_remediate: wrapper for usage-check in _phase_remediate ---
# Allows tests to override via function definition without touching the env var path.
# Returns: 0=ok (not paused), 2=paused (THROTTLE_PAUSE)
_check_usage_for_remediate() {
    local _usage_cmd="${_REMEDIATE_CHECK_USAGE_CMD:-${CLAUDE_PLUGIN_ROOT}/scripts/check-usage.sh}"  # shim-exempt: internal plugin script
    "$_usage_cmd" >/dev/null 2>&1
    local _rc=$?
    [[ "$_rc" -eq 2 ]] && return 2
    return 0
}

# =============================================================================
# Library-mode guard: when sourced with PR_LIB_MODE=1, skip all top-level
# execution. Used by tests to load function definitions without running the
# phase pipeline.
# =============================================================================
# shellcheck disable=SC2317  # exit 0 is the non-sourced fallback; return is the sourced path
if [[ "${PR_LIB_MODE:-0}" == "1" ]]; then return 0 2>/dev/null || exit 0; fi

# =============================================================================
# Top-level execution begins here
# =============================================================================

if ! _check_gh_version; then
    exit 1
fi

# --- Initialize state file (best-effort; requires BRANCH set above) ---
# Initialize state BEFORE the duplicate-PR guard so --resume can read it.
if type _state_init >/dev/null 2>&1; then
    _state_init 2>/dev/null || true
fi

# --- Resume detection: when --resume is set and the state file already
# records a pr_url, skip _check_duplicate_pr and _phase_merge entirely
# (a PR exists from a prior run; re-running them would error out on the
# duplicate-PR guard or push a no-op duplicate). (b0ad-69ee)
_RESUME_STATE_PR_URL=""
if [[ "${_RESUME:-0}" -eq 1 ]] && type _state_file_path >/dev/null 2>&1; then
    _RESUME_SF=$(_state_file_path 2>/dev/null || true)
    if [[ -n "$_RESUME_SF" && -f "$_RESUME_SF" ]]; then
        _RESUME_STATE_PR_URL=$(_DSO_SF="$_RESUME_SF" python3 -c "
import json, os
try:
    print(json.load(open(os.environ['_DSO_SF'])).get('pr_url', ''))
except Exception:
    print('')
" 2>/dev/null || true)
    fi
fi

# Skip the duplicate-PR guard when resuming with a recorded PR.
if [[ -z "$_RESUME_STATE_PR_URL" ]]; then
    if ! _check_duplicate_pr; then
        exit 1
    fi
fi

# --- Run merge phase; on failure, emit CONFLICT_DATA contract line ---
# Always emitted for parity with direct mode (resolve-conflicts/SKILL.md relies on it).
# resolution_strategy distinguishes whether the failure was a push/create error or a
# CONFLICTING merge: "pr-create-failed" when no PR was created, "pr-conflict" when
# gh reported the PR as CONFLICTING.
# Skip _phase_merge entirely when --resume is set and a prior PR is recorded
# (b0ad-69ee). Re-running would attempt push + gh pr create against an existing
# branch/PR, hitting the duplicate-PR error.
_PHASE_MERGE_RC=0
if [[ -z "$_RESUME_STATE_PR_URL" ]]; then
    _phase_merge || _PHASE_MERGE_RC=$?
fi
if [[ "$_PHASE_MERGE_RC" -ne 0 ]]; then
    if type _emit_conflict_data >/dev/null 2>&1; then
        # Determine resolution strategy from state: if PR URL was written, the phase
        # reached the CONFLICTING check; otherwise failure was at push/create time.
        _MERGE_SF=""
        if type _state_file_path >/dev/null 2>&1; then
            _MERGE_SF=$(_state_file_path 2>/dev/null || true)
        fi
        _PR_URL_CHECK=""
        if [[ -n "$_MERGE_SF" && -f "$_MERGE_SF" ]]; then
            _PR_URL_CHECK=$(_DSO_SF="$_MERGE_SF" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['_DSO_SF']))
    print(d.get('pr_url', ''))
except Exception:
    print('')
" 2>/dev/null || true)
        fi
        _RESOLUTION_STRATEGY="pr-create-failed"
        [[ -n "$_PR_URL_CHECK" ]] && _RESOLUTION_STRATEGY="pr-conflict"
        _emit_conflict_data "$BRANCH" "main" "$_RESOLUTION_STRATEGY"
    fi
    exit 1
fi

# --- Resolve PR url + number for resolve_threads + polling (from state file written above) ---
_PR_URL=""
_PR_NUMBER=""
if type _state_file_path >/dev/null 2>&1; then
    _SF=$(_state_file_path 2>/dev/null || true)
    if [[ -n "$_SF" && -f "$_SF" ]]; then
        _PR_URL=$(_DSO_SF="$_SF" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['_DSO_SF']))
    print(d.get('pr_url', ''))
except Exception:
    print('')
" 2>/dev/null || true)
        _PR_NUMBER=$(_DSO_SF="$_SF" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['_DSO_SF']))
    n = d.get('pr_number', '')
    print(n if n != '' else '')
except Exception:
    print('')
" 2>/dev/null || true)
    fi
fi

if [[ -z "$_PR_NUMBER" ]]; then
    echo "ERROR: could not resolve PR number for polling phase" >&2
    exit 1
fi

# --- Local-only: surface any new PR comments since the last push ---
# In local sessions, reviewer feedback must be addressed by the session agent
# before merge can proceed. The check is a no-op in CI (returns 0).
if ! _phase_check_pr_comments_since_push "$_PR_NUMBER" "$_PR_URL"; then
    exit 1
fi

# --- Resolve review threads before polling for merge ---
if ! _phase_resolve_threads "$_PR_NUMBER" "$_PR_URL"; then
    exit 1
fi

# --- Queue auto-merge AFTER thread resolution (ea7b-0038) ---
# Enqueue only after _phase_resolve_threads succeeds. If thread resolution
# produced a new push, the branches are now in sync and CI will run on the
# correct base. If it failed (exit above), auto-merge is never queued.
if ! _phase_queue_auto_merge "$_PR_NUMBER"; then
    exit 1
fi

if ! _phase_poll "$_PR_NUMBER" "$_PR_URL"; then
    if ! _phase_conflict_resolution "$_PR_NUMBER" "$_PR_URL"; then
        exit 2
    fi
    _phase_remediate "$_PR_NUMBER" "$_PR_URL" || exit 2
fi

# =============================================================================
# Success exit path: verify merge commit on origin/main, then run lifecycle
# phases that direct.sh runs (version_bump → archive → ci_trigger).
# =============================================================================

# --- Step 1: fetch latest origin/main so we have the merge commit locally ---
# Use explicit refspec to ensure refs/remotes/origin/main is populated.
# `git fetch origin main` without refspec may only update FETCH_HEAD on some git
# versions (notably Ubuntu git 2.43+) without creating the tracking ref.
git fetch origin "main:refs/remotes/origin/main" --quiet 2>/dev/null || \
    git fetch origin main --quiet 2>/dev/null || {
        echo "WARNING: git fetch origin main failed — merge SHA verification may be stale." >&2
    }

# --- Step 2: get the merge commit SHA from the PR ---
MERGE_SHA=$(gh pr view "$_PR_NUMBER" --json mergeCommit --jq .mergeCommit.oid 2>/dev/null || true)
if [[ -z "$MERGE_SHA" ]]; then
    echo "ERROR: Could not retrieve merge commit SHA from PR #${_PR_NUMBER} (URL: ${_PR_URL})" >&2
    exit 1
fi

# --- Step 3: verify it appears on origin/main ---
# For squash merges, GitHub's mergeCommit.oid returns the source-branch HEAD SHA
# rather than the new squash commit on main. Fall back to git rev-parse origin/main
# (the actual tip after the merge) when the API SHA is absent from origin/main.
if ! git log origin/main --pretty=%H -n 50 2>/dev/null | grep -q "^${MERGE_SHA}$"; then
    _fallback_sha=$(git rev-parse origin/main 2>/dev/null || true)
    if [[ "$_fallback_sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "INFO: mergeCommit.oid (${MERGE_SHA}) not on origin/main — squash-merge fallback: using git rev-parse origin/main (${_fallback_sha})" >&2
        MERGE_SHA="$_fallback_sha"
    else
        echo "ERROR: PR reported merged but merge commit ${MERGE_SHA} not found on origin/main (PR: ${_PR_URL})" >&2
        exit 1
    fi
fi

echo "INFO: Merge commit ${MERGE_SHA} verified on origin/main."

# --- Step 4: persist merge SHA into state file ---
if type _state_record_merge_sha >/dev/null 2>&1; then
    _state_record_merge_sha "$MERGE_SHA" 2>/dev/null || true
fi

# =============================================================================
# Source merge-to-main-direct.sh in library mode to reuse the lifecycle phases.
# Set the globals direct.sh phase functions expect, then invoke them in order.
# =============================================================================

_DIRECT_SH="${CLAUDE_PLUGIN_ROOT}/scripts/merge-to-main-direct.sh"  # shim-exempt: internal plugin script
if [[ ! -f "$_DIRECT_SH" ]]; then
    echo "ERROR: merge-to-main-direct.sh not found at $_DIRECT_SH" >&2
    exit 1
fi

# Resolve MAIN_REPO and PRE_MERGE_SHA before sourcing (direct.sh phase functions
# use these as globals). PRE_MERGE_SHA is the SHA of origin/main before the
# merge — i.e., the parent of $MERGE_SHA on the main-line. Use git to derive it.
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
fi
MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir 2>/dev/null || echo "")")
if [[ -z "$MAIN_REPO" || "$MAIN_REPO" == "." ]]; then
    MAIN_REPO="$REPO_ROOT"
fi
export MAIN_REPO

# PRE_MERGE_SHA: first parent of the merge commit (the main-line tip before merge).
PRE_MERGE_SHA=$(git rev-parse "${MERGE_SHA}^1" 2>/dev/null || echo "")
export PRE_MERGE_SHA

# _CFG_TKDIR is referenced by _phase_archive (direct.sh).
_CFG_TKDIR=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" tickets.directory 2>/dev/null || true)  # shim-exempt: internal plugin script
_CFG_TKDIR="${_CFG_TKDIR:-.tickets-tracker}"
export _CFG_TKDIR

# Source direct.sh in library mode (defines functions only; no top-level exec).
# shellcheck source=./merge-to-main-direct.sh disable=SC1091
MERGE_TO_MAIN_DIRECT_LIB=1 source "$_DIRECT_SH"

# In PR mode, version_bump runs against the merged commit on origin/main. The
# local main may not be checked out; cd into MAIN_REPO before invoking the
# phase functions so their bare git operations target the main checkout.
# However, the local main branch likely doesn't have the merge commit yet
# (only origin/main does). Fast-forward local main to origin/main first so
# version_bump's amend operates on the merge commit.
if [[ -d "$MAIN_REPO/.git" ]] || [[ -f "$MAIN_REPO/.git" ]]; then
    (
        cd "$MAIN_REPO" 2>/dev/null || exit 0
        # Best-effort: fast-forward local main to origin/main so the merge
        # commit is present locally for downstream phases. Failures are
        # tolerated — the phases gracefully handle missing local state.
        git fetch origin main --quiet 2>/dev/null || true
        if [[ "$(git branch --show-current 2>/dev/null)" == "main" ]]; then
            git merge --ff-only origin/main --quiet 2>/dev/null || true
        fi
    )
fi

# Run the remaining lifecycle phases. Each function calls _state_mark_complete
# on success and `exit 1` on failure (inherited via set -e propagation through
# the source).
_phase_version_bump
_phase_archive
_phase_ci_trigger

# Clean up state + marker file on success (mirrors direct.sh tail).
if type _state_file_path >/dev/null 2>&1; then
    rm -f "$(_state_file_path)" 2>/dev/null || true
fi
rm -f "/tmp/merge-state-init-marker-${BRANCH//\//-}" 2>/dev/null || true

echo "DONE: $BRANCH merged via PR ${_PR_URL}, version-bumped, and CI lifecycle complete."
exit 0
