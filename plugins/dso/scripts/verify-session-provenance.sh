#!/usr/bin/env bash
# verify-session-provenance.sh
#
# Verifies that every commit in main..SESSION_HEAD is provenanced — either by
# a DSO-Story-Merge trailer (squash or no-ff story merge) or by a linked GitHub
# PR (ci-pr mode).
#
# ── Environment overrides (for testability) ───────────────────────────────────
#   DSO_REPO_PATH      Override the git repository path (default: current dir)
#   DSO_BASE_SHA       Override the base commit (default: main branch tip)
#   DSO_SESSION_HEAD   Override the range endpoint (default: HEAD)
#   DSO_ARTIFACT_DIR   Override the artifact directory (default: /tmp)
#   DSO_GH_REPO        Override owner/repo for GitHub API calls
#   DSO_GH_BUDGET      Override the maximum number of gh API calls (default: 200)
#
# ── Exit codes ────────────────────────────────────────────────────────────────
#   0  = all commits provenanced (writes provenance-complete.marker + covered-shas.txt)
#   1  = one or more un-provenanced commits found (writes unprovenanced-shas.txt + marker + covered)
#   2  = BUDGET_EXHAUSTED — API call budget used up before all commits checked
#   3  = OVER_BOUND — non-provenanced commits acknowledged via DSO-Over-Bound: marker
#        (writes over-bound-shas.txt + marker + covered; large-diff routed to admin/FP-recovery)
#   4  = BASE_SHA or SESSION_HEAD unreachable in working tree (configuration error;
#        no marker written — distinguishes 'never ran cleanly' from 'ran cleanly')
#
# Exit-code contract details: docs/contracts/verify-session-provenance-exit-codes.md (under ${CLAUDE_PLUGIN_ROOT})

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
ARTIFACT_DIR="${DSO_ARTIFACT_DIR:-/tmp}"
GH_BUDGET="${DSO_GH_BUDGET:-200}"
CACHE_FILE="${ARTIFACT_DIR}/session-provenance-cache.json"
UNPROVENANCED_FILE="${ARTIFACT_DIR}/unprovenanced-shas.txt"

# ── Backoff state ─────────────────────────────────────────────────────────────
_backoff_delay=2

_call_gh_with_backoff() {
    local result exit_code
    # Bound the retry loop: PR #140 retro-review found that persistent 429
    # or 403 responses would retry indefinitely (max delay 60s/retry); the
    # only escape was via the outer GH_BUDGET counter on _api_call_count,
    # which is not always checked. Cap at GH_RETRY_MAX (default 8) so the
    # call surfaces a failure to the caller within a bounded wall-clock
    # window even when the API persistently rate-limits.
    local _gh_retry_max="${GH_RETRY_MAX:-8}"
    local _gh_retry_count=0
    while true; do
        # set -e + cmd substitution can abort the function before exit_code
        # is read in some bash versions (Copilot finding 2026-05-16).
        # Bracket with `set +e ... set -e` so a non-zero gh exit reliably
        # flows into the exit_code check instead of unwinding the call stack.
        set +e
        result=$(gh "$@" 2>&1)
        exit_code=$?
        set -e
        if [[ $exit_code -eq 0 ]]; then
            echo "$result"
            return 0
        fi
        if [[ "$result" == *"429"* ]] || [[ "$result" == *"403"* ]]; then
            _gh_retry_count=$(( _gh_retry_count + 1 ))
            if (( _gh_retry_count >= _gh_retry_max )); then
                echo "ERROR: _call_gh_with_backoff exhausted ${_gh_retry_max} retries on persistent ${result:0:200}" >&2
                return "${exit_code:-1}"
            fi
            sleep "$_backoff_delay"
            _backoff_delay=$(( _backoff_delay * 2 ))
            (( _backoff_delay > 60 )) && _backoff_delay=60
        else
            echo "$result" >&2
            return $exit_code
        fi
    done
}

# ── Resolve git repo and range ────────────────────────────────────────────────
GIT_REPO_PATH="${DSO_REPO_PATH:-.}"
SESSION_HEAD="${DSO_SESSION_HEAD:-HEAD}"

# Determine base: explicit DSO_BASE_SHA or main branch
if [[ -n "${DSO_BASE_SHA:-}" ]]; then
    BASE_SHA="$DSO_BASE_SHA"
else
    BASE_SHA="$(git -C "$GIT_REPO_PATH" rev-parse main 2>/dev/null || git -C "$GIT_REPO_PATH" rev-parse origin/main 2>/dev/null)"
fi

# ── Resolve owner/repo for GitHub API ─────────────────────────────────────────
if [[ -n "${DSO_GH_REPO:-}" ]]; then
    GH_REPO="$DSO_GH_REPO"
else
    _origin="$(git -C "$GIT_REPO_PATH" remote get-url origin 2>/dev/null)" || true
    GH_REPO="$(echo "$_origin" | sed -E 's|.*[:/]([^/.]+/[^/.]+)(\.git)?$|\1|')" || true
fi

# ── Cache schema and key format (bug 8a77 v3 hardening, folds Bug E) ──────────
# Cache file shape (v3):
#   {
#     "cache_version": 3,
#     "entries": {
#       "<sha>.pr<N>": "provenanced" | "unprovenanced",
#       ...
#     }
#   }
#
# The key is `${sha}.pr${PR_NUMBER:-0}`. This lets the same SHA produce
# different verdicts under different PR contexts (a commit that is "covered"
# by PR #252 when reviewed from PR #253 may not be "covered" when reviewed
# from PR #252 itself — the self-exclusion filter changes the answer).
#
# Cache poisoning prevention: only verified verdicts ("provenanced" /
# "unprovenanced") are cached. API errors (rate-limit, 404, timeout) yield
# "unknown-due-to-error" which is NOT persisted — the next CI run will
# re-evaluate that SHA rather than reading a stale failure verdict.
#
# Migration: on load, ledgers with version != 3 are silently ignored (treated
# as empty cache). Avoids the per-key migration headache; first write seeds
# the new shape.
#
# Cache version history:
#   v2 → v3: R2 poison-on-failure semantics. v2 used short-circuit-on-first-
#     success classification; v3 uses collect-all-then-classify with failure
#     poisoning the SHA. v2 cached verdicts may have masked failures, so they
#     are invalidated on first read under v3.
#   v3 → v4: removal of the DSO-Story(-Merge) trailer self-attestation
#     shortcut (PR-R1, post-audit Finding 3). v3 may have cached commits as
#     `provenanced` based solely on trailer presence, without verifying the
#     covering PR's review-sub-pr status. Under the two-tier promotion model
#     (PR-C: feature → staged-* → main), every commit reaching main has a
#     covering PR (PR1 = worktree-* → staged-*) whose review-sub-pr is
#     required by the sub-PR ruleset; the API path at :476+ now serves as
#     the sole authority. v3 cache entries are invalidated on first load.
CACHE_VERSION=4

# ── Initialize cache ──────────────────────────────────────────────────────────
_cache_init() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        printf '{"cache_version": %s, "entries": {}}\n' "$CACHE_VERSION" > "$CACHE_FILE"
        return 0
    fi
    # Validate existing cache file: must be JSON and carry the expected version.
    local valid
    valid="$(python3 -c "
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        print('invalid')
        sys.exit(0)
    if data.get('cache_version') != int(sys.argv[2]):
        print('invalid')
        sys.exit(0)
    if not isinstance(data.get('entries'), dict):
        print('invalid')
        sys.exit(0)
    print('valid')
except Exception:
    print('invalid')
" "$CACHE_FILE" "$CACHE_VERSION" 2>/dev/null)" || valid="invalid"
    if [[ "$valid" != "valid" ]]; then
        # Corrupted or wrong-version cache; rewrite empty. Use atomic_write
        # so a concurrent reader never sees a partial JSON.
        echo "WARNING: provenance cache schema mismatch or invalid; reinitializing" >&2
        _atomic_write_cache "{\"cache_version\": $CACHE_VERSION, \"entries\": {}}"
    fi
}

# ── Helper: atomic cache write (folds in Bug E lock-free race fix) ────────────
_atomic_write_cache() {
    local payload="$1"
    local tmp_file
    tmp_file="$(mktemp "${ARTIFACT_DIR}/cache-write.XXXXXX")" || {
        echo "WARNING: cache write failed (mktemp); bypassing cache for this run" >&2
        return 1
    }
    # Write to temp + rename = atomic; a concurrent reader either sees the old
    # complete file or the new complete file, never a half-written file.
    if ! printf '%s\n' "$payload" > "$tmp_file"; then
        echo "WARNING: cache write failed (write to tmp); bypassing cache for this run" >&2
        rm -f "$tmp_file"
        return 1
    fi
    if ! mv -f "$tmp_file" "$CACHE_FILE"; then
        echo "WARNING: cache write failed (atomic rename); bypassing cache for this run" >&2
        rm -f "$tmp_file"
        return 1
    fi
    return 0
}

# ── Initialize output tracking ────────────────────────────────────────────────
_api_call_count=0
_unprovenanced_shas=()
_over_bound_shas=()
_covered_shas=()        # bug 8a77 v2 MF3: SHAs classified as provenanced (trailer/cache/API)
_budget_exhausted=0
_post_budget_unprovenanced=0

_cache_init

# ── Cache key derivation (per-PR — bug 8a77 v3) ───────────────────────────────
_cache_key() {
    local sha="$1"
    # PR_NUMBER from env (ci.yml exports it); 0 when unset.
    local _pr="${PR_NUMBER:-0}"
    if ! [[ "$_pr" =~ ^[0-9]+$ ]]; then
        _pr=0
    fi
    echo "${sha}.pr${_pr}"
}

# ── Helper: check cache ───────────────────────────────────────────────────────
_cache_get() {
    local sha="$1"
    local key
    key="$(_cache_key "$sha")"
    # Returns "provenanced", "unprovenanced", or empty string if not cached.
    # Surfaces JSON-decode failures via the Python script's print-to-stderr
    # (which inherits the caller's stderr — no fd juggling needed).
    local cached
    cached="$(python3 -c "
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    entries = data.get('entries', {}) if isinstance(data, dict) else {}
    key = sys.argv[2]
    if key in entries:
        # Defensive: only print recognized verdicts; otherwise treat as miss.
        verdict = entries[key]
        if verdict in ('provenanced', 'unprovenanced'):
            print(verdict)
except Exception as e:
    print(f'WARNING: _cache_get parse failure: {e}', file=sys.stderr)
" "$CACHE_FILE" "$key" 2>/dev/null)" || cached=""
    echo "$cached"
}

_cache_set() {
    local sha="$1" value="$2"
    # Bug 8a77 v3: do NOT cache "unknown-due-to-error" — caller passes the
    # verified verdict only. The "unknown" case bypasses the cache so the
    # next CI run re-evaluates.
    if [[ "$value" != "provenanced" && "$value" != "unprovenanced" ]]; then
        echo "WARNING: _cache_set refusing to cache non-verified verdict '$value' for $sha" >&2
        return 0
    fi
    local key
    key="$(_cache_key "$sha")"
    # Read-modify-write under the atomic_write helper. A concurrent invocation
    # may overwrite our write; that's acceptable for a verdict cache (the
    # next read will re-fetch from API). The atomic_write ensures readers
    # never see a half-written file.
    local new_payload
    new_payload="$(python3 -c "
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    data = {'cache_version': int(sys.argv[4]), 'entries': {}}
if not isinstance(data, dict):
    data = {'cache_version': int(sys.argv[4]), 'entries': {}}
data.setdefault('cache_version', int(sys.argv[4]))
entries = data.setdefault('entries', {})
if not isinstance(entries, dict):
    entries = {}
    data['entries'] = entries
entries[sys.argv[2]] = sys.argv[3]
print(json.dumps(data))
" "$CACHE_FILE" "$key" "$value" "$CACHE_VERSION" 2>/dev/null)" || {
        echo "WARNING: _cache_set payload build failed for $sha; bypassing cache for this entry" >&2
        return 1
    }
    _atomic_write_cache "$new_payload" || return 1
    return 0
}

# ── Pre-walk reachability guard (bug 8a77 v2) ─────────────────────────────────
# `git log $BASE..$HEAD 2>/dev/null` returns empty stdout — silently — when
# either SHA is unreachable in the working tree (typical under
# `actions/checkout@v4` with default fetch-depth=1; the action fetches
# refs/pull/N/merge but NOT pull/N/head). The empty stdout previously caused
# the while-loop to iterate zero times and the script fell through to
# "All commits provenanced" exit 0, bypassing the A1-A4 layered filters
# entirely. Surface the failure loudly via the shared reachability helper.
_REACHABILITY_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/reachability.sh"
if [[ ! -f "$_REACHABILITY_LIB" ]]; then
    echo "ERROR: required helper $_REACHABILITY_LIB not found" >&2
    exit 4
fi
# shellcheck source=lib/reachability.sh
source "$_REACHABILITY_LIB"

assert_sha_reachable "$BASE_SHA" "BASE_SHA" "$GIT_REPO_PATH" || exit 4
assert_sha_reachable "$SESSION_HEAD" "SESSION_HEAD" "$GIT_REPO_PATH" || exit 4

# ── Determine the upstream "already-shipped" ref for filter exclusion ─────────
# Mirror PR-1d's dispatcher-side filter on the verifier side: commits already
# reachable from origin/main (or whatever base ref is set) have already been
# walked when they were originally landed. Walking them here is wasteful —
# for feature branches based on older main snapshots, this can add thousands
# of commits to the walk that each require cache lookups or GitHub API calls.
#
# The filter uses `git log A..B ^C` (equivalent to --not C) to exclude any
# commit reachable from C. C defaults to origin/main; honor DSO_UPSTREAM_REF
# when callers need a different base. Empty-string DSO_UPSTREAM_REF is
# treated as an explicit disable signal (callers who want unfiltered walk).
#
# SCOPE LIMITATION: this filter is SHA-identity-based. It correctly excludes
# commits whose SHAs are reachable from upstream (merge-commit workflows).
# It does NOT exclude:
#   - Squash-merged commits — original branch SHAs are unreachable from the
#     squash commit; the covering-PR detection (lines ~310-580) still handles
#     those via DSO-Story-Merge trailer or PR API lookup.
#   - Rebase-merged commits — similar to squash; new SHAs on main differ from
#     original branch SHAs.
#   - Cherry-picked commits — the patch is on main but as a different SHA,
#     so the original SHA on the feature branch is still walked. Correct
#     behavior — the feature-branch version may have subsequent changes.
# This is consistent with PR-1d's dispatcher-side filter (same env var).
#
# Robustness:
#   - Unresolvable upstream ref → fallback to unfiltered walk (safe; the worst
#     case is the prior O(N) behavior, not a correctness gap).
#   - Shallow repository → fallback to unfiltered walk (`git rev-list` would
#     return truncated history → randomly partial filter).
#   - Empty DSO_UPSTREAM_REF → explicit disable (no fallback to origin/main).
# Defense-in-depth: PR-1d's dispatcher filter still provides giant-diff
# protection downstream even when the verifier walks unfiltered.
#
# Side effect: commits excluded by this filter no longer get cache entries
# written. If a future run faces a rewritten history where one of those
# SHAs falls back into BASE..HEAD without an upstream entry, the verifier
# pays cold-cache cost re-classifying it. Acceptable tradeoff vs. the
# steady-state walk cost reduction (6000+ → 3-10 commits per PR typically).
# Default mirrors the dispatcher's _MAIN_REF resolution
# (llm-review-dispatch-or-skip.sh line 307): `origin/${GITHUB_BASE_REF:-main}`.
# This keeps verifier and dispatcher filters aligned by default so PR-mode
# targeting a non-main base branch doesn't cause provenance/dispatch mismatch.
# DSO_UPSTREAM_REF overrides for tests or non-standard layouts.
if [[ -z "${DSO_UPSTREAM_REF+x}" ]]; then
    _UPSTREAM_REF="origin/${GITHUB_BASE_REF:-main}"
else
    _UPSTREAM_REF="$DSO_UPSTREAM_REF"  # may be empty → explicit disable below
fi
# LAUNDERING NOTE (TS-1 / P9): the `^${_UPSTREAM_REF}` exclusion below equates
# "reachable from origin/main" with "already reviewed" — which is FALSE for any
# SHA that reached main unreviewed (admin bypass / hotfix / prior slip). It is
# kept here as a scope/perf optimization for THIS verifier's dispatch decision,
# but it is NOT the safety guarantee. The independent, fail-closed Goal-1
# guarantee is the review-coverage-invariant check (scripts/ci/ under the plugin
# root), which resolves the full origin/main..HEAD set with NO reachability
# prefilter and requires each SHA to be PROVEN reviewed. Do not treat this
# exclusion as coverage enforcement.
_UPSTREAM_EXCLUDE_ARGS=()
if [[ -n "$_UPSTREAM_REF" ]]; then
    if git -C "$GIT_REPO_PATH" rev-parse --verify --quiet "$_UPSTREAM_REF" >/dev/null 2>&1; then
        # Skip filtering on shallow repos — git rev-list would return
        # truncated history and the filter would be partially/randomly active.
        # CI's "Verify session provenance" step now does a full fetch of the
        # base ref (ci.yml line ~466); this check remains as defense-in-depth
        # for non-CI callers running in shallow contexts.
        if [[ "$(git -C "$GIT_REPO_PATH" rev-parse --is-shallow-repository 2>/dev/null)" != "true" ]]; then
            _UPSTREAM_EXCLUDE_ARGS=("^${_UPSTREAM_REF}")
        fi
    fi
fi

# ── Walk commits ──────────────────────────────────────────────────────────────
# Get all commits in range BASE_SHA..SESSION_HEAD, EXCLUDING commits already
# reachable from the upstream ref (already-shipped via prior PRs).
while IFS=' ' read -r sha subject; do
    [[ -z "$sha" ]] && continue

    # Step 1 (was: DSO-Story trailer shortcut) — REMOVED in v4 (PR-R1).
    # The trailer-presence shortcut was a self-attested claim, not evidence:
    # a commit with a fabricated trailer was previously marked `provenanced`
    # without any covering-PR verification (audit Finding 3). Removed so that
    # every commit is verified through the same API path (covering PR with
    # passing review-sub-pr). Under the two-tier promotion model (PR-C), the
    # covering PR for worktree-* commits is PR1 (worktree-* → staged-*),
    # whose review-sub-pr is required by the sub-PR ruleset; squash-merged
    # story commits also resolve to PR1 via the GitHub commits/<sha>/pulls
    # endpoint. The trailer remains in commit messages as human-readable
    # attribution metadata; it is no longer load-bearing for provenance.
    commit_body="$(git -C "$GIT_REPO_PATH" log -1 --format="%B" "$sha" 2>/dev/null)" || true

    # Step 1b: Check for DSO-Over-Bound: marker (acknowledged non-provenanced)
    if echo "$commit_body" | grep -q "^DSO-Over-Bound:"; then
        # Commit is acknowledged as non-provenanced (large-diff / OVER_BOUND path)
        echo "commit $sha status=OVER_BOUND; acknowledged non-provenanced (large-diff routed to FP-recovery)"
        _over_bound_shas+=("$sha")
        continue
    fi

    # Step 2: Check SHA→PR cache
    cached_result="$(_cache_get "$sha")"
    if [[ "$cached_result" == "provenanced" ]]; then
        _covered_shas+=("$sha")   # bug 8a77 v2 MF2 site (b): cache-hit provenanced
        continue
    elif [[ "$cached_result" == "unprovenanced" ]]; then
        _unprovenanced_shas+=("$sha")
        continue
    fi

    # Step 3: Check budget before making API call
    if (( _api_call_count >= GH_BUDGET )); then
        if (( _budget_exhausted == 0 )); then
            echo "BUDGET_EXHAUSTED: API call budget of ${GH_BUDGET} reached before all commits were checked."
            _budget_exhausted=1
        fi
        _post_budget_unprovenanced=$(( _post_budget_unprovenanced + 1 ))
        _unprovenanced_shas+=("$sha")
        continue
    fi

    # Step 4: Call gh api to check for associated PR
    _api_call_count=$(( _api_call_count + 1 ))

    # Build the gh api path — use explicit GH_REPO when available
    if [[ -n "${GH_REPO:-}" ]]; then
        _gh_api_path="repos/${GH_REPO}/commits/${sha}/pulls"
    else
        # No explicit repo — use relative path and let gh infer context
        _gh_api_path="repos/{owner}/{repo}/commits/${sha}/pulls"
    fi

    pr_result="$(_call_gh_with_backoff api "$_gh_api_path" 2>&1)" || {
        # Check if gh itself signaled budget exhaustion
        if echo "$pr_result" | grep -q "BUDGET_EXHAUSTED"; then
            if (( _budget_exhausted == 0 )); then
                echo "BUDGET_EXHAUSTED"
                _budget_exhausted=1
            fi
            _post_budget_unprovenanced=$(( _post_budget_unprovenanced + 1 ))
            _unprovenanced_shas+=("$sha")
            continue
        fi
        # Bug 8a77 v3 hardening: API error → flag in-memory as unprovenanced
        # so CI surfaces the failure, but DO NOT cache. Caching the failure
        # would poison the cache through the rest of the run and across
        # subsequent CI re-runs (the SHA would be permanently marked
        # unprovenanced until cache_version bump). The next CI run will
        # re-fetch from the API.
        echo "WARNING: gh api failed for $sha; flagging unprovenanced (not cached): ${pr_result:0:200}" >&2
        _unprovenanced_shas+=("$sha")
        continue
    }

    # Check if gh output contains BUDGET_EXHAUSTED signal
    if echo "$pr_result" | grep -q "BUDGET_EXHAUSTED"; then
        if (( _budget_exhausted == 0 )); then
            echo "BUDGET_EXHAUSTED"
            _budget_exhausted=1
        fi
        _post_budget_unprovenanced=$(( _post_budget_unprovenanced + 1 ))
        _unprovenanced_shas+=("$sha")
        continue
    fi

    # ─── Layered provenance filter (bug 8a77 fix) ────────────────────────────
    # The GitHub API `repos/{owner}/{repo}/commits/{sha}/pulls` endpoint
    # returns EVERY PR whose branch HEAD history contains this commit —
    # including the PR being reviewed. Counting any non-empty list as
    # "covered" was the pre-fix bug that silently disabled llm-review on
    # every PR. We now apply 4 filters and count only PRs that survive:
    #
    #   A2  state == "closed" AND merged_at != null  (merged PRs only — an
    #        open/draft/closed-unmerged PR carries no review evidence)
    #   A3a head.sha != $sha                          (PR cannot cover its
    #        own HEAD commit — defends push-event case where PR_NUMBER is
    #        unset)
    #   A3b merge_commit_sha != $sha                  (self-merge guard)
    #   A1  number != $PR_NUMBER                      (self-exclusion when
    #        PR_NUMBER env is set; no-op when unset since GitHub PR numbers
    #        are always > 0)
    #
    # A3c (ancestor filter — require covering PR's merge_commit_sha to be an
    # ancestor of BASE_SHA) was deliberately DROPPED during v2 review: it is
    # broken under CI's depth-1 shallow fetch (ci.yml:431 does
    # `git fetch --depth=1 origin <base_ref>`), so `git merge-base
    # --is-ancestor` returns false for genuinely-covering merge SHAs that
    # are not in the shallow fetch — producing false unprovenanced verdicts.
    # Do not re-introduce A3c without first solving the shallow-fetch
    # problem (e.g., `git fetch <covering_merge_sha>` before the check).
    #
    # Non-array responses (rate-limit / 404 / object envelope) yield
    # covering_count=0 → treated as unprovenanced. The status code from
    # _call_gh_with_backoff is the load-bearing signal; a successful HTTP
    # 200 with an object body means the parser falls through to 0.
    # Extract covering PR numbers (not just count) so G3 can verify review status.
    covering_prs="$(echo "$pr_result" | PR_UNDER_REVIEW="${PR_NUMBER:-0}" SHA_UNDER_REVIEW="$sha" python3 -c "
import sys, json, os
pr_under_review_str = os.environ.get('PR_UNDER_REVIEW', '0')
try:
    pr_under_review = int(pr_under_review_str)
except (TypeError, ValueError):
    pr_under_review = 0
sha_under_review = os.environ.get('SHA_UNDER_REVIEW', '')
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(data, dict) and 'items' in data:
    pr_list = data['items']
elif isinstance(data, list):
    pr_list = data
else:
    sys.exit(0)
for pr in pr_list:
    if not isinstance(pr, dict):
        continue
    # A2: must be merged (state==closed AND merged_at present and non-null)
    if pr.get('state') != 'closed':
        continue
    if not pr.get('merged_at'):
        continue
    # A3a: PR cannot cover its own HEAD
    head_sha = (pr.get('head') or {}).get('sha', '')
    if head_sha == sha_under_review:
        continue
    # A3b: self-merge guard
    if pr.get('merge_commit_sha') == sha_under_review:
        continue
    # A1: exclude the PR being reviewed (self-exclusion via env var)
    if pr_under_review > 0 and pr.get('number') == pr_under_review:
        continue
    print(pr.get('number', ''))
" 2>/dev/null)" || covering_prs=""

    # G3 fix: verify that each covering PR's review-sub-pr check actually
    # passed. A covering merged PR that failed or skipped review does not
    # constitute valid provenance. Without this, admin-merged PRs that
    # failed review would incorrectly count as "covered."
    _verified_covering=0
    if [[ -n "$covering_prs" ]]; then
        while IFS= read -r _cov_pr; do
            [[ -z "$_cov_pr" ]] && continue
            if (( _api_call_count >= GH_BUDGET )); then
                if (( _budget_exhausted == 0 )); then
                    echo "BUDGET_EXHAUSTED during G3 review-check verification" >&2
                    _budget_exhausted=1
                fi
                break
            fi
            _api_call_count=$(( _api_call_count + 1 ))
            # Query check-runs for the covering PR's head SHA to find review-sub-pr status.
            # Use the commits/{sha}/check-runs endpoint filtered to the review check name.
            _cov_head_sha=""
            _cov_stderr_file="$(mktemp)"
            _cov_head_sha="$(echo "$pr_result" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception as exc:
    print(f'JSON parse: {type(exc).__name__}: {exc}', file=sys.stderr)
    sys.exit(0)
if isinstance(data, dict) and 'items' in data:
    pr_list = data['items']
elif isinstance(data, list):
    pr_list = data
else:
    print(f'unexpected response shape: {type(data).__name__}', file=sys.stderr)
    sys.exit(0)
target = int(sys.argv[1])
for pr in pr_list:
    if isinstance(pr, dict) and pr.get('number') == target:
        head_sha = (pr.get('head') or {}).get('sha', '')
        if not head_sha:
            print(f'PR #{target} present but missing head.sha', file=sys.stderr)
        print(head_sha)
        break
else:
    print(f'PR #{target} not found in {len(pr_list)} listed PRs', file=sys.stderr)
" "$_cov_pr" 2>"$_cov_stderr_file")" || _cov_head_sha=""
            if [[ -z "$_cov_head_sha" ]]; then
                _cov_parse_err="$(head -c 200 "$_cov_stderr_file" 2>/dev/null | tr '\n' ' ')"
                rm -f "$_cov_stderr_file"
                echo "WARNING: could not resolve head SHA for covering PR #${_cov_pr}; treating as unverified (parse: ${_cov_parse_err:-no-stderr})" >&2
                continue
            fi
            rm -f "$_cov_stderr_file"
            # Check if review-sub-pr passed on the covering PR
            if [[ -n "${GH_REPO:-}" ]]; then
                _checks_path="repos/${GH_REPO}/commits/${_cov_head_sha}/check-runs"
            else
                _checks_path="repos/{owner}/{repo}/commits/${_cov_head_sha}/check-runs"
            fi
            _check_result="$(_call_gh_with_backoff api "$_checks_path" 2>&1)" || {
                _check_err_snippet="$(printf '%s' "${_check_result:-(no output)}" | head -c 200 | tr '\n' ' ')"
                echo "WARNING: check-runs API failed for covering PR #${_cov_pr} (${_cov_head_sha:0:8}); treating as unverified. gh output: ${_check_err_snippet}" >&2
                continue
            }
            # R2 (v4): poison-on-failure semantics. The GitHub check-runs API
            # returns ALL historical runs for a SHA, not just the latest. The
            # prior implementation short-circuited on first conclusion=success,
            # which let "fail → admin rerun → success" sequences silently mask
            # the original failure. Now: any failure-class conclusion in the
            # history of the covering check-run name poisons the SHA, regardless
            # of later successes. Cancelled/timeout/action_required are treated
            # as failures because they all mean "no completed review evidence."
            # The `name` filter preserves the original substring matching so
            # unrelated check-runs (e.g. Hook Tests failure) do NOT poison the
            # review verdict.
            _review_passed="$(echo "$_check_result" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print('unknown')
    sys.exit(0)
runs = data.get('check_runs', []) if isinstance(data, dict) else []
matching = [r for r in runs
            if 'review-sub-pr' in r.get('name', '')
            or 'llm-review' in r.get('name', '')]
failures = [r for r in matching
            if r.get('conclusion') in ('failure', 'cancelled', 'timed_out', 'action_required')]
successes = [r for r in matching if r.get('conclusion') == 'success']
if failures:
    print('failed')
elif successes:
    print('passed')
else:
    print('not_found')
" 2>/dev/null)" || _review_passed="unknown"
            case "$_review_passed" in
                passed)
                    _verified_covering=$(( _verified_covering + 1 ))
                    echo "commit $sha covering-PR #${_cov_pr} review-check=PASSED"
                    ;;
                failed)
                    echo "commit $sha covering-PR #${_cov_pr} review-check=FAILED (not counting as covered)"
                    ;;
                not_found)
                    echo "commit $sha covering-PR #${_cov_pr} review-check=NOT_FOUND (not counting as covered — no review evidence)"
                    ;;
                *)
                    echo "WARNING: commit $sha covering-PR #${_cov_pr} review-check=UNKNOWN; treating as unverified" >&2
                    ;;
            esac
        done <<< "$covering_prs"
    fi

    # `|| true` per the documented "bypass cache for this run" semantics —
    # see commentary on the trailer-cache call site above.
    if (( _verified_covering > 0 )); then
        _covered_shas+=("$sha")   # bug 8a77 v2 MF2 site (c): API-covered (BEFORE cache_set)
        _cache_set "$sha" "provenanced" || true
    else
        _unprovenanced_shas+=("$sha")
        _cache_set "$sha" "unprovenanced" || true
    fi

done < <(git -C "$GIT_REPO_PATH" log "${BASE_SHA}..${SESSION_HEAD}" "${_UPSTREAM_EXCLUDE_ARGS[@]}" --format="%H %s")

# ── Write unprovenanced SHAs to artifact file ─────────────────────────────────
if (( ${#_unprovenanced_shas[@]} > 0 )); then
    printf '%s\n' "${_unprovenanced_shas[@]}" > "$UNPROVENANCED_FILE"
    printf '%s\n' "${_unprovenanced_shas[@]}"
fi

# ── Write over-bound SHAs to artifact file (bug 8a77 v2 MF1) ──────────────────
# Without this, the dispatcher's `[[ -s over-bound-shas.txt ]]` route check
# is dead code and OVER_BOUND commits silently route as exit 0.
if (( ${#_over_bound_shas[@]} > 0 )); then
    printf '%s\n' "${_over_bound_shas[@]}" > "${ARTIFACT_DIR}/over-bound-shas.txt"
fi

# ── Write success marker and covered-list artifacts (bug 8a77 v2 Change F) ────
# The success marker proves the verifier ran to completion without an
# unreachable-SHA or other early-exit error. Downstream consumers (dispatcher)
# require this marker before trusting "no unprovenanced file" == all-provenanced.
# Without the marker, "absent file" is ambiguous (crash vs. clean exit).
_MARKER="${ARTIFACT_DIR}/provenance-complete.marker"
_COVERED_FILE="${ARTIFACT_DIR}/covered-shas.txt"

# covered-shas.txt: every SHA the walk classified as provenanced (trailer /
# cache / API). Used by the dispatcher's "Covered by sub-PR reviews:" line
# rather than re-walking BASE..HEAD (which is vulnerable to shallow clones).
if (( ${#_covered_shas[@]} > 0 )); then
    printf '%s\n' "${_covered_shas[@]}" > "$_COVERED_FILE"
else
    : > "$_COVERED_FILE"   # empty file = no covered SHAs (e.g., empty range)
fi

# Success marker (touched only on clean walk completion — NOT on exit 4)
date -u +%Y-%m-%dT%H:%M:%SZ > "$_MARKER"

# ── Exit with appropriate code ────────────────────────────────────────────────
if (( _budget_exhausted )); then
    echo "BUDGET_EXHAUSTED summary: ${_api_call_count} API call(s) made (budget=${GH_BUDGET}); ${_post_budget_unprovenanced} commit(s) marked unprovenanced post-exhaustion; ${#_covered_shas[@]} provenanced via trailer/cache."
    exit 2
elif (( ${#_unprovenanced_shas[@]} > 0 )); then
    exit 1
elif (( ${#_over_bound_shas[@]} > 0 )); then
    echo "OVER_BOUND: ${#_over_bound_shas[@]} commit(s) acknowledged as non-provenanced (large-diff routed to admin review)"
    exit 3
else
    echo "All commits provenanced"
    exit 0
fi
