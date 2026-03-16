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

# ── Telemetry state (updated as the hook progresses) ─────────────────────────
# These flags track what the hook discovered so log_decision records accurate
# metadata regardless of which exit path is taken.
_TELEMETRY_REVIEW_STATUS_PRESENT=false
_TELEMETRY_HASH_MATCH=false

# ── Helper: append a JSONL telemetry entry to the gate log ───────────────────
# Usage: log_decision <outcome>  where outcome is "pass" or "block"
# Appends one compact JSON line to $ARTIFACTS_DIR/review-gate-telemetry.jsonl.
# Uses >> (append, no locking) — short line writes are atomic on POSIX filesystems.
# All failures are silently suppressed so telemetry never slows or blocks commits.
log_decision() {
    local _outcome="$1"
    local _log_dir="${ARTIFACTS_DIR:-$(get_artifacts_dir 2>/dev/null || echo "")}"
    [[ -z "$_log_dir" ]] && return 0
    local _log_file="$_log_dir/review-gate-telemetry.jsonl"
    local _ts
    _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

    # Build staged_files JSON array; use python3 for reliable string escaping
    local _files_json="["
    local _first_file=1
    local _sf
    for _sf in "${STAGED_FILES[@]+"${STAGED_FILES[@]}"}"; do
        local _esc
        _esc=$(printf '%s' "$_sf" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()),end='')" 2>/dev/null || printf '"%s"' "$_sf")
        if (( _first_file )); then
            _files_json="${_files_json}${_esc}"
            _first_file=0
        else
            _files_json="${_files_json},${_esc}"
        fi
    done
    _files_json="${_files_json}]"

    printf '{"timestamp":"%s","outcome":"%s","staged_files":%s,"review_status_present":%s,"hash_match":%s}\n' \
        "$_ts" \
        "$_outcome" \
        "$_files_json" \
        "$_TELEMETRY_REVIEW_STATUS_PRESENT" \
        "$_TELEMETRY_HASH_MATCH" \
        >> "$_log_file" 2>/dev/null || true
}

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

# ── Helper: detect formatting-only drift between review and current staged state ─
# Returns 0 (true) if the ONLY differences between reviewed state and current
# staged state are ruff-style formatting changes for .py files.
# Returns 1 (false) if any non-formatting code change is detected.
#
# Algorithm: for each staged non-allowlisted .py file:
#   1. Get the staged content (git show :file — index content after ruff ran)
#   2. Get the base/HEAD content (git show HEAD:file — pre-format state)
#   3. Run ruff format on the base content to get what ruff would produce
#   4. If staged == ruff(base): file changed only due to formatting ✓
#   5. Otherwise: real code change detected → return 1 (not formatting-only)
#
# Non-.py files: if a non-allowlisted non-.py file changed, return 1 immediately
# since we can't detect formatting-only changes for those.
#
# Requires ruff in PATH. If ruff is unavailable, returns 1 (fail-safe: don't
# self-heal when we cannot verify).
_is_formatting_only_drift() {
    # Require ruff — without it we cannot verify formatting-only drift
    local _ruff_bin
    _ruff_bin=$(command -v ruff 2>/dev/null || echo "")
    if [[ -z "$_ruff_bin" ]]; then
        return 1
    fi

    # Iterate over non-allowlisted staged files
    # NON_ALLOWLISTED_FILES is set in the outer scope before this function is called
    for _staged_file in "${NON_ALLOWLISTED_FILES[@]}"; do
        # Only handle .py files — other file types block immediately
        if [[ "$_staged_file" != *.py ]]; then
            return 1
        fi

        # Get staged content (index — what will be committed)
        local _staged_content
        _staged_content=$(git show ":${_staged_file}" 2>/dev/null) || {
            # File not in index (deleted or unreadable) — cannot verify
            return 1
        }

        # Get base content (HEAD version — what existed before ruff ran)
        local _base_content
        _base_content=$(git show "HEAD:${_staged_file}" 2>/dev/null) || {
            # File is new (no HEAD version) — cannot verify formatting-only for new files
            return 1
        }

        # Apply ruff format to the base content to get what ruff would produce
        local _ruff_formatted
        _ruff_formatted=$(echo "$_base_content" | "$_ruff_bin" format - 2>/dev/null) || {
            # ruff failed — cannot verify
            return 1
        }

        # Compare ruff-formatted base to staged content
        if [[ "$_staged_content" != "$_ruff_formatted" ]]; then
            # Content differs beyond formatting — real code change
            return 1
        fi
    done

    # All non-allowlisted files are formatting-only changes
    return 0
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
    log_decision "pass"
    exit 0
fi

# ── Non-allowlisted files present → check review-status ──────────────────────
# Resolve artifacts directory (portable: does not depend on CLAUDE_PLUGIN_ROOT
# or PreToolUse hook environment variables — works in any shell context).
ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE_FILE="$ARTIFACTS_DIR/review-status"

# ── Check review-status exists and is "passed" ───────────────────────────────
if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
    log_decision "block"
    _print_block_error "No review recorded"
    exit 1
fi

# Review-status file is present — update telemetry flag
_TELEMETRY_REVIEW_STATUS_PRESENT=true

REVIEW_STATUS_LINE=$(head -1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
if [[ "$REVIEW_STATUS_LINE" != "passed" ]]; then
    log_decision "block"
    _print_block_error "Review status is '${REVIEW_STATUS_LINE}' (must be 'passed')"
    exit 1
fi

# ── Verify diff hash matches (review was for THIS code state) ─────────────────
RECORDED_HASH=$(grep '^diff_hash=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
if [[ -z "$RECORDED_HASH" ]]; then
    log_decision "block"
    _print_block_error "Review status file has no diff_hash (corrupted or outdated)"
    exit 1
fi

# Compute the current diff hash using the shared compute-diff-hash.sh script.
# This produces the same hash as record-review.sh did when recording the review.
CURRENT_HASH=$(bash "$HOOK_DIR/compute-diff-hash.sh" 2>/dev/null || echo "")
if [[ -z "$CURRENT_HASH" ]]; then
    # Hash computation failed — fail open (allow) to avoid blocking on infrastructure issues
    log_decision "pass"
    exit 0
fi

if [[ "$RECORDED_HASH" != "$CURRENT_HASH" ]]; then
    # ── Self-heal: check if drift is formatting-only (ruff auto-format) ──────
    # When ruff runs as a pre-commit hook before this gate, it may reformat
    # staged .py files, invalidating the diff hash from review time. If the
    # ONLY changes since review are ruff-style formatting (whitespace, style),
    # we re-compute the hash and update review-status to allow the commit.
    #
    # Algorithm: for each staged non-allowlisted .py file, compare the staged
    # content to what ruff format would produce from the HEAD/base version of
    # that file. If staged == ruff(base), it is a formatting-only change.
    # If ALL non-allowlisted files are formatting-only, drift is self-healed.
    if _is_formatting_only_drift; then
        # Re-compute hash for current staged state and update review-status
        _REHASH=$(bash "$HOOK_DIR/compute-diff-hash.sh" 2>/dev/null || echo "")
        if [[ -n "$_REHASH" ]]; then
            # Update diff_hash line in review-status (preserve all other fields)
            _TMP_STATUS=$(mktemp)
            grep -v '^diff_hash=' "$REVIEW_STATE_FILE" > "$_TMP_STATUS" 2>/dev/null || true
            echo "diff_hash=${_REHASH}" >> "$_TMP_STATUS"
            mv "$_TMP_STATUS" "$REVIEW_STATE_FILE"
            echo "pre-commit-review-gate: formatting-only drift self-healed (rehash=${_REHASH:0:12}...)" >&2
            log_decision "pass"
            exit 0
        fi
    fi
    log_decision "block"
    _print_block_error "Diff hash mismatch — code changed since review was recorded (recorded=${RECORDED_HASH:0:12}..., current=${CURRENT_HASH:0:12}...)"
    exit 1
fi

# ── Hash matched — update telemetry flag, then allow commit ──────────────────
_TELEMETRY_HASH_MATCH=true
log_decision "pass"
exit 0
