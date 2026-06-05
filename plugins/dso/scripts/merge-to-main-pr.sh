#!/usr/bin/env bash
# merge-to-main-pr.sh — PR merge mode for the merge-to-main pipeline.
#
# Creates a GitHub pull request from the current branch into main, waits
# for CI mergeability checks, and queues GitHub auto-merge. Used when
# dso.workflow=ci-pr (the canonical workflow knob, replacing the
# deprecated dso.workflow value). Direct merge mode lives in
# merge-to-main-direct.sh; merge-to-main.sh dispatches between the two.
#
# Responsibilities:
#   * gh CLI version gate (requires >= 2.0.0 for GraphQL features used by
#     PR-create and review-thread queries — DD7).
#   * Duplicate-PR guard: refuse to run when an open PR already exists
#     for the current branch (DD4).
#   * Full PR lifecycle: sync, push, gh pr create, mergeability polling,
#     auto-merge sequencing, review-thread resolution, trailer injection.
#   * CONFLICT_DATA contract parity with merge-to-main-direct.sh: emit
#     the same JSON conflict envelope via the shared _emit_conflict_data
#     helper in merge-helpers.sh (DD6 — PR side).
#
# Usage: merge-to-main-pr.sh [--resume|--help]
# Exit codes: 0=success, 1=error
set -euo pipefail
# In library mode (sourced by tests), relax set -e so that callers can inspect
# non-zero return codes from individual functions without the shell aborting.
if [[ "${PR_LIB_MODE:-0}" == "1" ]]; then
    set +e
fi

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

# --- Required env vars (or derived from config) ---
: "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set}"
if [[ "${PR_LIB_MODE:-0}" != "1" ]]; then
    # MERGE_STRATEGY may be set explicitly by the dispatcher (merge-to-main.sh)
    # OR derived here from dso-config.conf so the script is callable directly
    # (bug 17b7-80ff-2317-4587). Mirrors merge-to-main.sh's derivation logic:
    # dso.workflow=ci-pr -> MERGE_STRATEGY=pr; otherwise -> MERGE_STRATEGY=direct.
    if [[ -z "${MERGE_STRATEGY:-}" ]]; then
        _SCRIPT_DIR_FOR_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        _DERIVED_WORKFLOW="$(WORKFLOW_CONFIG_FILE="${WORKFLOW_CONFIG_FILE:-}" \
            bash "$_SCRIPT_DIR_FOR_CONFIG/read-config.sh" dso.workflow 2>/dev/null || echo "local")"
        if [[ "$_DERIVED_WORKFLOW" == "ci-pr" ]]; then
            MERGE_STRATEGY="pr"
        else
            MERGE_STRATEGY="direct"
        fi
        unset _SCRIPT_DIR_FOR_CONFIG _DERIVED_WORKFLOW
    fi
    # Export so python3 spawned by _state_init can read it via os.environ
    # (env-passthrough requirement; non-exported bash vars are invisible to os.environ).
    export MERGE_STRATEGY
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

# 3ebb DD1/DD3: review-gate tristate lattice + universal in-channel escalation
# (provides $TRISTATE_INDETERMINATE and tristate_indeterminate_escalation).
# Script-relative so it resolves under test regardless of ambient CLAUDE_PLUGIN_ROOT.
_REVIEW_TRISTATE_LIB="${DSO_REVIEW_TRISTATE_LIB:-$(dirname "${BASH_SOURCE[0]}")/lib/review-tristate-lib.sh}"
if [[ -f "$_REVIEW_TRISTATE_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$_REVIEW_TRISTATE_LIB"
fi

# --- Resolve default branch via resolver (F-05) ---
# Cached per merge-to-main run in $GIT_DIR/dso-default-branch — written here so
# subsequent invocations within the same run reuse the resolved value without
# re-running the precedence chain. Cache is per-clone (under .git/) and is not
# committed; deleted on each new merge-to-main invocation by merge-to-main.sh.
_RESOLVE_DEFAULT_BRANCH_SH="$(dirname "${BASH_SOURCE[0]}")/resolve-default-branch.sh"
if [[ -x "$_RESOLVE_DEFAULT_BRANCH_SH" ]]; then
    _GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || true)
    _DEFAULT_BRANCH_CACHE="${_GIT_DIR:+$_GIT_DIR/dso-default-branch}"
    if [[ -n "$_DEFAULT_BRANCH_CACHE" ]] && [[ -s "$_DEFAULT_BRANCH_CACHE" ]]; then
        _DEFAULT_BRANCH=$(cat "$_DEFAULT_BRANCH_CACHE")
    else
        _DEFAULT_BRANCH=$(bash "$_RESOLVE_DEFAULT_BRANCH_SH" --no-warn 2>/dev/null || echo "main")
        [[ -n "$_DEFAULT_BRANCH_CACHE" ]] && printf '%s' "$_DEFAULT_BRANCH" > "$_DEFAULT_BRANCH_CACHE" 2>/dev/null || true
    fi
else
    _DEFAULT_BRANCH="main"
fi
: "${_DEFAULT_BRANCH:=main}"

# --- Load CI findings normalization library ---
# shellcheck source=lib/ci-findings-normalize.sh
_FINDINGS_NORMALIZE_LIB="${CLAUDE_PLUGIN_ROOT}/scripts/lib/ci-findings-normalize.sh"  # shim-exempt: plugin-internal lib source
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
# Args: $1=phase (comments_since_push|resolve_threads|conflict_resolution|remediate),
#       $2=reason (one-line),
#       $3=instructions (what the session agent should do)
# Emits a JSON object to stdout describing the escalation. Caller chooses exit code.
#
# All escalations from this function direct the session agent to the canonical
# PR-finalize loop driver (PR-FINALIZE-WORKFLOW.md + pr-finalize-classify.sh).
# The 'instructions' field carries phase-specific context for the CURRENT iteration;
# 'next_action' is a stable structured handoff that does not vary by phase so a
# calling harness can detect the loop-driver target programmatically without
# parsing prose. Bug 9e06-e198-fb6f-4c39.
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
    'schema_version': 2,
    'escalation': 'local_no_llm_dispatch',
    'phase': os.environ.get('PHASE', ''),
    'reason': os.environ.get('REASON', ''),
    'instructions': os.environ.get('INSTR', ''),
    'next_action': {
        'workflow_doc': '\${CLAUDE_PLUGIN_ROOT}/docs/workflows/PR-FINALIZE-WORKFLOW.md',
        'loop_driver': '.claude/scripts/dso pr-finalize-classify.sh',
        'description': 'Read PR-FINALIZE-WORKFLOW.md and drive the PR to merge via pr-finalize-classify.sh. Do not re-run merge-to-main.sh.',
    },
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
            "Session agent must read each new PR comment and address the feedback (push fixes or reply), then drive the PR to merge via \${CLAUDE_PLUGIN_ROOT}/docs/workflows/PR-FINALIZE-WORKFLOW.md using pr-finalize-classify.sh. Do not re-run merge-to-main.sh."
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
# `gh pr list --head $BRANCH --state open --json number,url,isDraft`.
# Non-empty result of non-draft PRs → a non-draft open PR exists → exit non-zero.
# Draft PRs are allowed (e.g. active sprint PRs) and are filtered out.
# Best-effort: if gh fails (no auth, no remote, etc.), proceed — the downstream
# PR-create call in Task 3 will surface the underlying error with full context.
#
# Callers of this function (updated when new consumers added):
#   sprint/SKILL.md Phase I → /dso:end-session → merge-to-main.sh → here
#     (sprint Phase A creates a draft PR; draft filtered out, guard passes)
#   debug-everything/SKILL.md Phase L → merge-to-main.sh → here
#     (no draft PR created; guard passes when no non-draft PR exists)
#   end-session/SKILL.md → merge-to-main.sh → here
#     (no draft PR; guard passes)
#   fix-bug/SKILL.md → /dso:end-session → merge-to-main.sh → here
#     (no draft PR; guard passes)
_check_duplicate_pr() {
    local _existing
    _existing=$(gh pr list --head "$BRANCH" --state open --json number,url,isDraft 2>/dev/null \
        | jq -r 'map(select(.isDraft == false)) | .[0].url // empty' 2>/dev/null || true)
    if [[ -n "$_existing" ]]; then
        echo "ERROR: non-draft PR already exists for branch $BRANCH: $_existing" >&2
        return 1
    fi
    return 0
}

# --- _query_pr_is_draft: emit "true" or "false" for a PR's draft status ---
_query_pr_is_draft() {
    local _pr_number="$1"
    local _json
    _json=$(gh pr view "$_pr_number" --json isDraft 2>/dev/null || true)
    printf '%s' "$_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('true' if d.get('isDraft') else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo 'false'
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

# --- _phase_prebump_feature_sync (0f17 DD1/DD2): pinned pre-bump feature-sync ----
# BEFORE the source-branch version bump, rebase the feature branch onto the SAME
# origin/main SHA the staged ref was just cut from (PINNED — re-fetching origin/main
# would reopen the version conflict via TOCTOU). This makes PR1's version line
# single-sided so feat→staged merges cleanly, WITHOUT moving the bump off the reviewed
# path: the rebased (un-reviewed) feature commits are reviewed FRESH by PR1's
# review-sub-pr — no coverage exemption, no bypass actor.
#
# SECURITY GUARDRAIL (non-negotiable): NEVER force-push a branch already under
# in-flight review (that would re-credit a review onto a rewritten SHA). This runs
# ONLY before the branch is pushed / PR1 exists; it SKIPS idempotently when
# origin/<BRANCH> already exists (resume-safe per DD2).
#
# Arg: $1 = pinned origin/main SHA (the staged ref's tip).
# Returns: 0 = synced or safely skipped; 1 = CODE conflict (caller escalates, with the
#          pre-image patch) or a hard error. On any failure HEAD is restored to its
#          exact pre-rebase commit (abort-restore; always:patch-before-destructive).
_phase_prebump_feature_sync() {
    local _pinned_sha="${1:-}"
    if [[ -z "$_pinned_sha" ]]; then
        echo "ERROR: prebump-sync: empty pinned main SHA — fail closed" >&2
        return 1
    fi

    # DD2 idempotency / in-flight-review guard: if the source branch is already on the
    # remote, PR1 may be in flight — rewriting+force-pushing would re-credit a review
    # onto a new SHA. NEVER do that. Skip (resume-safe).
    if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
        echo "INFO: prebump-sync skipped — origin/$BRANCH already exists (never force-push under in-flight review)"
        return 0
    fi

    # Ensure the pinned SHA is available locally (fail closed if it cannot be obtained;
    # a bare/old fixture remote may reject single-SHA fetch, so fall back to the
    # default-branch fetch then re-check the object store).
    if ! git cat-file -e "${_pinned_sha}^{commit}" 2>/dev/null; then
        git fetch origin "${_DEFAULT_BRANCH:-main}" 2>/dev/null || true
        git fetch origin "$_pinned_sha" 2>/dev/null || true
        if ! git cat-file -e "${_pinned_sha}^{commit}" 2>/dev/null; then
            echo "ERROR: prebump-sync: pinned main SHA ${_pinned_sha} not available locally — fail closed (no rebase)" >&2
            return 1
        fi
    fi

    # Already based on the pinned main (pinned is an ancestor of HEAD) → clean PR1
    # merge already; nothing to rebase.
    if git merge-base --is-ancestor "$_pinned_sha" HEAD 2>/dev/null; then
        echo "INFO: prebump-sync: $BRANCH already based on pinned main ${_pinned_sha:0:12} — no rebase needed"
        return 0
    fi

    # always:patch-before-destructive — capture a pre-image patch of the feature
    # commits BEFORE the rebase, and remember the exact pre-rebase HEAD for restore.
    local _pre_head _preimg
    _pre_head=$(git rev-parse HEAD 2>/dev/null) || {
        echo "ERROR: prebump-sync: cannot resolve HEAD — fail closed" >&2
        return 1
    }
    _preimg="$(mktemp "/tmp/prebump-sync-preimage.XXXXXX.patch")"
    if ! git format-patch --stdout "${_pinned_sha}..HEAD" > "$_preimg" 2>/dev/null; then
        git diff "${_pinned_sha}..HEAD" > "$_preimg" 2>/dev/null || true
    fi
    echo "INFO: prebump-sync: pre-image patch saved to $_preimg (pre-rebase HEAD ${_pre_head:0:12})"

    # Rebase the feature commits onto the pinned main SHA. Abort + hard-restore on any
    # failure so a CODE conflict leaves the branch exactly as it was (the caller
    # escalates via CONFLICT_DATA rather than proceeding to bump/push a half-rebased
    # branch).
    local _rb_out _rb_rc=0
    _rb_out=$(git rebase "$_pinned_sha" 2>&1) || _rb_rc=$?
    if [[ "$_rb_rc" -ne 0 ]]; then
        git rebase --abort 2>/dev/null || true
        git reset --hard "$_pre_head" 2>/dev/null || true
        if [[ "$_rb_out" == *"CONFLICT"* || "$_rb_out" == *"could not apply"* ]]; then
            echo "ERROR: prebump-sync: CODE conflict rebasing $BRANCH onto pinned main ${_pinned_sha:0:12} — aborted + restored HEAD ${_pre_head:0:12}; pre-image at $_preimg" >&2
            echo "PREBUMP_SYNC_CONFLICT pinned=${_pinned_sha} preimage=${_preimg} restored_head=${_pre_head}" >&2
            return 1
        fi
        echo "ERROR: prebump-sync: rebase onto pinned main failed (non-conflict) — aborted + restored HEAD ${_pre_head:0:12}: ${_rb_out:0:200}" >&2
        rm -f "$_preimg" 2>/dev/null || true
        return 1
    fi

    echo "INFO: prebump-sync: rebased $BRANCH onto pinned main ${_pinned_sha:0:12} (single-sided version line → clean PR1 merge)"
    if type _state_mark_complete >/dev/null 2>&1; then
        _state_mark_complete "prebump_feature_sync" 2>/dev/null || true
    fi
    rm -f "$_preimg" 2>/dev/null || true
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
# --- _derive_pr_title: build a PR title that survives merge-back commits ---
#
# Args: $1=branch
# Output (stdout): a single-line PR title.
#
# Priority order:
#   1. Latest non-merge commit subject reachable from HEAD but not from main
#      (the work the branch actually contributes). If absent, fall back to the
#      latest non-merge commit on HEAD overall.
#   2. If that subject already starts with `[<id>]`, return it as-is.
#   3. Otherwise, try to extract a ticket id from any DSO-Story / DSO-Task
#      trailer or any branch-local `[<id>]`-prefixed commit subject; if found,
#      prefix the chosen subject with `[<id>] `.
#   4. Fallback (no non-merge commit exists, e.g. branch only carries a
#      merge-back commit): emit `[<branch>] <truncated-merge-subject>`.
#
# Bug 85b8-2576: prior code used `git log -1 --pretty=%s`, which after a
# merge-back from origin/main returned the uninformative merge subject.
_derive_pr_title() {
    local _branch="${1:-unknown}"
    local _subject="" _id="" _scan="" _trailer_id="" _bracket_id=""

    # 1. Prefer a non-merge commit unique to the branch (main..HEAD), then
    #    origin/main..HEAD as a fallback when local main is stale or absent.
    #
    # Retro-review of PR #171 found the prior third fallback
    # `git log --no-merges -1 --pretty=%s` (no range) read from main's history
    # when the branch had no non-merge commits of its own (pure-cleanup
    # branches, merge-only branches). That produced a title derived from a
    # main commit and bypassed the documented priority-4 [branch] fallback.
    # Drop the rangeless fallback — leaving _subject empty falls through to
    # the priority-4 `[<branch>] <merge-subject>` path below, which is the
    # documented behavior for pure-cleanup branches.
    # F-05: use resolved default branch (_DEFAULT_BRANCH) instead of literal "main"
    # so commit ranges work on host repos using master/develop/trunk.
    local _db="${_DEFAULT_BRANCH:-main}"
    # Skip pipeline-emitted `chore: bump version to v...` commits (line 711 of this
    # script emits them on the source branch before _derive_pr_title is called).
    # Walk back to the latest non-merge non-bump subject. (bug dd0c-06cf-83ed-4941)
    _subject=$(git log --no-merges --pretty=%s "${_db}..HEAD" 2>/dev/null | grep -v '^chore: bump version to ' | head -n 1 || true)
    if [[ -z "$_subject" ]]; then
        _subject=$(git log --no-merges --pretty=%s "origin/${_db}..HEAD" 2>/dev/null | grep -v '^chore: bump version to ' | head -n 1 || true)
    fi

    # 2. Already prefixed → return as-is.
    if [[ "$_subject" =~ ^\[[A-Za-z0-9._/-]+\] ]]; then
        printf '%s\n' "$_subject"
        return 0
    fi

    # 3a. Look for a DSO-Story / DSO-Task trailer on any branch-local commit.
    # Scope to main..HEAD / origin/main..HEAD; do NOT fall back to the
    # rangeless `git log -n 50` form — that scans main's history on a
    # pure-cleanup branch and can extract an unrelated DSO-Story id from a
    # main commit, producing a misleading PR-title prefix (PR #171 retro-
    # review finding).
    _scan=$(git log --pretty=format:%B "${_db}..HEAD" 2>/dev/null || true)
    if [[ -z "$_scan" ]]; then
        _scan=$(git log --pretty=format:%B "origin/${_db}..HEAD" 2>/dev/null || true)
    fi
    _trailer_id=$(printf '%s\n' "$_scan" \
        | grep -Eiom1 '^[[:space:]]*DSO-(Story|Task):[[:space:]]*[A-Za-z0-9._/-]+' \
        | sed -E 's/^[[:space:]]*DSO-(Story|Task):[[:space:]]*//I' \
        || true)

    # 3b. If no trailer, look for an earlier commit subject with leading [id].
    if [[ -z "$_trailer_id" ]]; then
        _bracket_id=$(git log --pretty=format:%s "${_db}..HEAD" 2>/dev/null \
            | grep -Eom1 '^\[[A-Za-z0-9._/-]+\]' \
            | sed -E 's/^\[(.+)\]$/\1/' \
            || true)
        if [[ -z "$_bracket_id" ]]; then
            # Scope to origin/<default>..HEAD as the second-priority range, not the
            # rangeless `git log -n 50` form which would scan the integration
            # branch's history on a pure-cleanup branch (same root cause as the
            # _scan fix above).
            _bracket_id=$(git log --pretty=format:%s "origin/${_db}..HEAD" 2>/dev/null \
                | grep -Eom1 '^\[[A-Za-z0-9._/-]+\]' \
                | sed -E 's/^\[(.+)\]$/\1/' \
                || true)
        fi
        _id="$_bracket_id"
    else
        _id="$_trailer_id"
    fi

    # 4. Fallback when no non-merge subject was found at all.
    if [[ -z "$_subject" ]]; then
        local _fallback_subject
        _fallback_subject=$(git log -1 --pretty=%s 2>/dev/null || true)
        # Truncate excessively long merge subjects for readability.
        if [[ "${#_fallback_subject}" -gt 120 ]]; then
            _fallback_subject="${_fallback_subject:0:117}..."
        fi
        if [[ -z "$_fallback_subject" ]]; then
            _fallback_subject="Merge $_branch"
        fi
        printf '[%s] %s\n' "$_branch" "$_fallback_subject"
        return 0
    fi

    if [[ -n "$_id" ]]; then
        printf '[%s] %s\n' "$_id" "$_subject"
    else
        printf '%s\n' "$_subject"
    fi
}

# --- _derive_pr_body: build a PR body listing the branch's commit subjects ---
#
# Args: $1=branch, $2=base ref (default: "main")
# Output (stdout): markdown body — a "## Commits" section with one bullet per
#                  non-merge commit on the branch, in chronological order.
#
# Range selection: prefer origin/<base>..HEAD (the canonical "not yet on the
# remote base" range); fall back to local <base>..HEAD only when origin/<base>
# is unresolvable (offline / first push). The earlier order (local first, fall
# back on empty) was wrong: when local <base> is STALE vs origin/<base> — the
# norm in active worktree workflows, since nobody routinely fast-forwards
# local main — the local range includes BOTH branch-local commits AND every
# commit that landed on origin/<base> since local <base> last moved (squash
# merges from prior PRs, version-bump fast-forwards, etc). The empty-fallback
# never triggers in that case because the branch-local commits keep the
# subjects list non-empty, so unrelated commits leak into the PR body.
# Merge commits are excluded (they're noise like "Merge remote-tracking
# branch 'origin/main' into worktree-XYZ"). Falls back to the legacy
# auto-generated message when no branch-local commits are found
# (pure-cleanup branches).
_derive_pr_body() {
    local _branch="${1:-unknown}"
    local _base="${2:-${_DEFAULT_BRANCH:-main}}"
    local _subjects=""

    local _range_used=""
    if git rev-parse --verify --quiet "origin/${_base}" >/dev/null 2>&1; then
        _subjects=$(git log --no-merges --reverse --format="- %s" "origin/${_base}..HEAD" 2>/dev/null || true)
        _range_used="origin/${_base}..HEAD"
    fi
    if [[ -z "$_subjects" ]]; then
        _subjects=$(git log --no-merges --reverse --format="- %s" "${_base}..HEAD" 2>/dev/null || true)
        _range_used="${_base}..HEAD"
    fi

    if [[ -z "$_subjects" ]]; then
        # shellcheck disable=SC2016  # backticks here are literal markdown, not command substitution
        printf 'Auto-generated PR for branch `%s` (created by merge-to-main-pr.sh).\n' "$_branch"
        return 0
    fi

    # shellcheck disable=SC2016  # backticks here are literal markdown, not command substitution
    printf '## Commits\n\n%s\n\n---\n_Auto-generated by merge-to-main-pr.sh from `git log --no-merges %s`._\n' "$_subjects" "$_range_used"
}

# --- _phase_source_branch_version_bump (PR mode): bump version ON THE SOURCE
# BRANCH before pushing, so the bump lands in main as part of the PR's
# squash-merge commit (not as a separate post-merge commit on main).
#
# Architectural fix for b6e3-e771 + bbba-123d:
#   - Eliminates the post-merge non-amend commit on main that diverged main from
#     the PR's merged content.
#   - Sidesteps pre-commit-compliance-verifier rejection: the bump commit is
#     made on the session worktree, which the verifier's ci-pr worktree
#     exemption (pre-commit-compliance-verifier.sh:42-53) already skips.
#
# Args: $1=story_id (used to construct DSO-Story trailer on the bump commit)
#
# Behavior:
#   - Reads version.file_path from dso-config.conf (via bump-version.sh).
#   - Defaults BUMP_TYPE to 'patch' when unset and version.file_path is set.
#   - Calls bump-version.sh to increment the version file.
#   - Stages and commits with subject `chore: bump version to v${new_ver}` and
#     a `DSO-Story: <story_id>` trailer.
#   - Resume idempotency: if HEAD is already a "chore: bump version to v..."
#     commit (prior resume attempt completed this phase), skip without
#     re-bumping (otherwise versions would cascade 1.17.6 → 1.17.7 → 1.17.8).
#   - No-op when version.file_path is unset / empty (mirrors _phase_version_bump).
#
# Returns: 0 on success or no-op, 1 on bump/commit failure.
_phase_source_branch_version_bump() {
    local _story_id="${1:-}"

    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "source_branch_version_bump" 2>/dev/null || true
    fi

    # --- Two-tier flow: do NOT bump on a staged-* source branch. ---
    # When BRANCH is staged-*, we are in the PR2 (staged-*→main) phase. The bump
    # was already applied on the FEATURE branch during PR1 (_phase_staged_intermediate)
    # and flowed into staged via PR1's merge, so it rides through PR2 into main.
    # Pushing a fresh bump commit directly to the protected staged-* branch here
    # would be REJECTED by the sub-PR ruleset (required_status_checks{review-sub-pr};
    # do_not_enforce_on_create exempts create, NOT update) because the bump commit
    # has no passing review-sub-pr and the non-admin agent cannot bypass. Skip.
    if [[ "$BRANCH" == staged-* ]]; then
        echo "INFO: BRANCH is staged-* (PR2 phase) — version bump already applied on the feature branch during PR1; skipping source-branch bump (two-tier flow)."
        if type _state_mark_complete >/dev/null 2>&1; then
            _state_mark_complete "source_branch_version_bump" 2>/dev/null || true
        fi
        return 0
    fi

    # --- Resume idempotency: skip when HEAD is already a bump commit. ---
    # Pattern matches the commit subject emitted below: `chore: bump version to v...`.
    # Without this guard, a --resume after a successful bump would cascade the
    # version on every retry.
    local _head_subject
    _head_subject=$(git log -1 --pretty=%s 2>/dev/null || true)
    if [[ "$_head_subject" =~ ^chore:\ bump\ version\ to\ v ]]; then
        echo "INFO: HEAD is already a version-bump commit ('$_head_subject') — skipping source-branch bump (resume idempotency)."
        if type _state_mark_complete >/dev/null 2>&1; then
            _state_mark_complete "source_branch_version_bump" 2>/dev/null || true
        fi
        return 0
    fi

    # --- Read version.file_path from config (best-effort). ---
    local _vfp_from_config=""
    if [[ -n "${VERSION_FILE_PATH:-}" ]]; then
        _vfp_from_config="$VERSION_FILE_PATH"
    elif [[ -f "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" ]]; then  # shim-exempt: plugin-internal script via CLAUDE_PLUGIN_ROOT
        _vfp_from_config=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" version.file_path 2>/dev/null || true)  # shim-exempt: plugin-internal script via CLAUDE_PLUGIN_ROOT
    fi

    if [[ -z "$_vfp_from_config" ]]; then
        echo "INFO: version.file_path not configured — skipping source-branch version bump."
        if type _state_mark_complete >/dev/null 2>&1; then
            _state_mark_complete "source_branch_version_bump" 2>/dev/null || true
        fi
        return 0
    fi

    # --- Default BUMP_TYPE to 'patch' when unset. ---
    local _bump_type="${BUMP_TYPE:-}"
    if [[ -z "$_bump_type" ]]; then
        _bump_type="patch"
        echo "INFO: --bump not specified — defaulting to patch (version.file_path configured)."
    fi

    # --- Invoke bump-version.sh. The script writes the new version to the
    # configured file and prints `Version bumped: X → Y (path)` to stdout. ---
    local _bs _bump_out _bump_rc=0
    _bs=$(command -v bump-version.sh 2>/dev/null || echo "${CLAUDE_PLUGIN_ROOT}/scripts/bump-version.sh")  # shim-exempt: internal plugin script
    if [[ ! -f "$_bs" ]]; then
        echo "ERROR: bump-version.sh not found at $_bs" >&2
        return 1
    fi

    # Idempotency guard for uncommitted state: if the version file is already
    # modified on disk from a prior interrupted attempt, skip bump-version.sh.
    if [[ -f "$_vfp_from_config" ]] && ! git diff --quiet -- "$_vfp_from_config" 2>/dev/null; then
        echo "INFO: version file already bumped (uncommitted prior attempt) — skipping bump-version.sh."
    else
        echo "Bumping version (--${_bump_type})..."
        _bump_out=$(bash "$_bs" "--${_bump_type}" 2>&1) || _bump_rc=$?
        if [[ "$_bump_rc" -ne 0 ]]; then
            echo "ERROR: bump-version.sh failed: $_bump_out" >&2
            return 1
        fi
        printf '%s\n' "$_bump_out"
    fi

    # --- Derive the new version string from the bumped file. ---
    local _new_ver="unknown"
    if [[ -f "$_vfp_from_config" ]]; then
        local _ext _basename
        _ext="${_vfp_from_config##*.}"
        _basename="$(basename "$_vfp_from_config")"
        if [[ "$_basename" == "$_ext" || "$_basename" == ".$_ext" ]]; then
            _ext=""
        fi
        case "$_ext" in
            json)
                _new_ver=$(_VF="$_vfp_from_config" python3 -c "import json,os;f=open(os.environ['_VF']);d=json.load(f);f.close();print(d.get('version','unknown'))" 2>/dev/null || echo "unknown")
                ;;
            toml)
                _new_ver=$(grep -m1 '^version = ' "$_vfp_from_config" 2>/dev/null | sed -E 's/^version = "(.*)"$/\1/' || echo "unknown")
                [[ -z "$_new_ver" ]] && _new_ver="unknown"
                ;;
            *)
                _new_ver=$(tr -d '[:space:]' < "$_vfp_from_config" 2>/dev/null || echo "unknown")
                [[ -z "$_new_ver" ]] && _new_ver="unknown"
                ;;
        esac
    fi
    echo "OK: Version bumped to ${_new_ver}."

    # --- Sync package-lock.json if the bumped file is package.json. ---
    if [[ "$_vfp_from_config" == *"package.json" ]] && command -v npm >/dev/null 2>&1; then
        local _pkg_dir
        _pkg_dir=$(dirname "$_vfp_from_config")
        echo "source_branch_version_bump: running npm install --package-lock-only to sync package-lock.json"
        (cd "$_pkg_dir" && npm install --package-lock-only --quiet 2>/dev/null) || \
            echo "WARNING: npm install --package-lock-only failed — package-lock.json may be out of sync"
    fi

    # --- Stage and commit on the session branch. ---
    git add -u 2>/dev/null || true
    if git diff --cached --quiet 2>/dev/null; then
        echo "INFO: No staged changes after bump — skipping commit (already up-to-date)."
        if type _state_mark_complete >/dev/null 2>&1; then
            _state_mark_complete "source_branch_version_bump" 2>/dev/null || true
        fi
        return 0
    fi

    # Commit with DSO-Story trailer so verify-session-provenance.sh accepts the
    # commit on the session branch (S1.T5: DSO-Story(-Merge)?: grammar).
    # The story_id may be empty when invoked outside a sprint context — in that
    # case emit a placeholder so the trailer regex still matches.
    local _trailer_id="${_story_id:-unknown}"
    local _commit_msg
    _commit_msg=$(printf 'chore: bump version to v%s\n\nDSO-Story: %s\n' "$_new_ver" "$_trailer_id")
    if ! git commit -m "$_commit_msg" --quiet; then
        echo "ERROR: git commit failed for source-branch version bump." >&2
        return 1
    fi
    echo "OK: Version bump committed on source branch (v${_new_ver})."

    if type _state_mark_complete >/dev/null 2>&1; then
        _state_mark_complete "source_branch_version_bump" 2>/dev/null || true
    fi
    return 0
}

# ── PR-C: staged-* promotion intermediate ────────────────────────────────────
#
# Two-tier promotion model (PR-B):
#
#   feature-branch / worktree-<ts>  (unrestricted)
#       ↓ PR1 — review-sub-pr workflow required (sub-PR ruleset)
#   staged-<short-sha>-<unix-ts>
#       ↓ PR2 — check-staged-head + main required checks (main ruleset)
#   main
#
# The sub-PR ruleset (16961402) enforces `review-sub-pr.yml` via a
# `required_workflows` rule. That rule evaluates at PR-MERGE time, not at
# ref-update time — so creating staged-<sha>-<ts> from origin/main HEAD and
# pushing the worktree's commits via PR1 is unrestricted.
#
# The main ruleset (15629023) requires `check-staged-head` to pass on every
# PR to main, ensuring only staged-* heads can land.
#
# This phase runs BEFORE _phase_merge in the session→main path (no
# STORY_PR_BASE). It creates the staged-* ref, opens PR1, waits for
# review-sub-pr, merges PR1, then re-points BRANCH to the staged-* branch so
# the subsequent _phase_merge opens PR2 (staged-* → main).
#
# Skip conditions (only the two legitimate-skip cases — no opt-out env var):
#   - STORY_PR_BASE set: story-PR mode, base is not main, nothing to do
#   - BRANCH already matches staged-*: caller (or prior --resume) already
#     ran this phase; skip
#   - Origin is not github.com: tests / local fixtures cannot create the
#     staged ref via gh api; no-op
#
# DSO_SKIP_STAGED_INTERMEDIATE=1 was removed in PR-R1 (post-audit Finding 3).
# The flag had no documented operational use case but did create a silent
# bypass of the comprehensive review gate (PR1). Under the two-tier model
# `verify-session-provenance.sh` no longer accepts trailer self-attestation
# as evidence of review (v4 cache), so a bypass of PR1 would now correctly
# fail provenance at PR2 time anyway — but removing the bypass surface is
# cleaner than tolerating it.

_create_staged_ref() {
    # Print the new staged-* branch name on stdout. Return 0 on success.
    # Hard-fails if the ref already exists (collision risk).
    local _short_sha _unix_ts _staged_name _main_sha _gh_repo
    _short_sha=$(git rev-parse --short=12 HEAD 2>/dev/null) || {
        echo "ERROR: _create_staged_ref: cannot resolve HEAD" >&2
        return 1
    }
    _unix_ts=$(date +%s)
    _staged_name="staged-${_short_sha}-${_unix_ts}"

    # Resolve the GitHub repo (owner/name) from the current working directory.
    # `gh` infers the repo from origin's remote URL.
    _gh_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
        echo "ERROR: _create_staged_ref: cannot resolve GitHub repo via gh repo view" >&2
        return 1
    }

    # Resolve origin/main HEAD via the GitHub API (authoritative for ref
    # creation). The script's local origin/main may be stale.
    _main_sha=$(gh api "repos/${_gh_repo}/branches/${_DEFAULT_BRANCH:-main}" \
        --jq '.commit.sha' 2>/dev/null) || {
        echo "ERROR: _create_staged_ref: cannot resolve origin/main HEAD via gh api" >&2
        return 1
    }

    # Create the ref. POST /git/refs returns 422 if the ref already exists —
    # we hard-fail on that to avoid silent collisions across concurrent sessions.
    local _create_out _create_rc=0
    _create_out=$(gh api -X POST "repos/${_gh_repo}/git/refs" \
        -f "ref=refs/heads/${_staged_name}" \
        -f "sha=${_main_sha}" 2>&1) || _create_rc=$?
    if [[ "$_create_rc" -ne 0 ]]; then
        echo "ERROR: failed to create staged-* ref ${_staged_name}: $_create_out" >&2
        return 1
    fi

    echo "$_staged_name"
    return 0
}

# _resume_should_advance_to_staged <pr1_open_count> <staged_exists_count> <staged_work_count>
# Resume hardening: decide whether to SKIP the PR1 phase and advance straight to
# PR2 (staged-*→main). True iff PR1 (source→staged) is no longer open (i.e. it
# merged) AND the staged branch still exists on the remote AND the staged branch
# actually CARRIES the session work (commits ahead of main > 0). Any "unknown"
# (gh/git failure → callers pass the fail-safe defaults pr1_open=1, staged=0,
# work=0) makes this FALSE, so resume falls back to the normal flow rather than
# risking a wrong advance.
#
# The third arg (staged_work_count) closes bug b7bf-c3b9: an EMPTY staged-* ref
# sitting at main HEAD (work=0) previously satisfied pr1_open=0 + staged_exists=1
# and advanced, causing the resume to claim "PR1 merged" when no work had reached
# main and to lose the version bump. A missing or non-numeric third arg defaults
# to FALSE (fail-closed), so an un-migrated caller can never wrongly advance.
#
# Closes the gap where a crash after PR1 merged but before the local checkout to
# staged-* left a later resume re-creating a duplicate staged ref+PR1 (the
# worktree-checkout-derived BRANCH was stale; staged_branch is instead read from
# the source-branch-keyed state file, which is checkout-independent).
_resume_should_advance_to_staged() {
    [[ "${1:-1}" == "0" && "${2:-0}" != "0" && "${3:-0}" != "0" && "${3:-0}" =~ ^[0-9]+$ ]]
}

# resume_pr_query_trustworthy <gh_rc> <json_payload>
# 3ebb DD2 — INC-008 GUARD (LOAD-BEARING). When --resume reconstructs pipeline
# state from GitHub PR state, a PR-query result is trustworthy as AUTHORITATIVE
# only when the call SUCCEEDED (rc 0) AND returned a well-formed JSON payload. A
# non-zero rc, an empty payload, or malformed/truncated JSON (e.g. a page cut
# short) is INDETERMINATE — the caller MUST re-fetch or escalate, and MUST NOT
# treat a short/empty result as authoritative "no PRs". Acting on partial state
# as authoritative-empty is the INC-008 stall (a duplicate staged-*+PR1, or a
# lost live session). A legitimately-empty list ("[]", rc 0) is well-formed and
# IS trusted — that is the case this guard deliberately distinguishes from a
# truncated read.
#   returns 0  = trustworthy (safe to parse, including a real empty list)
#   returns 75 = INDETERMINATE (TRISTATE_INDETERMINATE — re-fetch/escalate)
resume_pr_query_trustworthy() {
    local _rc="${1:-1}" _json="${2:-}"
    [[ "$_rc" == "0" ]] || return 75              # the call itself failed
    [[ -n "$_json" ]] || return 75                # empty payload ≠ "[]"
    printf '%s' "$_json" | python3 -c "import json,sys; json.load(sys.stdin)" >/dev/null 2>&1 || return 75
    return 0
}

# resume_staged_ref_is_spent <commits_ahead_of_main>
# 3ebb DD2 / INC-015: a staged-* ref is SPENT when it carries 0 commits ahead of
# origin/main — its content already merged (a completed promotion) or it is an
# empty placeholder. A spent staged-* must NOT be driven as a live PR2 source —
# that produced the confusing 'No commits between main and staged-*' stall when a
# worktree was left checked out on a leftover staged-* alongside a stale /tmp
# state file. Fail-safe: a non-numeric/empty count is NOT spent (never skip/GC on
# uncertainty — only a definitively-0 ahead-count is spent).
#   returns 0 = spent (refuse as PR2 source / safe to GC its cache)
#   returns 1 = not spent (live, or unknown)
resume_staged_ref_is_spent() {
    local _ahead="${1:-}"
    [[ "$_ahead" =~ ^[0-9]+$ ]] || return 1
    (( _ahead == 0 ))
}

# resume_gc_stale_staged_state [state_dir]
# 3ebb DD2 / INC-015 (b): the /tmp/merge-to-main-state-*.json files are a CACHE,
# not the source of truth (GitHub + git are). Garbage-collect the cache entries
# for staged-* branches that are GONE from origin or SPENT (already merged), so a
# later --resume can never reconstruct off a stale promotion's state. Best-effort;
# never fails the run. state_dir defaults to /tmp (overridable for tests).
resume_gc_stale_staged_state() {
    local _dir="${1:-/tmp}" _db="${_DEFAULT_BRANCH:-main}" _sf _b _ahead
    git fetch origin "$_db" --quiet 2>/dev/null || true
    for _sf in "$_dir"/merge-to-main-state-staged-*.json; do
        [[ -f "$_sf" ]] || continue
        _b="${_sf##*/merge-to-main-state-}"; _b="${_b%.json}"
        if ! git ls-remote --heads origin "$_b" 2>/dev/null | grep -q .; then
            rm -f "$_sf" 2>/dev/null || true; continue          # branch gone -> spent
        fi
        git fetch origin "$_b" --quiet 2>/dev/null || true
        _ahead=$(git rev-list --count "origin/${_db}..origin/${_b}" 2>/dev/null || echo "")
        if resume_staged_ref_is_spent "$_ahead"; then rm -f "$_sf" 2>/dev/null || true; fi
    done
}

_phase_staged_intermediate() {
    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "staged_intermediate" 2>/dev/null || true
    fi

    # Skip conditions
    if [[ -n "${STORY_PR_BASE:-}" ]]; then
        echo "INFO: staged-intermediate phase skipped (STORY_PR_BASE set; story-PR mode)"
        return 0
    fi
    if [[ "$BRANCH" == staged-* ]]; then
        echo "INFO: staged-intermediate phase skipped (BRANCH is already staged-*: $BRANCH)"
        return 0
    fi
    # DSO_SKIP_STAGED_INTERMEDIATE opt-out removed in PR-R1 (post-audit). If
    # the env var is set, treat it as a hard error: it would bypass the
    # comprehensive review gate without recourse.
    if [[ -n "${DSO_SKIP_STAGED_INTERMEDIATE:-}" ]]; then
        echo "ERROR: DSO_SKIP_STAGED_INTERMEDIATE is no longer supported (removed in PR-R1)." >&2
        echo "ERROR: The staged-* intermediate is now mandatory for session→main flows." >&2
        echo "" >&2
        echo "MIGRATION GUIDE:" >&2
        echo "  Legitimate use cases the flag previously served, with new alternatives:" >&2
        echo "" >&2
        echo "  1. 'I am testing merge-to-main without wanting to actually push':" >&2
        echo "     Use DSO_DRY_RUN=1 instead — emits the planned PR payload to stdout" >&2
        echo "     without hitting the GitHub API." >&2
        echo "" >&2
        echo "  2. 'I need to land an emergency fix that bypasses review-sub-pr':" >&2
        echo "     Use /dso:fp-recovery <pr_number>. The skill handles the bypass" >&2
        echo "     atomically and creates an audit-trail entry — DSO_SKIP_STAGED_INTERMEDIATE" >&2
        echo "     never did either." >&2
        echo "" >&2
        echo "  3. 'I want to revert the two-tier model':" >&2
        echo "     Revert PR-C, PR-R1, and the ruleset PATCHes per" >&2
        echo "     docs/runbooks/rulesets-rollback.md — a wholesale rollback is the" >&2
        echo "     correct path, not a per-invocation bypass." >&2
        echo "" >&2
        echo "  Audit ref: docs/handoff/llm-review-enforcement-handoff.md (post-audit Finding 3)." >&2
        return 1
    fi
    # Auto-skip when there's no real GitHub origin (test fixtures use tmpdir
    # remotes; the phase's gh api calls would hang or produce garbage).
    # Test fixtures often shim `gh`, so we check the actual git remote URL
    # rather than trusting `gh repo view`.
    local _origin_url
    _origin_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$_origin_url" != *"github.com"* ]]; then
        echo "INFO: staged-intermediate phase skipped (origin '$_origin_url' is not a github.com remote)"
        return 0
    fi

    # 1. Create the staged-* ref pointing at origin/main HEAD.
    local _staged_branch
    _staged_branch=$(_create_staged_ref) || return 1
    echo "INFO: created staged ref refs/heads/${_staged_branch} from origin/main HEAD"

    # Resume hardening: persist the staged branch name NOW, while BRANCH is still
    # the source branch (so the write lands in the SOURCE-branch-keyed state file —
    # _state_file_path is derived from BRANCH, which we re-point to staged-* below).
    # On --resume this lets the top-level flow advance to PR2 even if the worktree's
    # checkout to staged-* was lost in a crash window. (_state_set_field is a no-op
    # if the state file is absent.)
    if type _state_set_field >/dev/null 2>&1; then
        _state_set_field "staged_branch" "$_staged_branch" 2>/dev/null || true
    fi

    # 1a. 0f17 DD1: PIN the origin/main SHA the staged ref was just cut from, then
    # rebase the feature branch onto it BEFORE the version bump so PR1's version line is
    # single-sided (clean feat→staged merge). The staged ref's tip IS that pinned SHA
    # and is immutable, so reading it back is TOCTOU-free — a re-fetched origin/main
    # could have advanced and reopened the conflict. A failed sync (code conflict)
    # escalates: do NOT proceed to bump/push a half-synced branch.
    local _pinned_main_sha _gh_repo_pin
    _gh_repo_pin=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    _pinned_main_sha=""
    if [[ -n "$_gh_repo_pin" ]]; then
        _pinned_main_sha=$(gh api "repos/${_gh_repo_pin}/branches/${_staged_branch}" --jq '.commit.sha' 2>/dev/null || echo "")
    fi
    if [[ -n "$_pinned_main_sha" ]]; then
        if ! _phase_prebump_feature_sync "$_pinned_main_sha"; then
            echo "ERROR: prebump feature-sync failed (conflict or hard error) — escalating; not proceeding to bump/push" >&2
            return 1
        fi
    else
        echo "WARNING: prebump-sync: could not resolve the pinned main SHA from staged ref ${_staged_branch}; skipping sync (bump proceeds — PR1 may require a manual rebase if main advanced)"
    fi

    # 1b. Two-tier version bump: apply the version bump on the FEATURE branch NOW
    # (before PR1), so it flows feat→staged→main through the two reviewed PRs. The
    # bump must NOT be deferred to _phase_merge (PR2 phase), where BRANCH is staged-*
    # and pushing a bump commit directly to the protected staged-* branch is rejected
    # by the sub-PR ruleset for the non-admin agent. Derive a best-effort story id
    # for the bump commit's DSO-Story trailer (mirrors _phase_merge); fall back to
    # the branch name. The bump runs here while BRANCH is the feature branch, so the
    # staged-* skip guard in _phase_source_branch_version_bump does NOT fire.
    local _staged_bump_story
    _staged_bump_story=$(git log --pretty=format:%B "origin/${_DEFAULT_BRANCH:-main}..HEAD" 2>/dev/null \
        | grep -Eiom1 '^[[:space:]]*DSO-Story:[[:space:]]*[A-Za-z0-9._/-]+' \
        | sed -E 's/^[[:space:]]*DSO-Story:[[:space:]]*//I' || true)
    [[ -z "$_staged_bump_story" ]] && _staged_bump_story="${BRANCH:-unknown}"
    _phase_source_branch_version_bump "$_staged_bump_story" || {
        echo "ERROR: source-branch version bump failed on feature branch ${BRANCH}" >&2
        return 1
    }

    # 2. Push BRANCH (the source branch — typically worktree-*) to origin so
    #    GitHub can see its commits when we open PR1 against the staged ref.
    if ! git push origin "$BRANCH" 2>&1 | tail -5; then
        echo "ERROR: failed to push $BRANCH to origin" >&2
        return 1
    fi

    # 3. Open PR1: BRANCH → staged_branch. review-sub-pr workflow will fire.
    local _pr1_title _pr1_body _pr1_url _pr1_number
    _pr1_title="staged: ${BRANCH} -> ${_staged_branch}"
    _pr1_body=$(cat <<EOF
## Staged promotion (PR-C two-PR flow)

This is the **first PR** of a two-PR session→main promotion. The worktree branch \`${BRANCH}\` is being merged into the staged ref \`${_staged_branch}\`, which was created from \`origin/main\` HEAD.

The sub-PR ruleset's \`required_workflows\` rule requires \`review-sub-pr\` to run successfully on this PR before merge. Once this PR merges, the merge-to-main script will open PR2 from \`${_staged_branch}\` → \`main\`.

🤖 Generated by merge-to-main-pr.sh
EOF
)

    local _pr1_create_out _pr1_create_rc=0
    _pr1_create_out=$(gh pr create --base "$_staged_branch" --head "$BRANCH" \
        --title "$_pr1_title" --body "$_pr1_body" 2>&1) || _pr1_create_rc=$?
    if [[ "$_pr1_create_rc" -ne 0 ]]; then
        echo "ERROR: PR1 creation failed (${BRANCH} -> ${_staged_branch}): $_pr1_create_out" >&2
        return 1
    fi
    _pr1_url=$(echo "$_pr1_create_out" | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -n1)
    _pr1_number=$(echo "$_pr1_url" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+$')
    if [[ -z "$_pr1_number" ]]; then
        echo "ERROR: PR1 created but PR number unparseable from: $_pr1_create_out" >&2
        return 1
    fi
    echo "INFO: PR1 created #${_pr1_number}: $_pr1_url"

    # 3b. Enqueue auto-merge on PR1 so GitHub merges it once review-sub-pr passes.
    #     Without this the wait at step 4 deadlocks: wait-for-pr.sh only exits 0
    #     on MERGED, but nothing merges PR1 before the wait — on real GitHub the
    #     PR stays OPEN until the 30-min timeout, then the phase aborts (bug
    #     c9fe-8b6c-9421-4faf). Mirrors PR2's path, which enqueues via
    #     _phase_queue_auto_merge. The helper tolerates auto-merge-disabled repos
    #     (returns 0, warns); step 5's direct `gh pr merge` remains the fallback.
    _phase_queue_auto_merge "$_pr1_number" \
        || echo "WARNING: failed to enqueue auto-merge for PR1 #${_pr1_number}; relying on step-5 manual merge after the wait." >&2

    # 4. Wait for review-sub-pr to complete. Use the existing wait-for-pr helper
    #    if available; otherwise poll inline.
    local _wait_for_pr_helper="${_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/wait-for-pr.sh"
    if [[ -x "$_wait_for_pr_helper" ]]; then
        echo "INFO: waiting for PR1 #${_pr1_number} required checks to complete..."
        if ! bash "$_wait_for_pr_helper" "$_pr1_number"; then
            echo "ERROR: PR1 #${_pr1_number} reached terminal failure state — refusing to advance to PR2" >&2
            return 1
        fi
    else
        # Inline polling fallback (60s intervals, 30 min cap).
        local _poll_n=0
        while (( _poll_n < 30 )); do
            local _state
            _state=$(gh pr view "$_pr1_number" --json state --jq '.state' 2>/dev/null || echo "")
            [[ "$_state" == "MERGED" ]] && break
            [[ "$_state" == "CLOSED" ]] && { echo "ERROR: PR1 #${_pr1_number} closed without merging" >&2; return 1; }
            sleep 60
            (( _poll_n++ )) || true
        done
    fi

    # 5. Merge PR1 (if not already merged by wait-for-pr's auto-merge path).
    local _pr1_state
    _pr1_state=$(gh pr view "$_pr1_number" --json state --jq '.state' 2>/dev/null || echo "")
    if [[ "$_pr1_state" != "MERGED" ]]; then
        local _merge_out _merge_rc=0
        # cca8 DD1: rebase-merge PR1 (feature → staged) so the staged branch stays
        # linear and PR2 (staged → main) can itself be rebase-merged.
        _merge_out=$(gh pr merge "$_pr1_number" --rebase 2>&1) || _merge_rc=$?
        if [[ "$_merge_rc" -ne 0 ]]; then
            echo "ERROR: PR1 #${_pr1_number} merge failed: $_merge_out" >&2
            return 1
        fi
    fi
    echo "INFO: PR1 #${_pr1_number} merged into ${_staged_branch}"

    # 6. Re-point BRANCH to the staged branch so the subsequent _phase_merge
    #    opens PR2 (staged-* → main). Persist to state file for --resume.
    BRANCH="$_staged_branch"
    # Re-init state for the re-pointed (staged-) BRANCH so the staged-keyed state
    # file exists before _phase_merge writes PR2's pr_meta. The state-file path is
    # BRANCH-derived (_state_file_path), so without this re-init the staged file is
    # never created on the fresh path, _state_write_pr_meta no-ops on its `[[ -f ]]`
    # guard, and the polling phase cannot resolve PR2's number (bug 7a0e:
    # "could not resolve PR number for polling phase"). Mirrors the --resume path
    # (which re-invokes _state_init after restoring the staged BRANCH). _state_init
    # writes a fresh skeleton that drops staged_branch, so re-persist it for --resume.
    # (The previously-called _state_write_branch was never defined — a silent no-op.)
    if type _state_init >/dev/null 2>&1; then
        _state_init 2>/dev/null || true
        type _state_set_field >/dev/null 2>&1 && _state_set_field "staged_branch" "$_staged_branch" 2>/dev/null || true
    fi

    # 7. Switch the local working copy to the staged branch so _phase_merge's
    #    git fetch/merge operations operate on the right ref.
    if ! git fetch origin "$_staged_branch:refs/remotes/origin/${_staged_branch}" --quiet 2>/dev/null; then
        echo "WARNING: could not fetch ${_staged_branch} from origin; subsequent phases may fail" >&2
    fi
    git checkout -B "$_staged_branch" "origin/${_staged_branch}" --quiet 2>/dev/null || {
        echo "WARNING: could not check out ${_staged_branch}; subsequent phases may fail" >&2
    }

    if type _state_mark_complete >/dev/null 2>&1; then
        _state_mark_complete "staged_intermediate" 2>/dev/null || true
    fi

    return 0
}

# --- _sync_branch_against_default (cca8 DD1): linear pre-push sync ------------
# Bring the branch up to date with the default branch BEFORE the push, so CI
# runs on the same base used at merge time (a456-c689). cca8 (linear-history
# cutover): this REBASES the branch onto origin/<default> instead of merging it
# in. The prior `git merge --no-edit origin/<default>` created a merge commit on
# the branch head; under required_linear_history that merge commit (a) is itself
# a non-linear commit and (b) makes GitHub's `gh pr merge --rebase` refuse the PR
# ("rebase merge is not possible because the branch contains merge commits").
# Rebasing replays the branch's own commits on top of the default-branch tip, so
# the resulting head is linear and rebase-merges cleanly.
#
# Sets the script-global `_SYNCED_VIA_REBASE=1` when it rewrites history (the
# caller must then push with --force-with-lease instead of the plain
# fetch+rebase-onto-origin/<branch> path, which would otherwise replay the
# rewritten commits back on top of the stale remote and duplicate them).
# Returns 0 on success / no-op; 1 on rebase failure (history restored via abort).
_sync_branch_against_default() {
    local _db="${_DEFAULT_BRANCH:-main}"
    _SYNCED_VIA_REBASE=0
    if ! git fetch origin "${_db}:refs/remotes/origin/${_db}" --quiet 2>/dev/null && \
       ! git fetch origin "$_db" --quiet 2>/dev/null; then
        echo "WARNING: git fetch origin ${_db} failed — skipping origin/${_db} sync; proceeding with current HEAD." >&2
        return 0
    fi
    # Already up to date (origin/<default> is an ancestor of HEAD) → no sync.
    if git merge-base --is-ancestor "origin/${_db}" HEAD 2>/dev/null; then
        return 0
    fi
    # Only rebase when a common ancestor exists. Unrelated histories (no common
    # ancestor) means the worktree was initialised independently of the default
    # branch and forcing a rebase would be wrong.
    local _common_ancestor
    _common_ancestor=$(git merge-base HEAD "origin/${_db}" 2>/dev/null || true)
    if [[ -z "$_common_ancestor" ]]; then
        # No common ancestor → skip sync; branch and default branch are unrelated.
        return 0
    fi
    echo "INFO: Branch is behind origin/${_db} — rebasing before push (linear history) to avoid stale CI." >&2
    local _rebase_main_out _rebase_main_rc=0
    _rebase_main_out=$(git rebase "origin/${_db}" 2>&1) || _rebase_main_rc=$?
    if [[ "$_rebase_main_rc" -ne 0 ]]; then
        git rebase --abort 2>/dev/null || true
        local _rebase_hint="(rebase failed)"
        if echo "$_rebase_main_out" | grep -qiE "CONFLICT|merge conflict"; then
            _rebase_hint="(merge conflicts — run /dso:resolve-conflicts)"
        fi
        echo "ERROR: git rebase origin/${_db} failed $_rebase_hint" >&2
        return 1
    fi
    _SYNCED_VIA_REBASE=1
    return 0
}

# --- _publish_rebased_branch (cca8 DD1): force-with-lease publish after rebase -
# When _sync_branch_against_default rewrote history (rebased the branch onto
# origin/<default>), the local head intentionally diverges from origin/<branch>,
# so a plain push is rejected non-fast-forward and the branch must be force-
# published. Uses an EXPLICIT lease — origin/<branch>'s last-known tip captured
# from the remote-tracking ref WITHOUT a preceding fetch — so a concurrent writer
# is genuinely detected and refused.
#
# Why no fetch: a bare `--force-with-lease` uses refs/remotes/origin/<branch> as
# its lease basis. Fetching first fast-forwards that very tracking ref to the
# remote's current value, so the lease would always match and silently degrade to
# an unconditional `git push --force`, clobbering a concurrent writer (gitar
# finding, PR #663). Capturing the pre-push tip explicitly preserves the guard.
#
# Falls back to a bare `--force-with-lease` when no tracking ref exists yet (e.g.
# a brand-new branch); the tracking ref is the lease basis in that case too.
_publish_rebased_branch() {
    local _branch="$1"
    local _lease_sha
    _lease_sha=$(git rev-parse "refs/remotes/origin/${_branch}" 2>/dev/null || echo "")
    # Explicitly check the subshell so a failed force-push propagates to the
    # caller unambiguously (a function whose last command is a subshell already
    # returns the subshell's status, but the explicit `if`/`return` leaves no
    # doubt for callers that use `_publish_rebased_branch ... || return 1`).
    if ! (
        # shellcheck disable=SC2030  # intentional: export scoped to THIS subshell (PR #179 retro); must not leak to caller
        export DSO_ALLOW_PUSH_TO_MERGED_PR=1
        local _lease_arg="--force-with-lease"
        [[ -n "$_lease_sha" ]] && _lease_arg="--force-with-lease=${_branch}:${_lease_sha}"
        if ! git push "$_lease_arg" -u origin "$_branch" 2>&1; then
            echo "ERROR: git push ${_lease_arg} origin ${_branch} failed (linear-rebase publish)" >&2
            exit 1
        fi
    ); then
        return 1
    fi
    return 0
}

_phase_merge() {
    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "merge" 2>/dev/null || true
    fi

    # --- 1. Sync against the default branch before push (a456-c689; cca8 DD1) ---
    # F-05: use resolved $_DEFAULT_BRANCH (master/develop/trunk-aware). Rebases
    # (not merges) so the head stays linear for required_linear_history.
    local _db="${_DEFAULT_BRANCH:-main}"
    _SYNCED_VIA_REBASE=0
    _sync_branch_against_default || return 1

    # --- 1a. Source-branch version bump (b6e3-e771 + bbba-123d) ---
    # In PR mode, the version bump MUST commit to the session branch BEFORE
    # the push, so the bump lands in main as part of the PR's squash-merge
    # commit. Doing the bump post-merge (the prior approach) diverged main
    # from the PR's merged content and was rejected by the always-run
    # compliance-verifier pre-commit hook.
    #
    # Extract the story id from existing branch trailers (best-effort): the
    # bump commit carries a DSO-Story trailer so verify-session-provenance.sh
    # accepts it on the session branch (S1.T5 grammar).
    local _bump_story_id=""
    _bump_story_id=$(git log --pretty=format:%B "${_db}..HEAD" 2>/dev/null \
        | grep -Eiom1 '^[[:space:]]*DSO-Story:[[:space:]]*[A-Za-z0-9._/-]+' \
        | sed -E 's/^[[:space:]]*DSO-Story:[[:space:]]*//I' \
        || true)
    if [[ -z "$_bump_story_id" ]]; then
        _bump_story_id=$(git log --pretty=format:%B "origin/${_db}..HEAD" 2>/dev/null \
            | grep -Eiom1 '^[[:space:]]*DSO-Story:[[:space:]]*[A-Za-z0-9._/-]+' \
            | sed -E 's/^[[:space:]]*DSO-Story:[[:space:]]*//I' \
            || true)
    fi
    # Fall back to the branch name when no trailer is present; the bump
    # commit still gets a parseable trailer for downstream tooling.
    [[ -z "$_bump_story_id" ]] && _bump_story_id="${BRANCH:-unknown}"

    if ! _phase_source_branch_version_bump "$_bump_story_id"; then
        echo "ERROR: source-branch version bump failed." >&2
        return 1
    fi

    # --- 1b. Publish branch ---
    # cca8 DD1: when the linear pre-push sync rewrote history (rebased the branch
    # onto origin/<default>), the local head intentionally diverges from
    # origin/<branch>. The normal fetch+rebase-onto-origin/<branch> recovery would
    # replay the rewritten commits back onto the stale remote head and duplicate
    # them, so force-publish via _publish_rebased_branch, which uses an explicit
    # lease (no preceding fetch) so a concurrent writer is genuinely detected.
    if [[ "${_SYNCED_VIA_REBASE:-0}" == "1" ]]; then
        _publish_rebased_branch "$BRANCH" || return 1
    else
        # Pre-push sync: when the remote ref already exists and has advanced
        # past our local HEAD (e.g. a previous "Merge branch 'main' into <branch>"
        # landed via UI or another session), `git push -u` will be rejected
        # non-fast-forward. Fetch and rebase before push so the workflow recovers
        # automatically instead of halting and forcing manual `git pull --rebase`.
        # (b56b-14e9)
        _fetch_and_rebase_branch || return 1

        # Bypass pre-push-merged-pr-check.sh: this push is intentionally publishing
        # new commits to a session branch whose previous PR is already MERGED, in
        # order to open a NEW PR for the next set of commits. The merged-PR hook
        # protects against the "commits pushed after auto-merge, no follow-up PR
        # opened" failure mode (680f-53fb) — which does not apply here because
        # the very next step (gh pr create below) opens that follow-up PR.
        #
        # Retro-review of PR #179 found that the prior set-then-unset pattern leaked
        # DSO_ALLOW_PUSH_TO_MERGED_PR=1 to the caller's environment whenever the
        # push retry exited via `return 1`. Wrap both push attempts in a subshell so
        # the export is scoped to that subshell and cannot escape regardless of
        # which exit path is taken.
        if ! (
            # shellcheck disable=SC2031  # intentional: each push subshell independently scopes this export (PR #179 retro); not read across subshells
            export DSO_ALLOW_PUSH_TO_MERGED_PR=1
            if ! git push -u origin "$BRANCH" 2>&1; then
                # Retry once on rejection: another push may have landed between fetch and push.
                if _fetch_and_rebase_branch && git push -u origin "$BRANCH" 2>&1; then
                    : # retry succeeded
                else
                    git rebase --abort 2>/dev/null || true
                    echo "ERROR: git push -u origin $BRANCH failed (after fetch+rebase retry)" >&2
                    exit 1
                fi
            fi
        ); then
            return 1
        fi
    fi

    # --- 3. Derive PR title from last meaningful commit subject ---
    # Use _derive_pr_title so an upstream merge-back commit subject
    # (e.g. "Merge remote-tracking branch 'origin/main' into <branch>")
    # never becomes the PR title. Bug 85b8-2576.
    local _title
    _title=$(_derive_pr_title "$BRANCH")
    if [[ -z "$_title" ]]; then
        _title="Merge $BRANCH"
    fi

    # --- 4. Create the PR (or reuse an existing draft PR) ---
    # Check for an existing draft PR first (bug 05d1-faa4): sprint Phase A may
    # have created a draft PR earlier in the session. `gh pr create` fails with
    # "a pull request already exists" for both draft and non-draft PRs, so we
    # must detect and reuse any existing draft before calling `gh pr create`.
    local _pr_base
    # F-05: prefer the resolved default branch over the hard-coded "main"
    # so host repositories on master/develop/trunk work end-to-end.
    _pr_base="${STORY_PR_BASE:-${_DEFAULT_BRANCH:-main}}"
    [[ -z "$_pr_base" ]] && _pr_base="${_DEFAULT_BRANCH:-main}"

    local _body
    _body=$(_derive_pr_body "$BRANCH" "$_pr_base")

    local _draft_pr_json _final_url _pr_number
    _draft_pr_json=$(gh pr list --head "$BRANCH" --state open \
        --json number,url,isDraft 2>/dev/null || true)
    _final_url=$(printf '%s' "$_draft_pr_json" \
        | python3 -c "import json,sys; prs=json.load(sys.stdin); drafts=[p for p in prs if p.get('isDraft')]; print(drafts[0]['url'] if drafts else '')" 2>/dev/null || true)
    _pr_number=$(printf '%s' "$_draft_pr_json" \
        | python3 -c "import json,sys; prs=json.load(sys.stdin); drafts=[p for p in prs if p.get('isDraft')]; print(drafts[0]['number'] if drafts else '')" 2>/dev/null || true)

    if [[ -n "$_final_url" && -n "$_pr_number" ]]; then
        echo "INFO: Reusing existing draft PR #${_pr_number}: $_final_url"
    else
        # No existing draft PR — create a new one.
        local _pr_url _pr_create_rc=0
        _pr_url=$(gh pr create --base "$_pr_base" --head "$BRANCH" \
                              --title "$_title" --body "$_body" 2>&1) || _pr_create_rc=$?
        if [[ "$_pr_create_rc" -ne 0 ]]; then
            # Handle race condition: another process may have created the PR between our
            # gh pr list check and gh pr create. Extract URL from the error message.
            _final_url=$(echo "$_pr_url" | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -n1)
            if [[ -n "$_final_url" ]]; then
                _pr_number=$(echo "$_final_url" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+$')
                echo "INFO: PR already existed (race condition resolved): #${_pr_number}: $_final_url"
            else
                echo "ERROR: gh pr create failed: $_pr_url" >&2
                # _pr_url may contain the error text — still return 1 so caller emits
                # CONFLICT_DATA (best-effort) for upstream orchestrators.
                return 1
            fi
        else
            # gh pr create may print extra log lines before the URL; extract the
            # last line that looks like a PR url.
            _final_url=$(echo "$_pr_url" | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -n1)
            if [[ -z "$_final_url" ]]; then
                # Fallback: trust the entire stdout as the URL (some gh versions emit
                # only the URL with no surrounding text).
                _final_url=$(echo "$_pr_url" | tail -n1 | tr -d '[:space:]')
            fi

            _pr_number=$(echo "$_final_url" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+$')
            if [[ -z "$_pr_number" ]]; then
                echo "ERROR: could not parse PR number from gh pr create output: $_pr_url" >&2
                return 1
            fi
            echo "INFO: Created PR #${_pr_number}: $_final_url"
        fi
    fi

    # --- 5. Persist PR url + number to state file (best-effort) ---
    _state_write_pr_meta "$_final_url" "$_pr_number" 2>/dev/null || true

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

    # --- 7. Promote draft PR to ready-for-review (075f-ec40) ---
    # Sprint Phase A creates the long-lived PR with --draft. It must be promoted
    # before auto-merge can be queued (some GitHub plans require non-draft status).
    local _pr_is_draft
    _pr_is_draft=$(_query_pr_is_draft "$_pr_number")

    if [[ "$_pr_is_draft" == "true" ]]; then
        echo "INFO: PR #${_pr_number} is draft — promoting to ready-for-review."
        local _ready_out _ready_rc=0
        _ready_out=$(gh pr ready "$_pr_number" 2>&1) || _ready_rc=$?
        if [[ "$_ready_rc" -ne 0 ]]; then
            echo "WARNING: gh pr ready #${_pr_number} failed (non-fatal): $_ready_out" >&2
        else
            echo "INFO: PR #${_pr_number} promoted to ready-for-review."
        fi
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

    # ci-pr / story-PR mode: when STORY_PR_BASE is set, route through the
    # trailer-injection pipeline so the auto-merge enable carries the
    # DSO-Story-Merge trailer (ticket e349-6b4e-13c5-4e23).
    if [[ -n "${STORY_PR_BASE:-}" ]]; then
        inject_and_enable_automerge "$_pr_number" "${STORY_EPIC_ID:-unknown}" "${STORY_ID:-unknown}" || true
        return 0
    fi

    local _merge_out _merge_rc=0
    # cca8 (linear-history cutover, DD1): rebase-merge so no merge commit reaches
    # main under required_linear_history. --rebase replays the PR's commits onto
    # the base tip at merge time; a merge commit in the PR head would be rejected
    # by GitHub's rebase path, which is why the pre-push branch-sync also rebases
    # (see _sync_branch_against_default).
    _merge_out=$(gh pr merge "$_pr_number" --auto --rebase 2>&1) || _merge_rc=$?
    if [[ "$_merge_rc" -ne 0 ]]; then
        if echo "$_merge_out" | grep -qiE "auto.?merge.*(not allowed|disabled|cannot be enabled)"; then
            echo "WARNING: GitHub auto-merge is disabled for this repository — falling through to manual merge after CI." >&2
            echo "         (To enable for future runs: Settings → General → 'Allow auto-merge'.)" >&2
            if type _state_write_auto_merge_disabled >/dev/null 2>&1; then
                _state_write_auto_merge_disabled "true" 2>/dev/null || true
            fi
        else
            echo "ERROR: gh pr merge ${_pr_number} --auto --rebase failed: $_merge_out" >&2
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
            "Session agent must address the open PR review threads (resolve, comment, or push fixes), then drive the PR to merge via \${CLAUDE_PLUGIN_ROOT}/docs/workflows/PR-FINALIZE-WORKFLOW.md using pr-finalize-classify.sh. Do not re-run merge-to-main.sh."
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

        # Fast-path: zero threads, none ever observed, and no LLM dispatch needed.
        # _pr_settling_check requires quiet_elapsed=true even for threads=0, but that
        # is only meaningful after threads have been seen and resolved. A fresh PR with
        # no threads has nothing to wait for. We gate on _llm_cmd being empty because
        # when an LLM dispatcher is available the loop continues (e.g., to detect SHA
        # changes via _pr_handle_head_sha_reset). Bug 1d42-ffcb.
        if (( _threads_count == 0 && _last_thread_seen_ts == 0 )) && [[ -z "$_llm_cmd" ]]; then
            echo "INFO: PR #${_pr_number} has no review threads; resolve complete."
            if type _state_mark_complete >/dev/null 2>&1; then
                _state_mark_complete "resolve_threads" 2>/dev/null || true
            fi
            return 0
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

        # --- LLM helper required from this point — escalate if unset (1a83-46c5) ---
        # We only reach this point if there are actual unresolved, non-escalated
        # threads that need LLM dispatch. PRs with zero review threads exit cleanly
        # via _pr_settling_check above without ever requiring the helper.
        if [[ -z "$_llm_cmd" ]]; then
            if ! _dso_is_ci_environment; then
                _dso_emit_local_escalation "resolve_threads" \
                    "_LLM_DISPATCH_CMD not set; cannot dispatch LLM thread resolution locally (PR: ${_pr_url}; unresolved: ${_unresolved_ids})" \
                    "Session agent must resolve the open PR review threads manually, then drive the PR to merge via \${CLAUDE_PLUGIN_ROOT}/docs/workflows/PR-FINALIZE-WORKFLOW.md using pr-finalize-classify.sh. Do not re-run merge-to-main.sh."
                return 1
            fi
            echo "ESCALATE: _LLM_DISPATCH_CMD not set in CI; configure a compat-shim. UNRESOLVED:${_unresolved_ids} PR:${_pr_url}" >&2
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
#   1. `gh pr checks <num> --json name,state,bucket`
#      - any fail/cancel bucket → exit 1 with PR url
#      - all pass bucket → query merge state (step 2)
#      Note: `bucket` is gh CLI's canonical check-outcome field (pass|fail|
#      pending|skipping|cancel). The legacy `conclusion` field is NOT exposed
#      by `gh pr checks --json`; requesting it exits 1 with "Unknown JSON
#      field" and silently disables failure detection. Bug 075d-741a.
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

    # Attempt counter for BEHIND-state branch updates (jira-dig-2529).
    # Capped at 3 to avoid an infinite update→CI-rerun cycle when main keeps moving.
    local _branch_update_attempts=0
    local _BRANCH_UPDATE_MAX_ATTEMPTS=3

    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "poll" 2>/dev/null || true
    fi

    local _start=$SECONDS
    while :; do
        # --- Step 1: ONE pr checks call ---
        local _checks_json _checks_rc=0
        # `bucket` (pass|fail|pending|skipping|cancel) is gh CLI's canonical check
        # outcome field; the previously-used `conclusion` field is not exposed via
        # --json and would silently disable failure detection. See pr-finalize-classify.sh
        # line 190 for the established pattern. Bug 075d-741a.
        _checks_json=$(gh pr checks "$_pr_number" --json name,state,bucket 2>&1) || _checks_rc=$?

        # When PR has no checks, `gh pr checks` exits 8 with stderr "no checks reported".
        # Treat as "no failures yet" — continue polling for merge state.
        if [[ "$_checks_rc" -eq 0 ]]; then
            # Detect any failed bucket
            local _has_failure
            _has_failure=$(echo "$_checks_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, list):
        print('false'); sys.exit(0)
    for c in d:
        bucket = (c.get('bucket') or '').lower()
        if bucket in ('fail', 'cancel'):
            print('true'); sys.exit(0)
    print('false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")

            if [[ "$_has_failure" == "true" ]]; then
                # PR-C hard gate: if check-staged-head failed, refuse to proceed
                # with remediation OR admin merge. The check's failure means the
                # PR head doesn't match staged-* — no automatic fix is possible.
                # The caller (operator) must restructure the PR via the staged-*
                # intermediate flow.
                local _staged_head_failed
                _staged_head_failed=$(echo "$_checks_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, list):
        print('false'); sys.exit(0)
    for c in d:
        name = (c.get('name') or '').lower()
        bucket = (c.get('bucket') or '').lower()
        if name == 'check-staged-head' and bucket in ('fail', 'cancel'):
            print('true'); sys.exit(0)
    print('false')
except Exception:
    print('false')
" 2>/dev/null || echo "false")
                if [[ "$_staged_head_failed" == "true" ]]; then
                    echo "ERROR: check-staged-head failed on PR ${_pr_url}" >&2
                    echo "ERROR: PR head branch does not match required 'staged-*' pattern." >&2
                    echo "ERROR: This is a hard gate (PR-C). No remediation or admin-bypass path is supported." >&2
                    echo "ERROR: Re-run merge-to-main-pr.sh from the source worktree branch so the staged-* intermediate is created automatically." >&2
                    exit 1
                fi
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
            # `gh pr merge --rebase` ourselves so the loop's MERGED check below succeeds
            # on the next iteration. cca8 DD1: rebase-merge (no merge commit) for
            # required_linear_history parity with the auto-merge path.
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
        bucket = (c.get('bucket') or '').lower()
        # Any check still pending (or no bucket reported yet) blocks readiness.
        if bucket in ('pending',) or not bucket:
            print('false'); sys.exit(0)
        # Manual-merge readiness requires every reported check to pass.
        # NEUTRAL/SKIPPED (bucket=skipping) and cancel/fail are NOT accepted
        # here — branch protection may treat them as not-passing-required and
        # a manual `gh pr merge --merge` would be rejected.
        if bucket != 'pass':
            print('false'); sys.exit(0)
    print('true')
except Exception:
    print('false')
" 2>/dev/null || echo "false")
                if [[ "$_all_done" == "true" ]]; then
                    local _manual_out _manual_rc=0
                    # cca8 DD1: rebase-merge (no merge commit) for linear-history parity.
                    _manual_out=$(gh pr merge "$_pr_number" --rebase 2>&1) || _manual_rc=$?
                    if [[ "$_manual_rc" -eq 0 ]]; then
                        echo "INFO: Manual merge issued for PR #${_pr_number} (auto-merge disabled)."
                    else
                        # Don't fail hard: a transient gh error or "already merged" message is fine —
                        # the next iteration's state check will resolve.
                        echo "WARNING: gh pr merge ${_pr_number} --rebase returned non-zero: $_manual_out" >&2
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

        # --- Step 2.5: detect BEHIND base-branch state and update (jira-dig-2529) ---
        # When all CI checks pass but mergeStateStatus=BEHIND, branch protection
        # blocks auto-merge until the PR branch incorporates the latest base. Detect
        # this state and call `gh pr update-branch` rather than looping until timeout.
        # Only runs when CI checks were queried successfully (_checks_rc=0) and all
        # passed (_has_failure != "true") — skip during IN_PROGRESS or failure states.
        if [[ "${_checks_rc:-0}" -eq 0 && "${_has_failure:-false}" != "true" ]]; then
            local _merge_state_status
            _merge_state_status=$(gh pr view "$_pr_number" --json mergeStateStatus \
                --jq '.mergeStateStatus' 2>/dev/null || true)
            if [[ "$_merge_state_status" == "BEHIND" ]]; then
                if (( _branch_update_attempts >= _BRANCH_UPDATE_MAX_ATTEMPTS )); then
                    echo "ERROR: PR #${_pr_number} branch update attempt limit (${_BRANCH_UPDATE_MAX_ATTEMPTS}) reached — branch cannot be updated from base; escalating (PR: ${_pr_url})" >&2
                    return 1
                fi
                echo "INFO: PR #${_pr_number} branch is behind base — calling gh pr update-branch (attempt $(( _branch_update_attempts + 1 ))/${_BRANCH_UPDATE_MAX_ATTEMPTS})" >&2
                gh pr update-branch "$_pr_number" 2>/dev/null || true
                _branch_update_attempts=$(( _branch_update_attempts + 1 ))
            fi
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
            "Session agent must run /dso:resolve-conflicts (or rebase manually) and push, then drive the PR to merge via \${CLAUDE_PLUGIN_ROOT}/docs/workflows/PR-FINALIZE-WORKFLOW.md using pr-finalize-classify.sh. Do not re-run merge-to-main.sh."
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
            "Session agent must invoke /dso:fix-bug on the failing CI run and push the fix, then drive the PR to merge via \${CLAUDE_PLUGIN_ROOT}/docs/workflows/PR-FINALIZE-WORKFLOW.md using pr-finalize-classify.sh. Do not re-run merge-to-main.sh."
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

# --- _phase_comment_response: process PR comments after CI, before merge ---
# Runs after _phase_queue_auto_merge so auto-merge is already queued.
# Calls the pr-comment-response pipeline on a fixed snapshot of comments.
# If accept-classified comments push new commits, the CI re-poll is handled
# by the subsequent _phase_poll call which polls until MERGED.
_phase_comment_response() {
    local _pr_number="$1"
    _CURRENT_PHASE="comment_response"

    if type _state_write_phase >/dev/null 2>&1; then
        _state_write_phase "comment_response" 2>/dev/null || true
    fi

    if [[ -z "${_pr_number:-}" ]]; then
        echo "INFO: _phase_comment_response: no PR number — skipping."
        if type _state_mark_complete >/dev/null 2>&1; then
            _state_mark_complete "comment_response" 2>/dev/null || true
        fi
        return 0
    fi

    # Validate _pr_number is numeric to prevent malformed path construction.
    if [[ ! "${_pr_number}" =~ ^[0-9]+$ ]]; then
        echo "WARNING: _phase_comment_response: invalid PR number '${_pr_number}' — skipping." >&2
        if type _state_mark_complete >/dev/null 2>&1; then
            _state_mark_complete "comment_response" 2>/dev/null || true
        fi
        return 0
    fi

    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)

    # Guard against empty _repo_root (e.g. git unavailable or outside a repo).
    if [[ -z "${_repo_root:-}" ]]; then
        echo "WARNING: _phase_comment_response: cannot resolve repo root — skipping." >&2
        if type _state_mark_complete >/dev/null 2>&1; then
            _state_mark_complete "comment_response" 2>/dev/null || true
        fi
        return 0
    fi

    local _snapshot
    _snapshot=$(mktemp "/tmp/dso-pr-comment-response-snapshot.XXXXXX")

    echo "INFO: _phase_comment_response: processing PR #${_pr_number} comments..."

    local _rc=0
    "${_repo_root}/.claude/scripts/dso" pr-comment-response \
        --pr-number "${_pr_number}" \
        --output "${_snapshot}" 2>&1 || _rc=$?

    rm -f "${_snapshot}" 2>/dev/null || true

    if [[ "${_rc}" -ne 0 ]]; then
        echo "WARNING: pr-comment-response exited non-zero (rc=${_rc}) — continuing with merge." >&2
    else
        echo "INFO: _phase_comment_response: complete for PR #${_pr_number}."
    fi

    if type _state_mark_complete >/dev/null 2>&1; then
        _state_mark_complete "comment_response" 2>/dev/null || true
    fi
    return 0
}

# =============================================================================
# Trailer injection (ticket e349-6b4e-13c5-4e23): v7 spec
#
# DSO_TRAILER_INJECTION_MODE controls trailer-injection behavior for ci-pr mode:
#   enabled  (default) — inject DSO-Story-Merge trailer via ephemeral worktree
#   disabled (emergency rollback) — skip trailer; silent degradation to API fallback
#   dry-run  — log trailer injection plan without amending; merge proceeds
# =============================================================================
DSO_TRAILER_INJECTION_MODE="${DSO_TRAILER_INJECTION_MODE:-enabled}"

# Pre-merge force-push protection probe.
# Bails fast if story branch is protected against force-push (trailer-amend needs it).
# Args: <branch-name>
# Returns: 0 = proceed (no protection or force-push allowed); 1 = blocked
check_force_push_allowed() {
    local branch="$1"
    local encoded
    encoded=$(printf '%s' "$branch" | jq -sRr @uri 2>/dev/null || printf '%s' "$branch")
    local repo_full="${GITHUB_REPOSITORY:-x/y}"
    local owner="${repo_full%%/*}" repo="${repo_full##*/}"
    local protection allow_force
    # 404 = no protection rule = proceed (treat as OK).
    # gh api exit-nonzero on 404 is the expected "no protection" signal.
    if protection=$(gh api "repos/${owner}/${repo}/branches/${encoded}/protection" 2>&1); then
        allow_force=$(printf '%s' "$protection" | jq -r '.allow_force_pushes.enabled // false' 2>/dev/null || echo "false")
        if [[ "$allow_force" != "true" ]]; then
            echo "::error::story branch ${branch} is force-push-protected; trailer injection requires force-push. Aborting." >&2
            return 1
        fi
    fi
    return 0
}

# inject_trailer: amend (or empty-commit) the trailer on a story branch.
# Args: <epic_id> <story_id>
# Env (optional): SESSION_BRANCH (orchestrator-side export from sprint Phase F);
#                 defaults to "main" when unset.
# Returns:
#   0 — trailer injected + pushed (or no-op when force-push blocked? no: returns 1)
#   1 — force-push protection blocks OR git worktree add failed
#   2 — git commit (amend or allow-empty) failed
#   3 — git push --force-with-lease failed (concurrent push)
inject_trailer() {
    local epic="$1" story="$2"
    local story_branch="story/${epic}/${story}"

    # Force-push protection probe — block early if branch is force-push-protected.
    if ! check_force_push_allowed "$story_branch"; then
        return 1
    fi

    local tmp_wt="${TMPDIR:-/tmp}/dso-trailer-$$-${story}"
    local rc=0

    # Trap to guarantee cleanup on EXIT/INT/TERM. Use single-quoted body so the
    # variable expansion happens at trap-execution time (path is stable here, but
    # safer pattern).
    # shellcheck disable=SC2064
    trap "git worktree remove --force '$tmp_wt' 2>/dev/null || true; rm -rf '$tmp_wt' 2>/dev/null || true" EXIT INT TERM

    # Use --detach + origin/<branch> so we don't conflict with the same branch
    # being checked out in the main worktree (real-world scenario where the
    # session has the story branch checked out, and tests that mirror that
    # state). After commit, force-push HEAD to refs/heads/<branch>.
    git fetch --quiet origin "$story_branch" 2>/dev/null || true
    if ! git worktree add --detach --quiet "$tmp_wt" "origin/${story_branch}" 2>/dev/null; then
        # Fallback: try without origin/ prefix (covers shim-only environments).
        if ! git worktree add --detach --quiet "$tmp_wt" "$story_branch" 2>/dev/null; then
            trap - EXIT INT TERM
            git worktree remove --force "$tmp_wt" 2>/dev/null || true
            rm -rf "$tmp_wt" 2>/dev/null || true
            return 1
        fi
    fi

    local base_ref="${SESSION_BRANCH:-main}"
    local commit_count="0"
    commit_count=$(cd "$tmp_wt" && git rev-list --count "origin/${base_ref}..HEAD" 2>/dev/null) || commit_count="0"
    [[ -z "$commit_count" ]] && commit_count="0"

    if [[ "$commit_count" == "0" ]]; then
        if ! (cd "$tmp_wt" && git commit --allow-empty -m "story/${epic}/${story} trailer" --trailer "DSO-Story-Merge: ${story}" >/dev/null 2>&1); then
            rc=2
        fi
    else
        if ! (cd "$tmp_wt" && git commit --amend --no-edit --trailer "DSO-Story-Merge: ${story}" >/dev/null 2>&1); then
            rc=2
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        if ! (cd "$tmp_wt" && git push --force-with-lease "origin" "HEAD:refs/heads/${story_branch}" >/dev/null 2>&1); then
            rc=3
        fi
    fi

    trap - EXIT INT TERM
    git worktree remove --force "$tmp_wt" 2>/dev/null || true
    rm -rf "$tmp_wt" 2>/dev/null || true
    return "$rc"
}

# _do_inject_or_dry: dispatch inject_trailer based on DSO_TRAILER_INJECTION_MODE.
_do_inject_or_dry() {
    local epic="$1" story="$2" pr_num="$3"
    if [[ "${DSO_TRAILER_INJECTION_MODE}" == "dry-run" ]]; then
        echo "::notice::DRY-RUN: would inject DSO-Story-Merge: ${story} trailer onto story/${epic}/${story} for PR #${pr_num}" >&2
        return 0
    fi
    inject_trailer "$epic" "$story"
    local rc=$?
    case "$rc" in
        0) return 0 ;;
        1)
            echo "::error::worktree add failed for story/${epic}/${story} during trailer injection (or force-push protection blocks)" >&2
            return 1
            ;;
        2)
            echo "::error::trailer injection commit failed for story/${epic}/${story}" >&2
            return 1
            ;;
        3)
            echo "::warning::concurrent push to story/${epic}/${story} detected; trailer absent — API fallback will handle scoping" >&2
            return 0
            ;;
        *)
            echo "::error::inject_trailer returned unexpected rc=${rc}" >&2
            return 1
            ;;
    esac
}

# inject_and_enable_automerge: idempotent trailer injection + auto-merge enable.
# Args: <pr_num> <epic_id> <story_id>
# Reads DSO_TRAILER_INJECTION_MODE (enabled/disabled/dry-run)
# Returns: 0 on success or successful no-op (idempotent resume).
# Exits 1 (NOT returns 1) on force-push protection block — this terminates the
# entire script unconditionally and intentionally bypasses any caller's `|| true`,
# because a force-push-protected story branch cannot be auto-merged via trailer
# injection and must halt the sprint loudly for operator investigation.
# Round-3 finding e349 (bug e349-6b4e-13c5-4e23): the docstring previously
# claimed "Returns: 0 always" which was misleading — the exit-1 path was added
# in remediation but the docstring was not updated. The `|| true` on the caller
# at line 882 (intentionally preserved for the dry-run / disabled / 0-return
# happy paths) cannot suppress the exit-1, by design.
inject_and_enable_automerge() {
    local pr_num="$1" epic="$2" story="$3"
    local story_branch="story/${epic}/${story}"
    local repo_full="${GITHUB_REPOSITORY:-x/y}"

    # DSO_TRAILER_INJECTION_MODE=disabled — emergency rollback path.
    if [[ "${DSO_TRAILER_INJECTION_MODE}" == "disabled" ]]; then
        echo "::warning::DSO_TRAILER_INJECTION_MODE=disabled — skipping trailer injection for PR #${pr_num}; ci-pr fallback will scope llm-review via API" >&2
        gh pr merge --auto --merge "$pr_num" >/dev/null 2>&1 || true
        return 0
    fi

    # Force-push protection probe — always run except in disabled mode.
    # When blocked, abort the merge entirely: returning 0 silently would leave
    # the story PR OPEN forever without auto-merge queued, and the sprint would
    # advance unaware. Halt so the operator can investigate.
    if ! check_force_push_allowed "$story_branch"; then
        echo "::error::trailer injection blocked by force-push protection on $story_branch; aborting merge of PR #${pr_num}" >&2
        exit 1
    fi

    # Detect existing auto-merge + trailer state for idempotent resume.
    local auto_merge_state="" existing_trailer_count="0"
    # Pipe through jq locally so test stubs that emit raw JSON without
    # honoring --jq still resolve null → empty correctly.
    auto_merge_state=$(gh pr view "$pr_num" --json autoMergeRequest 2>/dev/null | jq -r '.autoMergeRequest // empty' 2>/dev/null) || auto_merge_state=""
    # Pipe gh-output through jq locally so stubs that emit raw JSON (without
    # honoring gh's own --jq) still produce parseable messages.
    existing_trailer_count=$(gh api --paginate "repos/${repo_full}/pulls/${pr_num}/commits" 2>/dev/null | jq -r '.[].commit.message' 2>/dev/null | grep -c '^DSO-Story-Merge:' 2>/dev/null) || existing_trailer_count="0"
    [[ -z "$existing_trailer_count" ]] && existing_trailer_count="0"

    local state_key="${auto_merge_state:+enabled},${existing_trailer_count}"
    case "$state_key" in
        enabled,0)
            # Auto-merge queued without trailer — disable, inject, re-enable.
            gh pr merge --disable-auto "$pr_num" >/dev/null 2>&1 || true
            _do_inject_or_dry "$epic" "$story" "$pr_num" || true
            gh pr merge --auto --merge "$pr_num" >/dev/null 2>&1 || true
            ;;
        enabled,*)
            # Trailer present + auto-merge — no-op (idempotent resume).
            echo "::notice::PR #${pr_num} already has trailer + auto-merge; skipping inject" >&2
            ;;
        ,*)
            # No auto-merge — inject then enable.
            _do_inject_or_dry "$epic" "$story" "$pr_num" || true
            gh pr merge --auto --merge "$pr_num" >/dev/null 2>&1 || true
            ;;
    esac
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

# --- Advance to PR2 when PR1 has already merged (runs UNCONDITIONALLY) ---
# The staged-* branch name is persisted in the SOURCE-branch-keyed state file by
# _phase_staged_intermediate (independent of the worktree checkout). If PR1
# (source→staged) is no longer open AND the staged branch still exists AND it
# carries the session work, restore BRANCH to the staged branch so
# _phase_staged_intermediate skips (its `BRANCH == staged-*` guard) and
# _phase_merge opens PR2 — instead of re-creating a duplicate staged ref + PR1.
#
# This detection runs on EVERY invocation, not just --resume (bug 73b5; prior art
# #490/#492): a bare re-invocation after PR1 merged must also advance, not mint a
# duplicate staged ref + PR1. It is a strict no-op before _phase_staged_intermediate
# has written `staged_branch` (field absent → _saved_staged empty → inner block
# skipped), so the normal first-run happy path is unaffected.
#
# Fail-safe: any gh/git uncertainty defaults to "do NOT advance" (finish PR1). The
# staged-work check (bug b7bf-c3b9) prevents advancing onto an EMPTY staged ref
# sitting at main HEAD — the empty-staged advance that lost a live session's work.
if type _state_get_field >/dev/null 2>&1; then
    _saved_staged=$(_state_get_field "staged_branch" "" 2>/dev/null || true)
    if [[ -n "$_saved_staged" && "$BRANCH" != "$_saved_staged" ]]; then
        # 3ebb DD2 / INC-008: read PR1 state from GitHub through the trustworthiness
        # guard. A partial/failed read must NOT be collapsed into a count — treating
        # it as "0 PRs" would advance onto unverified state (skip review); treating
        # it as ">0" would mint a duplicate staged-*+PR1. Neither is safe to GUESS,
        # so re-fetch once (cheap transient mitigation) and, if still indeterminate,
        # HALT as INDETERMINATE rather than act on partial state.
        _pr1_json=""; _pr1_rc=0
        for _attempt in 1 2; do
            _pr1_json=$(gh pr list --head "$BRANCH" --base "$_saved_staged" --state open --json number 2>/dev/null); _pr1_rc=$?
            resume_pr_query_trustworthy "$_pr1_rc" "$_pr1_json" && break
            if [[ "$_attempt" == "2" ]]; then
                # 3ebb DD3: retry budget spent — route to /dso:fp-recovery in-channel
                # (no manual git surgery) rather than guess from partial state.
                if declare -F tristate_indeterminate_escalation >/dev/null 2>&1; then
                    tristate_indeterminate_escalation "merge-to-main:resume-pr1-state" \
                        "could not obtain a trustworthy PR1 state for ${BRANCH} -> ${_saved_staged} (rc=${_pr1_rc}) after a retry; refusing to advance to PR2 or re-create on partial GitHub state (INC-008)" \
                        "$BRANCH"
                else
                    echo "INDETERMINATE: --resume could not obtain trustworthy PR1 state for ${BRANCH} (INC-008) — use /dso:fp-recovery." >&2
                fi
                exit "${TRISTATE_INDETERMINATE:-75}"
            fi
            sleep 1
        done
        _pr1_open=$(printf '%s' "$_pr1_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "1")
        _staged_exists=$(git ls-remote --heads origin "$_saved_staged" 2>/dev/null | wc -l | tr -d ' ')
        # Count session commits on the staged branch not reachable from main.
        # 0 ⇒ empty staged ref at main HEAD ⇒ do NOT advance (b7bf-c3b9). Any
        # git/network failure fails closed to "0" (non-numeric → coerced to 0).
        _staged_work=$( { git ls-remote --heads origin "$_saved_staged" >/dev/null 2>&1 \
            && git fetch origin "${_DEFAULT_BRANCH:-main}" "$_saved_staged" --quiet 2>/dev/null \
            && git rev-list --count "origin/${_DEFAULT_BRANCH:-main}..origin/${_saved_staged}" 2>/dev/null; } || echo "0")
        [[ "$_staged_work" =~ ^[0-9]+$ ]] || _staged_work="0"
        if _resume_should_advance_to_staged "$_pr1_open" "$_staged_exists" "$_staged_work"; then
            echo "INFO: --resume: PR1 merged + staged branch ${_saved_staged} exists — advancing to PR2 (restoring BRANCH=${_saved_staged})" >&2
            BRANCH="$_saved_staged"
            git fetch origin "${_saved_staged}:refs/remotes/origin/${_saved_staged}" --quiet 2>/dev/null || true
            git checkout -B "$_saved_staged" "origin/${_saved_staged}" --quiet 2>/dev/null || true
            # Re-init state for the restored (staged-) BRANCH so downstream phase/
            # pr_url writes land in the correct state file.
            type _state_init >/dev/null 2>&1 && _state_init 2>/dev/null || true
        fi
    fi
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

    # GitHub-side fallback (bug 5ff0-5e4b-84b3-4396): the state file is
    # absent (auto-deleted on prior success at line ~3064) or stale
    # (>4h triggers _state_init skeleton overwrite at merge-helpers.sh:131).
    # In either case the in-memory pr_url is empty even though an open
    # non-draft PR1 still exists on GitHub. Ask GitHub directly. Without
    # this, --resume falls through to _phase_staged_intermediate and
    # creates a duplicate staged-* ref + duplicate PR1 (observed: PRs
    # #490/#492 same source branch, different staged bases).
    if [[ -z "$_RESUME_STATE_PR_URL" ]]; then
        # Resolve only the STAGED PR1 (base=staged-*), never the base=main umbrella
        # draft PR (bug 1f5f / b7bf-c3b9): `--head "$BRANCH"` alone also matches the
        # long-lived session→main umbrella PR (the GitHubPRDefenseStore substrate,
        # e.g. #534/#556), which is NOT a staged promotion PR. Resolving it here made
        # --resume drive the wrong PR and lose the staged promotion. Filter to
        # non-draft PRs whose base is a staged-* branch.
        _RESUME_STATE_PR_URL=$(gh pr list --head "$BRANCH" --state open \
            --json url,isDraft,baseRefName 2>/dev/null \
            | python3 -c "
import json, sys
try:
    prs = json.load(sys.stdin)
    print(next((p['url'] for p in prs
                if not p.get('isDraft', False)
                and str(p.get('baseRefName', '')).startswith('staged-')), ''))
except Exception:
    print('')
" 2>/dev/null || true)
        if [[ -n "$_RESUME_STATE_PR_URL" ]]; then
            echo "INFO: --resume found existing open non-draft PR for ${BRANCH}: ${_RESUME_STATE_PR_URL}" >&2
            echo "INFO: skipping PR-create phases; resuming at PR-wait stage" >&2
        fi
    fi
fi

# Skip the duplicate-PR guard when resuming with a recorded PR.
if [[ -z "$_RESUME_STATE_PR_URL" ]]; then
    if ! _check_duplicate_pr; then
        exit 1
    fi
fi

# 3ebb DD2 / INC-015 (a): assert the current branch is a usable promotion source
# before the PR1/PR2 phase. A worktree left checked out on a SPENT staged-* ref
# (a leftover from an already-merged promotion — 0 commits ahead of origin/main)
# must NOT be driven as a live PR2 source: that produced the confusing 'No commits
# between main and staged-*' stall. This is a DETERMINATE operational error (wrong
# checkout), NOT an INDETERMINATE verdict — so it gives a concrete recovery
# (checkout the feature branch) and exits 1, and is deliberately NOT routed to
# /dso:fp-recovery (fp-recovery cannot fix a wrong-branch checkout). The /tmp
# state cache for spent staged refs is GC'd so a later --resume starts clean.
if [[ "$BRANCH" == staged-* ]]; then
    git fetch origin "${_DEFAULT_BRANCH:-main}" "$BRANCH" --quiet 2>/dev/null || true
    _cur_ahead=$(git rev-list --count "origin/${_DEFAULT_BRANCH:-main}..origin/${BRANCH}" 2>/dev/null \
        || git rev-list --count "origin/${_DEFAULT_BRANCH:-main}..HEAD" 2>/dev/null || echo "")
    if type resume_staged_ref_is_spent >/dev/null 2>&1 && resume_staged_ref_is_spent "$_cur_ahead"; then
        type resume_gc_stale_staged_state >/dev/null 2>&1 && resume_gc_stale_staged_state 2>/dev/null || true
        echo "ERROR [merge-to-main]: current branch '${BRANCH}' is a SPENT staged-* ref — its promotion already merged (0 commits ahead of origin/${_DEFAULT_BRANCH:-main}). This is the INC-015 stale-checkout stall, not a review problem." >&2
        echo "RECOVERY: checkout your feature branch ('git checkout <your-branch>') and re-run merge-to-main. The stale /tmp state cache for spent staged refs has been cleared." >&2
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
    # PR-C: staged-* intermediate runs first; no-op for story-PR mode or
    # already-staged-* BRANCH. Failure routes through the same CONFLICT_DATA
    # emission path below as a _phase_merge failure (test_conflict_data_*).
    _phase_staged_intermediate || _PHASE_MERGE_RC=$?
    [[ "$_PHASE_MERGE_RC" -eq 0 ]] && _phase_merge || _PHASE_MERGE_RC=$?
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

# Defense-in-depth (bug 7a0e): the state file may be absent or path-diverged across
# a BRANCH re-point. Before failing, resolve the open PR directly from GitHub for the
# current BRANCH, so a created PR is never stranded and an already-open PR from a prior
# interrupted run self-heals on the next invocation.
#
# Base-agnostic (bug 8bae-cd51): do NOT pin --base to the default branch. In the
# two-channel flow PR1 (head -> staged-*) and PR2 (staged-* -> main) target
# different bases; pinning --base main returned empty for a staged-base PR1 and
# stranded a mergeable PR. Match the open PR for the head regardless of base,
# selecting the non-draft PR deterministically — mirrors the resume-discovery
# query above (~line 2936).
if [[ -z "$_PR_NUMBER" ]]; then
    _PR_NUMBER=$(gh pr list --head "$BRANCH" --state open \
        --json number,isDraft --jq 'map(select(.isDraft==false)) | .[0].number // empty' 2>/dev/null || true)
    # Validate numeric-only before reuse as a positional arg to gh (defensive: gh's
    # .number is already an integer, but never feed an unvalidated value to a sink).
    if [[ "$_PR_NUMBER" =~ ^[0-9]+$ ]]; then
        _PR_URL=$(gh pr view "$_PR_NUMBER" --json url --jq '.url' 2>/dev/null || true)
        echo "INFO: resolved PR #${_PR_NUMBER} via GitHub fallback (state file did not carry the PR number)" >&2
    else
        _PR_NUMBER=""   # non-numeric (or empty) -> treat as unresolved
    fi
fi

if [[ -z "$_PR_NUMBER" ]]; then
    echo "ERROR: could not resolve PR number for polling phase" >&2
    exit 1
fi

# --- Promote draft PR to ready-for-review (2e68-046a) ---
# On --resume, _phase_merge is skipped so its 075f-ec40 promotion block never
# runs. Promote here unconditionally so both the fresh and resume paths work.
# The guard inside _phase_merge prevents double-promotion on non-resume runs.
_top_is_draft=$(_query_pr_is_draft "$_PR_NUMBER")
if [[ "$_top_is_draft" == "true" ]]; then
    echo "INFO: PR #${_PR_NUMBER} is draft — promoting to ready-for-review."
    _top_ready_out=$(gh pr ready "$_PR_NUMBER" 2>&1) || \
        echo "WARNING: gh pr ready #${_PR_NUMBER} failed (non-fatal): $_top_ready_out" >&2
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

_phase_comment_response "$_PR_NUMBER" || true

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

# --- Step 1: fetch latest default branch so we have the merge commit locally ---
# F-05: use resolved $_DEFAULT_BRANCH instead of literal "main".
# Use explicit refspec to ensure refs/remotes/origin/<default> is populated.
# `git fetch origin <default>` without refspec may only update FETCH_HEAD on
# some git versions (notably Ubuntu git 2.43+) without creating the tracking ref.
_DB_FOR_VERIFY="${_DEFAULT_BRANCH:-main}"
git fetch origin "${_DB_FOR_VERIFY}:refs/remotes/origin/${_DB_FOR_VERIFY}" --quiet 2>/dev/null || \
    git fetch origin "$_DB_FOR_VERIFY" --quiet 2>/dev/null || {
        echo "WARNING: git fetch origin ${_DB_FOR_VERIFY} failed — merge SHA verification may be stale." >&2
    }

# --- Step 2: get the merge commit SHA from the PR ---
MERGE_SHA=$(gh pr view "$_PR_NUMBER" --json mergeCommit --jq .mergeCommit.oid 2>/dev/null || true)
if [[ -z "$MERGE_SHA" ]]; then
    echo "ERROR: Could not retrieve merge commit SHA from PR #${_PR_NUMBER} (URL: ${_PR_URL})" >&2
    exit 1
fi

# --- Step 3: verify it appears on origin/<default> ---
# For squash merges, GitHub's mergeCommit.oid returns the source-branch HEAD SHA
# rather than the new squash commit on the default branch. Fall back to
# git rev-parse origin/<default> when the API SHA is absent.
if ! git log "origin/${_DB_FOR_VERIFY}" --pretty=%H -n 50 2>/dev/null | grep -q "^${MERGE_SHA}$"; then
    _fallback_sha=$(git rev-parse "origin/${_DB_FOR_VERIFY}" 2>/dev/null || true)
    if [[ "$_fallback_sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "INFO: mergeCommit.oid (${MERGE_SHA}) not on origin/${_DB_FOR_VERIFY} — squash-merge fallback: using git rev-parse origin/${_DB_FOR_VERIFY} (${_fallback_sha})" >&2
        MERGE_SHA="$_fallback_sha"
    else
        echo "ERROR: PR reported merged but merge commit ${MERGE_SHA} not found on origin/${_DB_FOR_VERIFY} (PR: ${_PR_URL})" >&2
        exit 1
    fi
fi

echo "INFO: Merge commit ${MERGE_SHA} verified on origin/${_DB_FOR_VERIFY}."

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

# Propagate resume context into direct.sh phase functions (bug cb31-3552).
# _phase_version_bump's resume-skip guard reads DSO_MERGE_RESUMING (the
# library-mode equivalent of direct.sh's _CLI_RESUME local). Without this,
# every --resume in PR mode re-bumps the version on a stale base.
if [[ "${_RESUME:-0}" == "1" ]]; then
    export DSO_MERGE_RESUMING=1
fi

# Architectural fix (b6e3-e771 + bbba-123d): in PR mode the version bump is
# performed BEFORE the PR push (in _phase_source_branch_version_bump), so the
# bump lands in main as part of the PR's squash-merge commit. The post-merge
# version_bump + push phases (and their MAIN_REPO branch-switch + stale-reset
# scaffolding) have been removed. _phase_archive + _phase_ci_trigger remain:
# they log the post-merge preconditions summary and re-trigger CI if HEAD has
# [skip ci]. They both read from origin/main (already fetched at Step 1 above),
# so they do not require local main to be checked out.
#
# Fast-forward local main when MAIN_REPO is a primary checkout that currently
# has main checked out — best-effort, tolerated failures. This is no longer
# required by version_bump, but keeps the local main view in sync with origin
# for any subsequent operations in the same session.
if [[ -d "$MAIN_REPO/.git" ]] || [[ -f "$MAIN_REPO/.git" ]]; then
    (
        cd "$MAIN_REPO" 2>/dev/null || exit 0
        # F-05: use resolved default branch.
        _DB_LOCAL_SYNC="${_DEFAULT_BRANCH:-main}"
        git fetch origin "$_DB_LOCAL_SYNC" --quiet 2>/dev/null || true
        if [[ "$(git branch --show-current 2>/dev/null)" == "$_DB_LOCAL_SYNC" ]]; then
            git merge --ff-only "origin/${_DB_LOCAL_SYNC}" --quiet 2>/dev/null || true
        fi
    )
fi

_phase_archive
_phase_ci_trigger

# Clean up state + marker file on success (mirrors direct.sh tail).
if type _state_file_path >/dev/null 2>&1; then
    rm -f "$(_state_file_path)" 2>/dev/null || true
fi
rm -f "/tmp/merge-state-init-marker-${BRANCH//\//-}" 2>/dev/null || true

echo "DONE: $BRANCH merged via PR ${_PR_URL}; post-merge archive + CI-trigger complete."
exit 0
