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
#   0  = all commits provenanced
#   1  = one or more un-provenanced commits found (written to unprovenanced-shas.txt)
#   2  = BUDGET_EXHAUSTED — API call budget used up before all commits checked
#   3  = OVER_BOUND — non-provenanced commits acknowledged via DSO-Over-Bound: marker
#        (large-diff routed to admin/FP-recovery; skip LLM dispatch)

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

# ── Initialize cache ──────────────────────────────────────────────────────────
if [[ ! -f "$CACHE_FILE" ]]; then
    echo '{}' > "$CACHE_FILE"
fi

# ── Initialize output tracking ────────────────────────────────────────────────
_api_call_count=0
_unprovenanced_shas=()
_over_bound_shas=()
_budget_exhausted=0

# ── Helper: check cache ───────────────────────────────────────────────────────
_cache_get() {
    local sha="$1"
    # Returns "provenanced", "unprovenanced", or empty string if not cached
    local cached
    cached="$(cat "$CACHE_FILE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
sha = sys.argv[1]
if sha in data:
    print(data[sha])
" "$sha" 2>/dev/null)" || true
    echo "$cached"
}

_cache_set() {
    local sha="$1" value="$2"
    local tmp_file
    tmp_file="$(mktemp "${ARTIFACT_DIR}/cache-update.XXXXXX")"
    python3 -c "
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
data[sys.argv[2]] = sys.argv[3]
with open(sys.argv[1], 'w') as f:
    json.dump(data, f)
" "$CACHE_FILE" "$sha" "$value" 2>/dev/null || true
    rm -f "$tmp_file"
}

# ── Walk commits ──────────────────────────────────────────────────────────────
# Get all commits in range BASE_SHA..SESSION_HEAD
while IFS=' ' read -r sha subject; do
    [[ -z "$sha" ]] && continue

    # Step 1: Check for DSO-Story-Merge trailer in commit message
    commit_body="$(git -C "$GIT_REPO_PATH" log -1 --format="%B" "$sha" 2>/dev/null)" || true
    if echo "$commit_body" | grep -qE "^DSO-Story(-Merge)?:"; then
        # Commit is provenanced via story merge trailer — cache and skip
        _cache_set "$sha" "provenanced"
        continue
    fi

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
        continue
    elif [[ "$cached_result" == "unprovenanced" ]]; then
        _unprovenanced_shas+=("$sha")
        continue
    fi

    # Step 3: Check budget before making API call
    if (( _api_call_count >= GH_BUDGET )); then
        echo "BUDGET_EXHAUSTED: API call budget of ${GH_BUDGET} reached before all commits were checked."
        _budget_exhausted=1
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
            echo "BUDGET_EXHAUSTED"
            _budget_exhausted=1
            _unprovenanced_shas+=("$sha")
            continue
        fi
        # Other error — treat as unprovenanced
        _unprovenanced_shas+=("$sha")
        _cache_set "$sha" "unprovenanced"
        continue
    }

    # Check if gh output contains BUDGET_EXHAUSTED signal
    if echo "$pr_result" | grep -q "BUDGET_EXHAUSTED"; then
        echo "BUDGET_EXHAUSTED"
        _budget_exhausted=1
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
    covering_count="$(echo "$pr_result" | PR_UNDER_REVIEW="${PR_NUMBER:-0}" SHA_UNDER_REVIEW="$sha" python3 -c "
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
    print(0)
    sys.exit(0)
if isinstance(data, dict) and 'items' in data:
    pr_list = data['items']
elif isinstance(data, list):
    pr_list = data
else:
    # Non-array, non-items shape (rate-limit error object, etc.) — treat as
    # zero covering PRs. The exit status from _call_gh_with_backoff would
    # have caught the typical error path; if we reached here with an object
    # body, the safe default is 'no covering evidence'.
    print(0)
    sys.exit(0)
count = 0
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
    count += 1
print(count)
" 2>/dev/null)" || covering_count=0

    if (( covering_count > 0 )); then
        _cache_set "$sha" "provenanced"
    else
        _unprovenanced_shas+=("$sha")
        _cache_set "$sha" "unprovenanced"
    fi

done < <(git -C "$GIT_REPO_PATH" log "${BASE_SHA}..${SESSION_HEAD}" --format="%H %s" 2>/dev/null)

# ── Write unprovenanced SHAs to artifact file ─────────────────────────────────
if (( ${#_unprovenanced_shas[@]} > 0 )); then
    printf '%s\n' "${_unprovenanced_shas[@]}" > "$UNPROVENANCED_FILE"
    printf '%s\n' "${_unprovenanced_shas[@]}"
fi

# ── Exit with appropriate code ────────────────────────────────────────────────
if (( _budget_exhausted )); then
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
