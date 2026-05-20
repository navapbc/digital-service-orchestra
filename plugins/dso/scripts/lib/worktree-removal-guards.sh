#!/usr/bin/env bash
# worktree-removal-guards.sh
#
# Purpose:
#   Safety guards for worktree removal.  Callers source this library and
#   invoke individual guards or the orchestrator `assert_worktree_removable`
#   before removing a git worktree.
#
# Exported functions:
#   guard_protected_branch <branch>
#       Returns non-zero (fires) when <branch> is a protected branch:
#       main, master, develop, or release/*.
#       Prints:  GUARD: protected_branch <branch>  (stderr)
#
#   guard_uncommitted <worktree-path>
#       Returns non-zero (fires) when the worktree has uncommitted changes
#       (staged or unstaged).
#       Prints:  GUARD: uncommitted_state <worktree>  (stderr)
#
#   guard_unpushed <worktree-path>
#       Returns non-zero (fires) when the worktree has commits not yet pushed
#       to the upstream.  A missing upstream is treated as "unpushed".
#       Prints:  GUARD: unpushed_state <worktree>  (stderr)
#
#   guard_open_pr <branch> <sha>
#       Returns non-zero (fires) when one or more open PRs are found for
#       <branch> or <sha> via a 3-tier fallback:
#         Tier-A (first, promoted per S1.T1 spike):
#             gh pr list --search "head:<branch>" --state open
#         Tier-B:
#             gh pr list --head "<branch>" --state open
#         Tier-C:
#             gh api repos/{owner}/{repo}/commits/<sha>/pulls
#       Also queries --base <branch> for sub-PR enumeration (story branches
#       targeting the session branch as base).  Results are unioned and
#       deduplicated by PR number.
#       Prints:  GUARD: open_pr_with_ci <branch> PRs: <url1>, <url2>, ...  (stderr)
#
#       Fail-CLOSED contract:
#         If `command -v gh` fails, `gh auth status` fails, or any gh call
#         returns a rate-limit error, the function exits non-zero and prints:
#             GUARD_PR_CHECK_UNAVAILABLE: <cause>
#         Override (both variables required; mirrors DSO_SPRINT_ACTIVE_BYPASS_REASON
#         pattern):
#             WORKTREE_REMOVAL_SKIP_PR_CHECK=1
#             WORKTREE_REMOVAL_SKIP_PR_CHECK_REASON=<non-empty justification>
#
#   assert_worktree_removable --worktree-path <path> --branch <branch> [--force]
#       Orchestrator.  Runs ALL guards (no short-circuit) and collects every
#       firing guard message.
#       Without --force: exits non-zero; prints all firing guard messages.
#       With --force:    exits 0;         prints all firing guard messages.
#       Exception: guard_protected_branch is NEVER bypassed by --force.
#       The <branch> is checked against the protected list regardless of --force.
#
# Source guard:
#   Set _GUARDS_SOURCE_ONLY=1 before sourcing to suppress any top-level
#   execution (library-safe mode).
#
# This file is NOT executable standalone — source it into other scripts.

# ── Source guard ──────────────────────────────────────────────────────────────
# Prevent re-sourcing in the same shell session.
if [[ -n "${_WORKTREE_REMOVAL_GUARDS_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
_WORKTREE_REMOVAL_GUARDS_LOADED=1

# ── guard_protected_branch ───────────────────────────────────────────────────
# Usage: guard_protected_branch <branch>
# Returns: non-zero (fires) if <branch> is protected; 0 (clear) otherwise.
guard_protected_branch() {
    local branch="${1:?guard_protected_branch: branch required}"

    local _is_protected=0
    case "$branch" in
        main|master|develop|release/*)
            _is_protected=1
            ;;
    esac

    if [[ "$_is_protected" -eq 1 ]]; then
        echo "GUARD: protected_branch ${branch}" >&2
        return 1
    fi
    return 0
}

# ── guard_uncommitted ────────────────────────────────────────────────────────
# Usage: guard_uncommitted <worktree-path>
# Returns: non-zero (fires) if the worktree has uncommitted changes; 0 otherwise.
guard_uncommitted() {
    local wt="${1:?guard_uncommitted: worktree-path required}"

    # Reject paths starting with '-' to prevent flag-confusion unless prefixed by ./
    if [[ "$wt" == -* ]]; then
        echo "ERROR: guard_uncommitted: worktree path must not start with '-'; use './${wt}'" >&2
        return 2
    fi

    local _status
    _status=$(git -C "$wt" status --porcelain -- 2>/dev/null)
    if [[ -n "$_status" ]]; then
        echo "GUARD: uncommitted_state ${wt}" >&2
        return 1
    fi
    return 0
}

# ── guard_unpushed ────────────────────────────────────────────────────────────
# Usage: guard_unpushed <worktree-path>
# Returns: non-zero (fires) if the worktree has commits not pushed; 0 otherwise.
# A missing upstream is treated as "unpushed" (conservative/safe default).
guard_unpushed() {
    local wt="${1:?guard_unpushed: worktree-path required}"

    # Reject paths starting with '-'
    if [[ "$wt" == -* ]]; then
        echo "ERROR: guard_unpushed: worktree path must not start with '-'; use './${wt}'" >&2
        return 2
    fi

    # Check for upstream; if none, treat as unpushed
    local _upstream_check
    _upstream_check=$(git -C "$wt" rev-parse --abbrev-ref '@{u}' 2>&1)
    local _rc=$?
    if [[ $_rc -ne 0 ]]; then
        # No upstream configured → treat as unpushed
        echo "GUARD: unpushed_state ${wt}" >&2
        return 1
    fi

    local _unpushed
    _unpushed=$(git -C "$wt" log '@{u}..HEAD' --oneline -- 2>/dev/null)
    if [[ -n "$_unpushed" ]]; then
        echo "GUARD: unpushed_state ${wt}" >&2
        return 1
    fi
    return 0
}

# ── _parse_pr_list_tsv ────────────────────────────────────────────────────────
# Internal helper: parse TSV output from `gh pr list` and extract PR numbers and URLs.
# Input: raw TSV string (number<tab>title<tab>url<tab>state or similar)
# Output: writes "number url" lines to stdout (one per PR)
_parse_pr_list_tsv() {
    local _tsv="$1"
    local _line _num _url
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        # TSV columns: number title url state (from gh pr list default output)
        _num=$(printf '%s' "$_line" | cut -f1)
        _url=$(printf '%s' "$_line" | cut -f3)
        if [[ -n "$_num" && -n "$_url" ]]; then
            printf '%s %s\n' "$_num" "$_url"
        fi
    done <<< "$_tsv"
}

# ── _parse_pr_json_array ──────────────────────────────────────────────────────
# Internal helper: parse JSON array from gh api commits/<sha>/pulls.
# Input: JSON array string, each element has .number and .html_url
# Output: writes "number url" lines to stdout (one per PR)
_parse_pr_json_array() {
    local _json="$1"
    # Use jq if available, else basic grep/sed extraction
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$_json" | jq -r '.[] | "\(.number) \(.html_url)"' 2>/dev/null || true
    else
        # Fallback: extract number and html_url with basic tools
        local _num _url
        _num=$(printf '%s' "$_json" | grep -o '"number":[0-9]*' | grep -o '[0-9]*')
        _url=$(printf '%s' "$_json" | grep -o '"html_url":"[^"]*"' | sed 's/"html_url":"//;s/"//')
        if [[ -n "$_num" && -n "$_url" ]]; then
            printf '%s %s\n' "$_num" "$_url"
        fi
    fi
}

# ── guard_open_pr ─────────────────────────────────────────────────────────────
# Usage: guard_open_pr <branch> <sha>
# Returns: non-zero (fires) if any open PRs found; 0 (clear) otherwise.
# Fail-CLOSED: exits non-zero if gh is unavailable or rate-limited.
# Override: set WORKTREE_REMOVAL_SKIP_PR_CHECK=1 AND
#           WORKTREE_REMOVAL_SKIP_PR_CHECK_REASON=<non-empty> to bypass.
guard_open_pr() {
    local branch="${1:?guard_open_pr: branch required}"
    local sha="${2:?guard_open_pr: sha required}"

    # ── Override check (both vars required) ───────────────────────────────────
    if [[ "${WORKTREE_REMOVAL_SKIP_PR_CHECK:-0}" == "1" ]]; then
        if [[ -n "${WORKTREE_REMOVAL_SKIP_PR_CHECK_REASON:-}" ]]; then
            # Both vars set — allow bypass
            return 0
        fi
        # Only one var set — insufficient; continue to fail-closed behaviour
    fi

    # ── gh availability check ─────────────────────────────────────────────────
    if ! command -v gh >/dev/null 2>&1; then
        echo "GUARD_PR_CHECK_UNAVAILABLE: gh not installed or not in PATH" >&2
        return 1
    fi

    local _auth_err
    _auth_err=$(gh auth status 2>&1)
    local _auth_rc=$?
    if [[ $_auth_rc -ne 0 ]]; then
        echo "GUARD_PR_CHECK_UNAVAILABLE: gh auth status failed: ${_auth_err}" >&2
        return 1
    fi

    # ── PR accumulation: use a temp file to collect "number url" pairs ────────
    # We avoid nested functions (no closure support in bash) by writing results
    # to a temp file, then reading it back into the dedup map.
    local _pr_tmp
    _pr_tmp=$(mktemp /tmp/guard_open_pr.XXXXXX)

    # ── Tier-A (promoted per S1.T1 spike): search "head:<branch>" ─────────────
    local _tier_a_out _tier_a_rc
    _tier_a_out=$(gh pr list --search "head:${branch}" --state open 2>&1)
    _tier_a_rc=$?
    if [[ $_tier_a_rc -ne 0 ]]; then
        if printf '%s' "$_tier_a_out" | grep -qi 'rate limit'; then
            echo "GUARD_PR_CHECK_UNAVAILABLE: gh rate limit exceeded (tier-A search)" >&2
            rm -f "$_pr_tmp"
            return 1
        fi
        # Non-fatal tier failure; continue to next tier
    else
        _parse_pr_list_tsv "$_tier_a_out" >> "$_pr_tmp"
    fi

    # ── Sub-PR enumeration: --base <branch> (additive, runs independently) ────
    local _base_out _base_rc
    _base_out=$(gh pr list --base "${branch}" --state open 2>&1)
    _base_rc=$?
    if [[ $_base_rc -eq 0 ]]; then
        _parse_pr_list_tsv "$_base_out" >> "$_pr_tmp"
    elif printf '%s' "$_base_out" | grep -qi 'rate limit'; then
        echo "GUARD_PR_CHECK_UNAVAILABLE: gh rate limit exceeded (base enumeration)" >&2
        rm -f "$_pr_tmp"
        return 1
    fi

    # ── Tier-B: --head <branch> ───────────────────────────────────────────────
    local _tier_b_out _tier_b_rc
    _tier_b_out=$(gh pr list --head "${branch}" --state open 2>&1)
    _tier_b_rc=$?
    if [[ $_tier_b_rc -eq 0 ]]; then
        _parse_pr_list_tsv "$_tier_b_out" >> "$_pr_tmp"
    elif printf '%s' "$_tier_b_out" | grep -qi 'rate limit'; then
        echo "GUARD_PR_CHECK_UNAVAILABLE: gh rate limit exceeded (tier-B head)" >&2
        rm -f "$_pr_tmp"
        return 1
    fi

    # ── Tier-C: commits/<sha>/pulls ───────────────────────────────────────────
    local _tier_c_out _tier_c_rc
    _tier_c_out=$(gh api "repos/{owner}/{repo}/commits/${sha}/pulls" \
        --jq '[.[]|select(.state=="open")]' 2>&1)
    _tier_c_rc=$?
    if [[ $_tier_c_rc -eq 0 ]]; then
        _parse_pr_json_array "$_tier_c_out" >> "$_pr_tmp"
    elif printf '%s' "$_tier_c_out" | grep -qi 'rate limit'; then
        echo "GUARD_PR_CHECK_UNAVAILABLE: gh rate limit exceeded (tier-C commits)" >&2
        rm -f "$_pr_tmp"
        return 1
    fi

    # ── Deduplicate by PR number and collect URLs ──────────────────────────────
    # Sort by PR number and deduplicate; then extract unique URLs.
    # We sort on the number field (column 1) and keep only the first occurrence
    # (stable sort preserves first-seen URL for each number).
    local _dedup_file
    _dedup_file=$(mktemp /tmp/guard_open_pr_dedup.XXXXXX)
    sort -k1,1 -u "$_pr_tmp" > "$_dedup_file" 2>/dev/null || true
    rm -f "$_pr_tmp"

    # ── Evaluate accumulated PRs ──────────────────────────────────────────────
    # Check if the dedup file has any content
    local _has_prs=0
    local _url_list=""
    local _dn _du
    while IFS=' ' read -r _dn _du; do
        [[ -z "$_dn" ]] && continue
        _has_prs=1
        if [[ -z "$_url_list" ]]; then
            _url_list="$_du"
        else
            _url_list="${_url_list}, ${_du}"
        fi
    done < "$_dedup_file"
    rm -f "$_dedup_file"

    if [[ $_has_prs -eq 1 ]]; then
        echo "GUARD: open_pr_with_ci ${branch} PRs: ${_url_list}" >&2
        return 1
    fi

    return 0
}

# ── assert_worktree_removable ─────────────────────────────────────────────────
# Usage: assert_worktree_removable --worktree-path <path> --branch <branch> [--force]
# Orchestrator: runs ALL guards (no short-circuit).
# Without --force: exits 1 if any guard fires (refusal).
# With --force:    exits 0 even if guards fire (bypass; messages still printed).
# Exception: guard_protected_branch is NEVER bypassed by --force.
assert_worktree_removable() {
    local _wt=""
    local _branch=""
    local _force=0

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --worktree-path)
                _wt="${2:?--worktree-path requires a value}"
                shift 2
                ;;
            --branch)
                _branch="${2:?--branch requires a value}"
                shift 2
                ;;
            --force)
                _force=1
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "ERROR: assert_worktree_removable: unknown argument: $1" >&2
                return 2
                ;;
        esac
    done

    if [[ -z "$_wt" ]]; then
        echo "ERROR: assert_worktree_removable: --worktree-path is required" >&2
        return 2
    fi
    if [[ -z "$_branch" ]]; then
        echo "ERROR: assert_worktree_removable: --branch is required" >&2
        return 2
    fi

    # Reject paths starting with '-' unless prefixed by './'
    if [[ "$_wt" == -* ]]; then
        echo "ERROR: assert_worktree_removable: worktree path must not start with '-'; use './${_wt}'" >&2
        return 2
    fi

    local _any_fired=0
    local _protected_fired=0

    # ── Guard 1: protected branch (never bypassable) ──────────────────────────
    # Guards print their own GUARD: messages to stderr; just collect exit code.
    guard_protected_branch "$_branch" || {
        _any_fired=1
        _protected_fired=1
    }

    # ── Guard 2: uncommitted changes ──────────────────────────────────────────
    guard_uncommitted "$_wt" || {
        _any_fired=1
    }

    # ── Guard 3: unpushed commits ─────────────────────────────────────────────
    guard_unpushed "$_wt" || {
        _any_fired=1
    }

    # ── Guard 4: open PR ──────────────────────────────────────────────────────
    guard_open_pr "$_branch" "$_branch" || {
        _any_fired=1
    }

    # ── Evaluate result ───────────────────────────────────────────────────────
    if [[ $_any_fired -eq 0 ]]; then
        # All clear
        return 0
    fi

    # At least one guard fired
    if [[ $_force -eq 1 && $_protected_fired -eq 0 ]]; then
        # --force bypass allowed (no protected-branch violation)
        return 0
    fi

    # Refusal: exit 1
    return 1
}

# ── Library-mode guard ────────────────────────────────────────────────────────
# When sourced with _GUARDS_SOURCE_ONLY=1, suppress top-level execution.
if [[ "${_GUARDS_SOURCE_ONLY:-0}" == "1" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
