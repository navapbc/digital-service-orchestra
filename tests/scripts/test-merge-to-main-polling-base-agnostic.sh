#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted patterns intentionally match literal $ in source
# tests/scripts/test-merge-to-main-polling-base-agnostic.sh
#
# Structural test for bug 8bae-cd51-6874-4737:
#   On --resume the polling-phase PR-number fallback must resolve the open PR
#   for the head BRANCH regardless of its base. The two-channel flow's PR1
#   targets a staged-* branch (NOT the default branch), so a fallback that pins
#   `gh pr list --base "${_DEFAULT_BRANCH:-main}"` returns empty and the script
#   exits 1 ("could not resolve PR number for polling phase"), stranding an
#   already-open, mergeable PR.
#
# Per behavioral testing standard Rule 5 (instruction/script files): the inline
# top-level polling fallback issues live `gh`/network calls and is not unit-
# executable, so we test the structural boundary — mirroring the sibling test
# tests/scripts/test-merge-to-main-resume-existing-pr-discovery.sh. The contract
# is: "the polling fallback queries gh base-agnostically (no --base default-branch
# pin) and selects a non-draft PR deterministically."
#
# Usage: bash tests/scripts/test-merge-to-main-polling-base-agnostic.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

if [[ ! -f "$MERGE_SCRIPT" ]]; then
    echo "SKIP: merge-to-main-pr.sh not found at $MERGE_SCRIPT"
    exit 0
fi

# ── Extract the polling PR-resolution region ──────────────────────────────────
# From the "Resolve PR url + number for resolve_threads + polling" marker comment
# down to (and including) the "could not resolve PR number for polling phase"
# guard. Assertions match content INSIDE this region only, so the base-agnostic
# resume-DISCOVERY block earlier in the script does not mask a regression here.
_POLLING_BLOCK=$(awk '
    /Resolve PR url \+ number for resolve_threads \+ polling/ { found=1 }
    found { print }
    /could not resolve PR number for polling phase/ { if (found) exit }
' "$MERGE_SCRIPT" 2>/dev/null)

echo "=== test-merge-to-main-polling-base-agnostic.sh ==="

# ============================================================
# test_polling_block_extracted
# Guard: the region markers must exist so the assertions below are meaningful.
# ============================================================
test_polling_block_extracted() {
    local found=0
    grep -qE 'gh pr list --head "\$BRANCH"' <<< "$_POLLING_BLOCK" 2>/dev/null && found=1 || true
    assert_eq "polling region contains the head-branch fallback query" "1" "$found"
}

# ============================================================
# test_polling_fallback_not_base_pinned (8bae)
# The polling fallback must NOT pin --base to the default branch — that is the
# defect: it cannot match a staged-* based PR1.
# ============================================================
test_polling_fallback_not_base_pinned() {
    local pinned=0
    grep -qE -- '--base "\$\{_DEFAULT_BRANCH:-main\}"' <<< "$_POLLING_BLOCK" 2>/dev/null && pinned=1 || true
    assert_eq "polling fallback does NOT pin --base to the default branch (8bae)" "0" "$pinned"
}

# ============================================================
# test_polling_fallback_is_base_agnostic (8bae)
# The fallback must query base-agnostically: `gh pr list --head "$BRANCH" --state
# open` with no --base flag at all.
# ============================================================
test_polling_fallback_is_base_agnostic() {
    local base_agnostic=0
    # A head+state query that is NOT immediately followed by a --base flag.
    grep -qE 'gh pr list --head "\$BRANCH" --state open' <<< "$_POLLING_BLOCK" 2>/dev/null \
        && ! grep -qE 'gh pr list --head "\$BRANCH"[^|]*--base' <<< "$_POLLING_BLOCK" 2>/dev/null \
        && base_agnostic=1 || true
    assert_eq "polling fallback queries gh base-agnostically (no --base flag) (8bae)" "1" "$base_agnostic"
}

# ============================================================
# test_polling_fallback_filters_drafts (8bae)
# Selection must be deterministic and exclude drafts (mirrors the resume-
# discovery block's non-draft selection at ~line 2936-2945).
# ============================================================
test_polling_fallback_filters_drafts() {
    local found=0
    grep -qE 'isDraft' <<< "$_POLLING_BLOCK" 2>/dev/null && found=1 || true
    assert_eq "polling fallback filters draft PRs for deterministic selection (8bae)" "1" "$found"
}

test_polling_block_extracted
test_polling_fallback_not_base_pinned
test_polling_fallback_is_base_agnostic
test_polling_fallback_filters_drafts

print_summary
