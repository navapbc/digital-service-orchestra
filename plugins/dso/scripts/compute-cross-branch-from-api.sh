#!/usr/bin/env bash
# Compute cross-branch file set from auto-merged story PRs via GitHub API.
# Fallback for ci-pr mode where DSO-Story-Merge trailers may be absent on the
# session branch (e.g., GitHub auto-merge commits without --body propagation).
#
# Supported merge-commit subject:
#   ^Merge pull request #[0-9]+ from [^/]+/story/[^/]+/[^/]+$
# Custom-subject merges fall through to API fallback alone.
#
# OUTPUT: APPENDS to CROSS_BRANCH_FILE (does not truncate). Existing
# LC_ALL=C sort -u downstream dedups with any trailer-grep output.
#
# Concurrent invocations on DIFFERENT stories are safe; concurrent
# invocations sharing the SAME PR number are undefined (caller serializes).
#
# Edge case: PRs merged into a session branch BEFORE the branch was renamed
# retain base=<old-name>. The git-log path (primary derivation) catches them;
# API fallback may miss them, degrades gracefully via unprovenanced-commits.
#
# IMPLEMENTATION CONSTRAINT: main() body MUST be a top-level for-loop. Do not
# refactor to subshell pipelines — `continue` semantics depend on top-level
# bash context.
set -euo pipefail
export LC_ALL=C

# -----------------------------------------------------------------------------
# Required env vars (with defaults)
# -----------------------------------------------------------------------------
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${HEAD_REF:?HEAD_REF is required}"
: "${BASE_REF:?BASE_REF is required}"
CROSS_BRANCH_FILE="${CROSS_BRANCH_FILE:-${ARTIFACT_DIR:-/tmp}/cross-branch-files.txt}"

# Ensure output dir exists, touch file (idempotent — append semantics)
mkdir -p "$(dirname "$CROSS_BRANCH_FILE")" 2>/dev/null || true
touch "$CROSS_BRANCH_FILE"

# -----------------------------------------------------------------------------
# gh_api_with_retry: invoke gh api, classify status, handle 403/429 retry
#
# Args: $1 = api path, $2 = output file (stdout capture), $3 = retry_count (internal)
# Stdout: status code label ("200" | "404")
# Exit: 0 on success/404, 1 on unrecoverable error (5xx, exhausted 403)
#
# Production-only error handling — no test-mode coupling. Test scenarios that
# exercise 403/429/404 paths do so via argv-dispatch in the gh stub, never via
# env-var coupling to this function.
# -----------------------------------------------------------------------------
gh_api_with_retry() {
    local path="$1"
    local out_file="$2"
    local retry_count="${3:-0}"
    local err rc=0

    err=$(gh api "$path" 2>&1 >"$out_file") || rc=$?

    if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
        echo "200"
        return 0
    fi

    case "$err" in
        *"HTTP 404"*|*'"status":"404"'*|*"Not Found"*)
            echo "404"
            return 0
            ;;
        *"HTTP 403"*|*"HTTP 429"*|*'"status":"403"'*|*'"status":"429"'*|*"rate limit"*|*"Rate limit"*)
            if [ "$retry_count" -lt 1 ]; then
                local retry_after
                retry_after=$(echo "$err" | sed -nE 's/.*[Rr]etry-[Aa]fter:[[:space:]]*([0-9]+).*/\1/p' | head -1)
                retry_after="${retry_after:-1}"
                echo "::warning::gh api $path got HTTP rate limit; retrying after ${retry_after}s" >&2
                sleep "$retry_after"
                gh_api_with_retry "$path" "$out_file" 1
                return $?
            fi
            echo "::error::gh api $path exhausted retries with rate limit" >&2
            return 1
            ;;
        *"HTTP 500"*|*"HTTP 502"*|*"HTTP 503"*|*"HTTP 504"*|\
        *'"status":"500"'*|*'"status":"502"'*|*'"status":"503"'*|*'"status":"504"'*|\
        *"Internal Server"*|*"Bad Gateway"*|*"Service Unavailable"*|*"Gateway Timeout"*)
            echo "::error::gh api $path returned 5xx: $err" >&2
            return 1
            ;;
        "")
            # rc != 0 but no stderr — treat as opaque success-ish
            echo "200"
            return 0
            ;;
        *)
            echo "::error::gh api $path returned unexpected error: $err" >&2
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# append_pr_files: fetch PR's file list and append to CROSS_BRANCH_FILE
# Conservative on 404 — emits warning, no append (files unrecoverable).
# -----------------------------------------------------------------------------
append_pr_files() {
    local pr_num="$1"
    local validate_only="${2:-0}"
    local tmp_files status rc=0
    tmp_files=$(mktemp /tmp/xb-files.XXXXXX)

    set +e
    status=$(gh_api_with_retry "repos/${GITHUB_REPOSITORY}/pulls/${pr_num}/files" "$tmp_files")
    rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp_files"
        return 1
    fi

    if [ "$status" = "404" ]; then
        echo "::warning::PR #${pr_num} files endpoint returned 404; cannot append filenames" >&2
        rm -f "$tmp_files"
        return 0
    fi

    if [ "$validate_only" = "1" ]; then
        rm -f "$tmp_files"
        return 0
    fi

    if [ -s "$tmp_files" ]; then
        jq -r '.[].filename' "$tmp_files" 2>/dev/null >> "$CROSS_BRANCH_FILE" || true
    fi
    rm -f "$tmp_files"
    return 0
}

# -----------------------------------------------------------------------------
# main: top-level for-loop (continue semantics depend on top-level context)
# -----------------------------------------------------------------------------
main() {
    # Defensive fetch of base ref
    git rev-parse --verify "origin/${BASE_REF}^{commit}" >/dev/null 2>&1 \
        || git fetch --no-tags origin "${BASE_REF}" 2>/dev/null \
        || git fetch --no-tags --unshallow 2>/dev/null \
        || true

    # Derive story refs from merge commit subjects (primary source of truth)
    local story_refs=()
    mapfile -t story_refs < <(
        git log "origin/${BASE_REF}..HEAD" --grep='^Merge pull request' --format=%s 2>/dev/null \
            | tr -d '\r' \
            | grep -oE 'story/[^/]+/[A-Za-z0-9_-]+' \
            | LC_ALL=C sort -u
    )

    if [ "${#story_refs[@]}" -eq 0 ]; then
        echo "::warning::no story merge commits found on session branch; ci-pr fallback inactive" >&2
        exit 0
    fi

    # Build story_refs_json for jq IN filter (filter PRs to those with a
    # matching local merge commit — prevents processing PRs whose story
    # was never merged into this session branch).
    local story_refs_json
    story_refs_json=$(printf '%s\n' "${story_refs[@]}" | jq -R . | jq -s .)

    # Enumerate candidate PRs via GitHub API
    local pr_list_tmp pr_status pr_list_rc=0
    pr_list_tmp=$(mktemp /tmp/xb-prlist.XXXXXX)

    set +e
    pr_status=$(gh_api_with_retry "repos/${GITHUB_REPOSITORY}/pulls?state=closed&base=${HEAD_REF}&per_page=100" "$pr_list_tmp")
    pr_list_rc=$?
    set -e

    if [ "$pr_list_rc" -ne 0 ]; then
        rm -f "$pr_list_tmp"
        exit 1
    fi

    if [ "$pr_status" = "404" ]; then
        echo "::warning::PR list endpoint returned 404; no candidate PRs to process" >&2
        rm -f "$pr_list_tmp"
        exit 0
    fi

    # Filter PRs: merged, base==HEAD_REF, head.ref matches story/<epic-in-set>/<id>
    local pr_records=""
    local skipped_unprovenanced=""
    if [ -s "$pr_list_tmp" ]; then
        pr_records=$(jq -c --argjson refs "$story_refs_json" --arg base "$HEAD_REF" '
            .[]
            | select(.merged_at != null)
            | select(.merge_commit_sha != null)
            | select(.base.ref == $base)
            | select(.head.ref | test("^story/[^/]+/[A-Za-z0-9_-]+$"))
            | select(.head.ref as $h | $refs | any(. == $h))
            | {number, head_ref: .head.ref, merge_commit_sha, base_ref: .base.ref}
        ' "$pr_list_tmp" 2>/dev/null || echo "")
        # PRs that pass shape/merged/base filters but lack a local merge commit
        # — emit a per-PR warning so unprovenanced PRs are visible in CI logs.
        skipped_unprovenanced=$(jq -r --argjson refs "$story_refs_json" --arg base "$HEAD_REF" '
            .[]
            | select(.merged_at != null)
            | select(.merge_commit_sha != null)
            | select(.base.ref == $base)
            | select(.head.ref | test("^story/[^/]+/[A-Za-z0-9_-]+$"))
            | select(.head.ref as $h | $refs | any(. == $h) | not)
            | "\(.number)\t\(.head.ref)\t\(.merge_commit_sha)"
        ' "$pr_list_tmp" 2>/dev/null || echo "")
        if [ -n "$skipped_unprovenanced" ]; then
            while IFS=$'\t' read -r _num _head _sha; do
                [ -z "$_num" ] && continue
                echo "::warning::PR #${_num} (${_head}, sha=${_sha}) has no matching local merge commit; treating as unprovenanced and skipping" >&2
            done <<< "$skipped_unprovenanced"
        fi
    fi
    rm -f "$pr_list_tmp"

    if [ -z "$pr_records" ]; then
        # No candidate PRs — dedup cbf and exit
        _dedup_cbf
        exit 0
    fi

    # Iterate per-PR (TOP-LEVEL for-loop — see contract constraint)
    local pr_records_arr=()
    mapfile -t pr_records_arr < <(echo "$pr_records")

    local record num merge_commit_sha
    for record in "${pr_records_arr[@]}"; do
        [ -z "$record" ] && continue
        num=$(echo "$record" | jq -r '.number')
        merge_commit_sha=$(echo "$record" | jq -r '.merge_commit_sha')

        # Defensive SHA shape validation — reject anything that isn't a full
        # 40-char lowercase hex SHA-1 before passing to git/gh commands.
        # Covers all downstream sinks: git fetch, git merge-base, gh api commits/{sha}.
        if ! [[ "$merge_commit_sha" =~ ^[0-9a-f]{40}$ ]]; then
            echo "::warning::PR #${num} merge_commit_sha=${merge_commit_sha} is not a valid SHA-1; skipping" >&2
            continue
        fi

        # Defensive fetch of merge_commit_sha (best-effort, don't gate)
        # `--` argv separator defends against any future SHA-shape change that
        # might allow leading-dash interpretation.
        if ! git fetch origin "$merge_commit_sha" --depth=1 -- >/dev/null 2>&1; then
            echo "::warning::PR #${num} merge_commit_sha=${merge_commit_sha} unreachable via fetch; proceeding with API check" >&2
            # Note: cannot do ancestor checks; skip those gates
        else
            # Skip if not ancestor of HEAD (rebase orphan)
            if ! git merge-base --is-ancestor "$merge_commit_sha" HEAD 2>/dev/null; then
                echo "::warning::PR #${num} merge_commit_sha not ancestor of session HEAD; skipping (likely rebase orphan)" >&2
                continue
            fi

            # Skip if ancestor of BASE_REF (already on main)
            if git merge-base --is-ancestor "$merge_commit_sha" "origin/${BASE_REF}" 2>/dev/null; then
                echo "::warning::PR #${num} merge_commit_sha already on origin/${BASE_REF}; skipping" >&2
                continue
            fi
        fi

        # Check review-sub-pr check-run conclusion
        local cr_tmp cr_status cr_rc=0 conclusion=""
        cr_tmp=$(mktemp /tmp/xb-checkruns.XXXXXX)
        set +e
        cr_status=$(gh_api_with_retry "repos/${GITHUB_REPOSITORY}/commits/${merge_commit_sha}/check-runs" "$cr_tmp")
        cr_rc=$?
        set -e

        if [ "$cr_rc" -ne 0 ]; then
            rm -f "$cr_tmp"
            exit 1
        fi

        if [ "$cr_status" = "404" ]; then
            echo "::warning::PR #${num} check-runs returned 404; re-including files in scope conservatively" >&2
            append_pr_files "$num" || { rm -f "$cr_tmp"; exit 1; }
            rm -f "$cr_tmp"
            continue
        fi

        if [ -s "$cr_tmp" ]; then
            conclusion=$(jq -r '.check_runs[]? | select(.name == "review-sub-pr") | .conclusion' "$cr_tmp" 2>/dev/null | head -1)
        fi
        rm -f "$cr_tmp"

        # ALWAYS call pulls/N/files to validate the endpoint is reachable —
        # propagates 5xx/exhausted-rate-limit errors immediately. The result
        # is only APPENDED to CROSS_BRANCH_FILE when the per-story review
        # was non-success (skipped/failure/missing); successful reviews skip
        # the append since those files were already reviewed at the per-story
        # PR level.
        local files_only_validate="0"
        if [ "$conclusion" = "success" ]; then
            files_only_validate="1"
            echo "::notice::PR #${num} review-sub-pr=success; validating files endpoint (no append)" >&2
        else
            echo "::warning::PR #${num} review-sub-pr=${conclusion:-missing}; re-including files in scope" >&2
        fi
        append_pr_files "$num" "$files_only_validate" || exit 1
    done

    _dedup_cbf
}

# -----------------------------------------------------------------------------
# _dedup_cbf: sort -u CROSS_BRANCH_FILE in place
# -----------------------------------------------------------------------------
_dedup_cbf() {
    if [ -s "$CROSS_BRANCH_FILE" ]; then
        local tmp
        tmp=$(mktemp /tmp/xb-dedup.XXXXXX)
        LC_ALL=C sort -u "$CROSS_BRANCH_FILE" > "$tmp"
        mv "$tmp" "$CROSS_BRANCH_FILE"
    fi
}

main "$@"
