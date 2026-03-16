#!/usr/bin/env bash
# lockpick-workflow/hooks/pre-commit-review-gate.sh
# git pre-commit hook: default-deny allowlist check + review-status validation.
#
# DESIGN:
#   This hook runs at git pre-commit time, where staged files are natively
#   available via `git diff --cached --name-only`. This eliminates the fragile
#   command-string parsing required in the PreToolUse review-gate.sh hook.
#
# LOGIC:
#   1. Get list of staged files from `git diff --cached --name-only`
#   2. Load the shared allowlist from review-gate-allowlist.conf
#   3. If ALL staged files match the allowlist → exit 0 (no review needed)
#   4. If any staged file is non-allowlisted:
#        a. Resolve the artifacts directory (portable, no CLAUDE_PLUGIN_ROOT dep)
#        b. Check for a valid review-status file with status=passed
#        c. Verify the diff_hash in review-status matches current staged diff hash
#        d. If valid → exit 0
#        e. If invalid/missing → exit 1 with actionable error message
#
# INSTALL:
#   Registered in .pre-commit-config.yaml as a local hook (NOT via core.hooksPath,
#   which would conflict with the 12 existing hooks managed by pre-commit).
#
# COEXISTENCE:
#   The old PreToolUse review-gate.sh continues to run during the transition period
#   (until Story 1idf removes it). This hook and the old gate may both run on the
#   same commit — they are additive, not conflicting.
#
# ENVIRONMENT:
#   WORKFLOW_PLUGIN_ARTIFACTS_DIR — override for artifacts dir (used in tests)
#   CLAUDE_PLUGIN_ROOT            — optional; used to locate read-config.sh

set -uo pipefail

# ── Locate hook and plugin directories ──────────────────────────────────────
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared dependency library (provides get_artifacts_dir, hash_stdin, etc.)
source "$HOOK_DIR/lib/deps.sh"

# ── Helper: print actionable error message ───────────────────────────────────
# Called before each exit 1; names the non-allowlisted files and directs to /commit or /review.
_print_block_error() {
    local reason="$1"
    echo "" >&2
    echo "BLOCKED: git pre-commit review gate" >&2
    echo "" >&2
    echo "  Reason: ${reason}" >&2
    echo "" >&2
    echo "  Non-allowlisted files requiring review:" >&2
    for _f in "${NON_ALLOWLISTED_FILES[@]}"; do
        echo "    - ${_f}" >&2
    done
    echo "" >&2
    echo "  To unblock: run /commit or /review to perform a code review," >&2
    echo "  then retry your commit." >&2
    echo "" >&2
}

# ── Locate the shared allowlist ──────────────────────────────────────────────
ALLOWLIST_PATH="${CONF_OVERRIDE:-$HOOK_DIR/lib/review-gate-allowlist.conf}"

# ── Get staged files ─────────────────────────────────────────────────────────
# git diff --cached lists only staged (index-vs-HEAD) changes.
# In a merge commit (MERGE_HEAD present), this still returns only the files
# explicitly staged, which is the correct set to classify.
STAGED_FILES=()
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    STAGED_FILES+=("$f")
done < <(git diff --cached --name-only 2>/dev/null || true)

# No staged files → nothing to check; let git handle it
if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# ── Load allowlist patterns ──────────────────────────────────────────────────
# Uses _load_allowlist_patterns from deps.sh (same shared allowlist as
# compute-diff-hash.sh and skip-review-check.sh — single source of truth).
ALLOWLIST_PATTERNS=""
if [[ -f "$ALLOWLIST_PATH" ]]; then
    ALLOWLIST_PATTERNS=$(_load_allowlist_patterns "$ALLOWLIST_PATH" 2>/dev/null || true)
fi

# Build a grep regex from the allowlist for fast file matching
NON_REVIEWABLE_REGEX=""
if [[ -n "$ALLOWLIST_PATTERNS" ]]; then
    while IFS= read -r _regex_line; do
        [[ -z "$_regex_line" ]] && continue
        if [[ -z "$NON_REVIEWABLE_REGEX" ]]; then
            NON_REVIEWABLE_REGEX="$_regex_line"
        else
            NON_REVIEWABLE_REGEX="${NON_REVIEWABLE_REGEX}|${_regex_line}"
        fi
    done <<< "$(_allowlist_to_grep_regex "$ALLOWLIST_PATTERNS")"
fi

# ── Classify staged files ────────────────────────────────────────────────────
# A file is "allowlisted" (non-reviewable) if it matches the regex.
# All others require review.
NON_ALLOWLISTED_FILES=()
for staged_file in "${STAGED_FILES[@]}"; do
    is_allowlisted=0
    if [[ -n "$NON_REVIEWABLE_REGEX" ]]; then
        if echo "$staged_file" | grep -qE "$NON_REVIEWABLE_REGEX" 2>/dev/null; then
            is_allowlisted=1
        fi
    fi
    if [[ "$is_allowlisted" -eq 0 ]]; then
        NON_ALLOWLISTED_FILES+=("$staged_file")
    fi
done

# ── All staged files are allowlisted → allow without review ──────────────────
if [[ ${#NON_ALLOWLISTED_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# ── Non-allowlisted files present → check review-status ──────────────────────
# Resolve artifacts directory (portable: does not depend on CLAUDE_PLUGIN_ROOT
# or PreToolUse hook environment variables — works in any shell context).
ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE_FILE="$ARTIFACTS_DIR/review-status"

# ── Check review-status exists and is "passed" ───────────────────────────────
if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
    _print_block_error "No review recorded"
    exit 1
fi

REVIEW_STATUS_LINE=$(head -1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
if [[ "$REVIEW_STATUS_LINE" != "passed" ]]; then
    _print_block_error "Review status is '${REVIEW_STATUS_LINE}' (must be 'passed')"
    exit 1
fi

# ── Verify diff hash matches (review was for THIS code state) ─────────────────
RECORDED_HASH=$(grep '^diff_hash=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
if [[ -z "$RECORDED_HASH" ]]; then
    _print_block_error "Review status file has no diff_hash (corrupted or outdated)"
    exit 1
fi

# Compute the current diff hash using the shared compute-diff-hash.sh script.
# This produces the same hash as record-review.sh did when recording the review.
CURRENT_HASH=$(bash "$HOOK_DIR/compute-diff-hash.sh" 2>/dev/null || echo "")
if [[ -z "$CURRENT_HASH" ]]; then
    # Hash computation failed — fail open (allow) to avoid blocking on infrastructure issues
    exit 0
fi

if [[ "$RECORDED_HASH" != "$CURRENT_HASH" ]]; then
    _print_block_error "Diff hash mismatch — code changed since review was recorded (recorded=${RECORDED_HASH:0:12}..., current=${CURRENT_HASH:0:12}...)"
    exit 1
fi

# ── All checks passed → allow commit ─────────────────────────────────────────
exit 0
