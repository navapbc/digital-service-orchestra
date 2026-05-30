#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted patterns intentionally match literal $ in source
# tests/scripts/test-merge-to-main-resume-existing-pr-discovery.sh
#
# Structural test for bug 5ff0-5e4b-84b3-4396:
#   --resume must discover an existing open non-draft PR1 from GitHub when
#   the state file's pr_url is empty (e.g., after _state_init overwrote it
#   on a stale or absent state file). Without this fallback, --resume falls
#   through to _phase_staged_intermediate and creates a duplicate staged-*
#   ref + duplicate PR1 (observed: PRs #490/#492 with same source branch,
#   different staged bases).
#
# Per behavioral testing standard Rule 5 (instruction/script files): test
# the structural boundary, not runtime behavior. The structural contract
# is "the --resume path queries gh for an existing open non-draft PR when
# the in-memory pr_url is empty."
#
# Usage: bash tests/scripts/test-merge-to-main-resume-existing-pr-discovery.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

if [[ ! -f "$MERGE_SCRIPT" ]]; then
    echo "SKIP: merge-to-main-pr.sh not found at $MERGE_SCRIPT"
    exit 0
fi

# ── Extract the --resume detection block ──────────────────────────────────────
# The block we care about starts at:
#   if [[ "${_RESUME:-0}" -eq 1 ]] && type _state_file_path
# and ends at the closing 'fi' for that block. We need to extract it so that
# assertions match content INSIDE the block, not later sections of the script.
_RESUME_DETECT_BLOCK=$(awk '
    /if \[\[ "\$\{_RESUME:-0\}" -eq 1 \]\] && type _state_file_path/ { found=1; depth=1; print; next }
    found {
        print
        if (/^[[:space:]]*if /) depth++
        if (/^[[:space:]]*fi[[:space:]]*$/ || /^[[:space:]]*fi[[:space:]]/) {
            depth--
            if (depth == 0) { found=0 }
        }
    }
' "$MERGE_SCRIPT" 2>/dev/null)

# ============================================================
# test_resume_queries_gh_for_existing_pr (5ff0)
#
# The --resume detection block must call `gh pr list --head "$BRANCH"`
# to discover an existing open PR when the state file does not record one.
# Without this, --resume falls through to _phase_staged_intermediate.
# ============================================================
test_resume_queries_gh_for_existing_pr() {
    local found=0
    grep -qE 'gh pr list --head "\$BRANCH" --state open' <<< "$_RESUME_DETECT_BLOCK" 2>/dev/null && found=1 || true
    assert_eq "resume block queries gh for existing open PR on BRANCH (5ff0)" "1" "$found"
}

# ============================================================
# test_resume_filters_drafts_in_gh_query (5ff0)
#
# The gh query must include isDraft handling — drafts are not "existing
# non-draft PR1" and must not be matched as resumable.
# ============================================================
test_resume_filters_drafts_in_gh_query() {
    local found=0
    grep -qE 'isDraft' <<< "$_RESUME_DETECT_BLOCK" 2>/dev/null && found=1 || true
    assert_eq "resume block filters draft PRs out of existing-PR discovery (5ff0)" "1" "$found"
}

# ============================================================
# test_resume_populates_state_pr_url_from_gh (5ff0)
#
# When the gh query finds an open non-draft PR, the URL must be assigned
# to _RESUME_STATE_PR_URL so the downstream guards (line ~2826 and ~2841)
# skip _check_duplicate_pr and _phase_merge.
# ============================================================
test_resume_populates_state_pr_url_from_gh() {
    # Look for _RESUME_STATE_PR_URL= assignment INSIDE the block that also
    # contains the gh pr list call.
    local has_gh_query=0
    local has_assignment=0
    grep -qE 'gh pr list --head "\$BRANCH"' <<< "$_RESUME_DETECT_BLOCK" 2>/dev/null && has_gh_query=1 || true
    # Require the assignment to use the gh output (look for the substitution
    # form: _RESUME_STATE_PR_URL=$(... gh pr list ...) OR pipe to python that
    # prints the URL).
    grep -qE '_RESUME_STATE_PR_URL=\$\(.*gh pr list' <<< "$_RESUME_DETECT_BLOCK" 2>/dev/null && has_assignment=1 || true
    assert_eq "resume block populates _RESUME_STATE_PR_URL from gh discovery (5ff0)" "11" "${has_gh_query}${has_assignment}"
}

# ============================================================
# Run tests
# ============================================================
echo "=== test-merge-to-main-resume-existing-pr-discovery.sh ==="

test_resume_queries_gh_for_existing_pr
test_resume_filters_drafts_in_gh_query
test_resume_populates_state_pr_url_from_gh

print_summary
