#!/usr/bin/env bash
# hook-boundary: enforcement
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# shellcheck disable=SC2295  # Pre-existing: inner $(…) in pattern expansion — safe here
_PLUGIN_GIT_PATH="${_PLUGIN_ROOT#$(cd "$_PLUGIN_ROOT" && git rev-parse --show-toplevel)/}"
# hooks/pre-commit-review-gate.sh
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

# Source shared merge/rebase state library (provides ms_filter_to_worktree_only, etc.)
source "$HOOK_DIR/lib/merge-state.sh"

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

    # Build staged_files JSON array; single python3 call for all files
    # (avoids per-file subprocess spawning which is O(N) forks)
    local _files_json
    _files_json=$(printf '%s\n' "${STAGED_FILES[@]+"${STAGED_FILES[@]}"}" | \
        python3 -c "import json,sys; print(json.dumps([f for f in sys.stdin.read().splitlines() if f]),end='')" \
        2>/dev/null || echo "[]")

    printf '{"timestamp":"%s","outcome":"%s","staged_files":%s,"review_status_present":%s,"hash_match":%s}\n' \
        "$_ts" \
        "$_outcome" \
        "$_files_json" \
        "$_TELEMETRY_REVIEW_STATUS_PRESENT" \
        "$_TELEMETRY_HASH_MATCH" \
        >> "$_log_file" 2>/dev/null || true
}

# ── Helper: print actionable error message ───────────────────────────────────
# Called before each exit 1; names the non-allowlisted files and directs to /dso:commit or /dso:review.
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
    echo "  To unblock: run /dso:commit or /dso:review to perform a code review," >&2
    echo "  then retry your commit." >&2
    echo "" >&2
}

# ── Helper: detect shellcheck-directive-only drift between review and staged state ─
# Returns 0 (true) if the ONLY differences between HEAD and current staged state
# are added/removed shellcheck directive comment lines (# shellcheck ...) in .sh files.
# Returns 1 (false) if any non-directive change is detected, or if any non-.sh file
# is in the non-allowlisted set.
#
# Algorithm: for each staged non-allowlisted .sh file:
#   1. Get the staged content (git show :file — index content)
#   2. Get the HEAD content (git show HEAD:file — committed version)
#   3. Strip all shellcheck directive lines from both versions
#   4. If stripped staged == stripped HEAD: file only changed in directives ✓
#   5. Otherwise: real code change detected → return 1
#
# Non-.sh files: immediately return 1 since this self-heal only applies to shell scripts.
_is_shellcheck_disable_only_drift() {
    for _sh_staged_file in "${NON_ALLOWLISTED_FILES[@]}"; do
        if [[ "$_sh_staged_file" != *.sh ]]; then
            return 1
        fi
        local _sh_staged_content
        _sh_staged_content=$(git show ":${_sh_staged_file}" 2>/dev/null) || { return 1; }
        local _sh_base_content
        _sh_base_content=$(git show "HEAD:${_sh_staged_file}" 2>/dev/null) || { return 1; }
        local _sh_staged_stripped _sh_base_stripped
        _sh_staged_stripped=$(echo "$_sh_staged_content" | grep -v '^\s*#\s*shellcheck\s' 2>/dev/null || echo "$_sh_staged_content")
        _sh_base_stripped=$(echo "$_sh_base_content" | grep -v '^\s*#\s*shellcheck\s' 2>/dev/null || echo "$_sh_base_content")
        if [[ "$_sh_staged_stripped" != "$_sh_base_stripped" ]]; then
            return 1
        fi
    done
    return 0
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
STAGED_FILES=()
_staged_output=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -n "$_staged_output" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        STAGED_FILES+=("$f")
    done <<< "$_staged_output"
fi

# No staged files → nothing to check; let git handle it
if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# ── Mechanical amend bypass (merge-to-main.sh version_bump / validate) ────────
# DSO_MECHANICAL_AMEND=1 is set by merge-to-main.sh before git commit --amend
# for mechanical operations (version bump, post-merge validation fold-in).
# These are single-field or auto-fix changes that don't require code review.
# Layer 2 (review-gate-bypass-sentinel.sh) blocks misuse on non-amend commits.
if [[ "${DSO_MECHANICAL_AMEND:-}" == "1" ]]; then
    exit 0
fi

# ── Merge/rebase commit: filter out incoming-only files ───────────────────────
# When MERGE_HEAD exists (e.g., `git merge --no-commit origin/main`) or
# REBASE_HEAD exists (mid-rebase state), staged files may include changes from
# the incoming/onto branch that were already reviewed on main. These
# incoming-only files should not require re-review.
#
# Delegates to ms_get_worktree_only_files (merge-state.sh) which handles:
#   - MERGE_HEAD: files changed on worktree branch (merge-base..HEAD)
#   - REBASE_HEAD: files changed on worktree branch (merge-base..orig-head)
#   - Fail-open: returns staged files on merge-base computation failure
#
# Preserves early-exit when all files are incoming-only.
if ms_is_merge_in_progress || ms_is_rebase_in_progress; then
    _worktree_files=$(ms_get_worktree_only_files 2>/dev/null || true)

    # Check if merge-base was computed successfully (non-fail-open).
    _merge_base_check=$(ms_get_merge_base 2>/dev/null || echo "")

    # If merge-base was computed and worktree has no changed files, all staged
    # files are incoming-only → nothing to review, allow commit.
    if [[ -n "$_merge_base_check" ]] && [[ -z "$_worktree_files" ]]; then
        log_decision "pass"
        exit 0
    fi

    # If ms_get_worktree_only_files returned non-empty output, filter staged files.
    # If it returned empty AND merge-base failed (fail-open), fall through with full list.
    if [[ -n "$_worktree_files" ]]; then
        _filtered_staged=()
        for _msf in "${STAGED_FILES[@]+"${STAGED_FILES[@]}"}"; do
            if echo "$_worktree_files" | grep -qxF "$_msf" 2>/dev/null; then
                _filtered_staged+=("$_msf")
            fi
        done

        # Replace STAGED_FILES with filtered list
        STAGED_FILES=("${_filtered_staged[@]+"${_filtered_staged[@]}"}")

        # If all staged files were incoming-only, nothing to check
        if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
            log_decision "pass"
            exit 0
        fi
    fi
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
# Uses a single grep invocation instead of per-file subprocess spawning
# for O(1) process forks regardless of staged file count.
NON_ALLOWLISTED_FILES=()
if [[ -z "$NON_REVIEWABLE_REGEX" ]]; then
    # No allowlist loaded — everything requires review (fail-safe)
    NON_ALLOWLISTED_FILES=("${STAGED_FILES[@]}")
else
    _non_allowlisted=$(printf '%s\n' "${STAGED_FILES[@]}" | grep -vE "$NON_REVIEWABLE_REGEX" 2>/dev/null || true)
    if [[ -n "$_non_allowlisted" ]]; then
        while IFS= read -r _classified_file; do
            [[ -n "$_classified_file" ]] && NON_ALLOWLISTED_FILES+=("$_classified_file")
        done <<< "$_non_allowlisted"
    fi
fi

# ── All staged files are allowlisted → allow without review ──────────────────
if [[ ${#NON_ALLOWLISTED_FILES[@]} -eq 0 ]]; then
    log_decision "pass"
    exit 0
fi

# ── Source fragment staleness check ──────────────────────────────────────────
# When reviewer source fragments (reviewer-base.md or reviewer-delta-*.md) are
# staged, verify that every generated agent file's embedded content-hash matches
# the expected hash of its source inputs. Blocks commit if any hash is stale.
#
# Hash algorithm: sha256(base_content + "\n" + delta_content) — identical to
# build-review-agents.sh (see HASH_ALGORITHM comment in that script).
_has_staged_fragments=false
for _sf in "${STAGED_FILES[@]}"; do
    case "$_sf" in
        "${_PLUGIN_GIT_PATH}"/docs/workflows/prompts/reviewer-base.md|"${_PLUGIN_GIT_PATH}"/docs/workflows/prompts/reviewer-delta-*.md)
            _has_staged_fragments=true
            break
            ;;
    esac
done

if [[ "$_has_staged_fragments" == "true" ]]; then
    # Portable sha256 wrapper — same as build-review-agents.sh _sha256()
    _sha256_gate() {
        if command -v sha256sum &>/dev/null; then
            sha256sum | awk '{print $1}'
        elif command -v shasum &>/dev/null; then
            shasum -a 256 | awk '{print $1}'
        else
            echo "ERROR: no sha256sum or shasum available" >&2
            return 1
        fi
    }

    # Read base content from the staged (index) version
    _base_content=$(git show ":${_PLUGIN_GIT_PATH}/docs/workflows/prompts/reviewer-base.md" 2>/dev/null || echo "")

    # Find all generated agent files in the repo
    _stale_agents=()
    # shellcheck disable=SC2231  # Pre-existing: glob in for-loop with variable prefix — intentional
    for _agent_file in ${_PLUGIN_GIT_PATH}/agents/code-reviewer-*.md; do
        [[ -f "$_agent_file" ]] || continue

        # Extract tier from filename: code-reviewer-<tier>.md
        _tier_name="$(basename "$_agent_file")"
        _tier_name="${_tier_name#code-reviewer-}"
        _tier_name="${_tier_name%.md}"

        # Find the corresponding delta file
        _delta_path="${_PLUGIN_GIT_PATH}/docs/workflows/prompts/reviewer-delta-${_tier_name}.md"

        # Read delta content from staged (index) version if staged, else from working tree
        _delta_content=$(git show ":${_delta_path}" 2>/dev/null || cat "$_delta_path" 2>/dev/null || echo "")

        # Compute expected hash: sha256(base_content + "\n" + delta_content)
        _expected_hash=$(printf '%s\n%s' "$_base_content" "$_delta_content" | _sha256_gate)

        # Extract embedded content-hash from the agent file (staged version if staged, else committed)
        _agent_content=$(git show ":${_agent_file}" 2>/dev/null || git show "HEAD:${_agent_file}" 2>/dev/null || cat "$_agent_file" 2>/dev/null || echo "")
        _embedded_hash=$(echo "$_agent_content" | sed -n 's/.*<!-- content-hash: \([a-f0-9]*\) -->.*/\1/p' 2>/dev/null | head -1)

        if [[ -z "$_embedded_hash" ]]; then
            _stale_agents+=("$_agent_file (no content-hash found)")
        elif [[ "$_expected_hash" != "$_embedded_hash" ]]; then
            _stale_agents+=("$_agent_file (expected=${_expected_hash:0:12}..., found=${_embedded_hash:0:12}...)")
        fi
    done

    if [[ ${#_stale_agents[@]} -gt 0 ]]; then
        echo "" >&2
        echo "BLOCKED: reviewer agent staleness check" >&2
        echo "" >&2
        echo "  Source fragments were modified but generated agent files are stale." >&2
        echo "  Stale agents:" >&2
        for _sa in "${_stale_agents[@]}"; do
            echo "    - ${_sa}" >&2
        done
        echo "" >&2
        echo "  Fix: run 'bash ${_PLUGIN_ROOT}/scripts/build-review-agents.sh' to regenerate," >&2
        echo "  then stage the updated agent files." >&2
        echo "" >&2
        log_decision "block"
        exit 1
    fi
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
    if _is_formatting_only_drift || _is_shellcheck_disable_only_drift; then
        # Re-compute hash for current staged state and update review-status
        _REHASH=$(bash "$HOOK_DIR/compute-diff-hash.sh" 2>/dev/null || echo "")
        if [[ -n "$_REHASH" ]]; then
            # Update diff_hash line in review-status (preserve all other fields)
            _TMP_STATUS=$(mktemp)
            grep -v '^diff_hash=' "$REVIEW_STATE_FILE" > "$_TMP_STATUS" 2>/dev/null || true
            echo "diff_hash=${_REHASH}" >> "$_TMP_STATUS"
            mv "$_TMP_STATUS" "$REVIEW_STATE_FILE"
            echo "pre-commit-review-gate: non-functional drift self-healed (rehash=${_REHASH:0:12}...)" >&2
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
