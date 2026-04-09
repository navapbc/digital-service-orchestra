#!/usr/bin/env bash
# hooks/record-test-status.sh
# Utility: discovers associated test files for staged source files, runs them,
# and records pass/fail status with diff_hash to test-gate-status.
#
# Mirrors the structure of record-review.sh. Called from COMMIT-WORKFLOW.md
# before the commit step to ensure changed code passes its associated tests.
#
# Usage:
#   record-test-status.sh [--source-file <path>] [--restart]
#   When --source-file is omitted, runs discovery for all staged source files.
#   --restart clears stale status and progress files before running.
#
# Convention-based association algorithm:
#   For each staged source file (e.g., plugins/dso/hooks/foo.sh or src/bar.py):
#     basename=<filename>
#     # Strip extension, add test_ prefix
#     test_name="test_${basename%.*}"
#     # Find in test directory tree
#     associated=<all matches>
#
# Environment variables:
#   RECORD_TEST_STATUS_RUNNER  — override the test runner command (for testing)
#   WORKFLOW_PLUGIN_ARTIFACTS_DIR — override artifacts directory (for testing)
#   CLAUDE_PLUGIN_ROOT — path to the DSO plugin root
#
# State file written to: $(get_artifacts_dir)/test-gate-status
# Format:
#   Line 1: 'passed' or 'failed' or 'timeout'
#   Line 2: diff_hash=<sha256>
#   Line 3: timestamp=<ISO8601>
#   Line 4: tested_files=<comma-separated list of test files run>
#
# .test-index format (extended):
#   source/path.ext: test/path1.ext [first_red_test_name], test/path2.ext
#   The optional [first_red_test_name] marker after a test path indicates the
#   first test in the RED zone. Failures at or after this marker are tolerated
#   (non-blocking). Failures before this marker still block. If the marker name
#   is not found in the test file, a warning is emitted and behavior falls back
#   to blocking. Entries without a [marker] are unaffected (backward compatible).

set -euo pipefail

# Source shared dependency library (provides get_artifacts_dir, hash_stdin, etc.)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"
source "$HOOK_DIR/lib/fuzzy-match.sh"

# Source RED zone helpers (get_red_zone_line_number, parse_failing_tests_from_output,
# get_test_line_number, parse_passing_tests_from_output) from shared lib.
source "$HOOK_DIR/lib/red-zone.sh"

# Source merge/rebase state library (provides ms_filter_to_worktree_only, etc.)
source "$HOOK_DIR/lib/merge-state.sh"

# ── .test-index parsing ──────────────────────────────────────────────────────
# Reads $REPO_ROOT/.test-index and returns test paths mapped to a given source file.
# Format per line: 'source/path.ext: test/path1.ext [marker], test/path2.ext'
#   - Lines starting with # are comments; blank lines are ignored
#   - Colons and commas in paths are not supported
#   - Empty right-hand side = no association for that line
#   - Optional [first_red_test_name] after a test path enables RED zone tolerance
# Returns lines on stdout: "test/path.ext" or "test/path.ext [marker_name]"
# Missing file = no output (no error). Nonexistent test paths: warning to stderr, skipped.
read_test_index_for_source() {
    local src_file="$1"
    local repo_root="${REPO_ROOT:-.}"
    local index_file="${repo_root}/.test-index"

    if [[ ! -f "$index_file" ]]; then
        echo "INFO: .test-index not found, using fuzzy match only" >&2
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Split on first colon: left = source path, right = comma-separated test paths
        local left="${line%%:*}"
        local right="${line#*:}"

        # Trim whitespace from left side
        left="${left#"${left%%[![:space:]]*}"}"
        left="${left%"${left##*[![:space:]]}"}"

        # Match against the source file
        if [[ "$left" != "$src_file" ]]; then
            continue
        fi

        # Split right side on commas and emit each non-empty test path (with optional [marker])
        # Declare parts and part as local to prevent clobbering caller variables.
        local parts part
        IFS=',' read -ra parts <<< "$right"
        for part in "${parts[@]}"; do
            # Trim leading/trailing whitespace
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            if [[ -n "$part" ]]; then
                # Extract optional [marker_name] suffix: "test/path.ext [marker]"
                local test_path marker_name
                if [[ "$part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                    test_path="${BASH_REMATCH[1]}"
                    marker_name="${BASH_REMATCH[2]}"
                    # Trim trailing whitespace from test_path
                    test_path="${test_path%"${test_path##*[![:space:]]}"}"
                else
                    test_path="$part"
                    marker_name=""
                fi

                local full_path="${repo_root}/${test_path}"
                if [[ ! -f "$full_path" ]]; then
                    echo "WARNING: .test-index entry points to nonexistent file: $test_path" >&2
                    continue
                fi
                if [[ -n "$marker_name" ]]; then
                    echo "${test_path} [${marker_name}]"
                else
                    echo "$test_path"
                fi
            fi
        done
    done < "$index_file"
}

# find_global_red_marker_for_test: scan ALL .test-index entries (regardless of
# source file) to find a RED marker for a given test file path.
# Bug B fix (b9a9-4cb3): when a test is triggered by a staged source whose
# .test-index entry has no marker, a different source's entry may have one.
# This function performs a proper parse (not substring grep) to avoid false
# positives from overlapping filenames (e.g., "test_alpha.sh" must not match
# a marker on "test_alpha_extended.sh").
#
# Usage: find_global_red_marker_for_test <test_file_path>
# Returns: marker name on stdout (empty string if none found)
find_global_red_marker_for_test() {
    local target_test="$1"
    local repo_root="${REPO_ROOT:-.}"
    local index_file="${repo_root}/.test-index"

    [[ -f "$index_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Split on first colon: left = source, right = comma-separated tests
        local right="${line#*:}"

        # Declare parts and part as local to prevent clobbering caller variables.
        local parts part
        IFS=',' read -ra parts <<< "$right"
        for part in "${parts[@]}"; do
            # Trim whitespace
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            [[ -z "$part" ]] && continue

            # Parse "test/path.ext [marker_name]" or just "test/path.ext"
            local parsed_path parsed_marker
            if [[ "$part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                parsed_path="${BASH_REMATCH[1]}"
                parsed_marker="${BASH_REMATCH[2]}"
                # Trim trailing whitespace from path
                parsed_path="${parsed_path%"${parsed_path##*[![:space:]]}"}"
            else
                parsed_path="$part"
                parsed_marker=""
            fi

            # Exact path match (not substring) — hardened for overlapping names
            if [[ "$parsed_path" == "$target_test" ]] && [[ -n "$parsed_marker" ]]; then
                echo "$parsed_marker"
                return 0
            fi
        done
    done < "$index_file"
}

# ── EAGAIN resource exhaustion detection ─────────────────────────────────────
# Matches fork failures caused by transient resource pressure (EAGAIN/ENOMEM).
# Exit code 254 is used as a sentinel by suite-engine when the test process
# itself exits with this code indicating resource exhaustion.
EAGAIN_PATTERN='fork: (retry: )?Resource temporarily unavailable|BlockingIOError.*Resource temporarily unavailable'

# _is_eagain_failure <exit_code> <output_file>
# Returns 0 when exit_code==254 AND the output file contains the EAGAIN pattern.
_is_eagain_failure() {
    local exit_code="$1"
    local output_file="$2"
    [ "$exit_code" -eq 254 ] || return 1
    [ -f "$output_file" ] || return 1
    grep -qE "$EAGAIN_PATTERN" "$output_file" || return 1
    return 0
}

# ── Centrality scoring ───────────────────────────────────────────────────────
# REVIEW-DEFENSE: grep is used here for file-level fan-in counting, consistent with
# the project pattern in gate-2b-blast-radius.sh count_fan_in() (line 226). The
# CLAUDE.md directive to prefer built-in tools over Bash grep applies to *Claude Code
# tool calls*, not to shell script logic. grep -rlE is the standard tool for recursive
# file content matching in bash — no Python subprocess is warranted for a simple count.
#
# count_centrality: Counts files that directly reference the target file using
# grep pattern matching. Returns count on stdout (0 when no references found).
# Args: $1 = source file path (relative to repo root), $2 = repo root
# Returns: count on stdout (always a single integer, 0 on no matches)
count_centrality() {
    local filepath="$1"
    local repo_root="$2"

    local basename
    basename="$(basename "$filepath")"
    local module_name="${basename%.*}"

    # Escape regex metacharacters in module_name to prevent injection (Bug 5 fix).
    local escaped_module_name
    escaped_module_name=$(printf '%s' "$module_name" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

    # Hardcoded default patterns (fallback when no config patterns are present).
    # Patterns matched: Python import/from, bash source.
    local _hardcoded_pattern
    _hardcoded_pattern="(import[[:space:]]+${escaped_module_name}|from[[:space:]]+${escaped_module_name}[[:space:]]|source[[:space:]]+(.*/)?(${escaped_module_name}))"

    # Read test_gate.import_pattern.* keys from config.
    # Each key value may contain literal "$MODULE" which gets replaced with the escaped module name.
    local _config_file="${repo_root}/.claude/dso-config.conf"
    local _combined_pattern=""
    local _has_valid_config_pattern=false

    if [[ -f "$_config_file" ]]; then
        while IFS= read -r _cfg_line || [[ -n "$_cfg_line" ]]; do
            # Extract key and value
            local _cfg_key _cfg_val
            _cfg_key="${_cfg_line%%=*}"
            _cfg_val="${_cfg_line#*=}"

            # Skip entries with empty values
            [[ -z "$_cfg_val" ]] && continue

            # Replace literal $MODULE with the escaped module name
            local _resolved_pattern
            _resolved_pattern="${_cfg_val//\$MODULE/${escaped_module_name}}"

            # Validate pattern: use grep -E on empty string — exit 0 (match) or 1 (no match)
            # are both valid; any other exit code means the pattern itself is invalid.
            local _grep_rc=0
            echo '' | grep -E "$_resolved_pattern" /dev/null 2>/dev/null || _grep_rc=$?
            if [[ "$_grep_rc" -ne 0 && "$_grep_rc" -ne 1 ]]; then
                echo "WARNING: invalid import pattern '${_cfg_key}': ${_resolved_pattern} — skipping" >&2
                continue
            fi

            # Append valid pattern to combined pattern
            if [[ -z "$_combined_pattern" ]]; then
                _combined_pattern="$_resolved_pattern"
            else
                _combined_pattern="${_combined_pattern}|${_resolved_pattern}"
            fi
            _has_valid_config_pattern=true
        done < <(grep '^test_gate\.import_pattern\.' "$_config_file" 2>/dev/null || true)
    fi

    # When no valid config patterns exist, fall back to hardcoded default patterns
    local _grep_pattern
    if [[ "$_has_valid_config_pattern" == "true" ]]; then
        _grep_pattern="$_combined_pattern"
    else
        # fallback to hardcoded default patterns
        _grep_pattern="$_hardcoded_pattern"
    fi

    local count
    count=$(grep -rlE \
        "$_grep_pattern" \
        "$repo_root" \
        --include='*.py' --include='*.sh' --include='*.bash' \
        --include='*.js' --include='*.ts' --include='*.tsx' \
        --include='*.rb' --include='*.java' 2>/dev/null \
        | grep -vcF "$repo_root/$filepath" 2>/dev/null) || count=0
    # Ensure single integer — grep pipelines can produce multi-line output
    # when one stage fails (e.g., "0\n0" from BSD grep exit-1 + || fallback).
    count=$(echo "$count" | tail -1 | tr -d '[:space:]')
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    echo "$count"
}

# Parse arguments
SOURCE_FILE=""
_RESTART=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-file)
            SOURCE_FILE="$2"
            shift 2
            ;;
        --source-file=*)
            SOURCE_FILE="${1#*=}"
            shift
            ;;
        --restart)
            _RESTART=true
            shift
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "" >&2
            echo "Usage: record-test-status.sh [--source-file <path>] [--restart]" >&2
            exit 1
            ;;
    esac
done

# --restart: clear stale status and progress files so the full suite runs fresh
if [[ "$_RESTART" == true ]]; then
    _artifacts=$(get_artifacts_dir)
    rm -f "$_artifacts/test-gate-status"
    rm -f "$_artifacts"/test-gate-progress-*
    echo "Restart: cleared test-gate-status and progress files." >&2
fi

# Determine repo root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    echo "ERROR: not in a git repository" >&2
    exit 1
fi

ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

# Read test directory configuration
if [[ -n "${TEST_GATE_TEST_DIRS_OVERRIDE:-}" ]]; then
    _TEST_DIRS="$TEST_GATE_TEST_DIRS_OVERRIDE"
else
    _TEST_DIRS=$(grep '^test_gate\.test_dirs=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)
    _TEST_DIRS="${_TEST_DIRS:-tests/}"
fi

# Read centrality threshold configuration (default: 8)
_CENTRALITY_THRESHOLD=$(grep '^test_gate\.centrality_threshold=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)
_CENTRALITY_THRESHOLD="${_CENTRALITY_THRESHOLD:-8}"

# Read file count threshold configuration (default: 50)
# When staged file count exceeds this threshold, centrality is skipped and full suite runs.
_FILE_COUNT_THRESHOLD=$(grep '^test_gate\.file_count_threshold=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)
_FILE_COUNT_THRESHOLD="${_FILE_COUNT_THRESHOLD:-50}"

# Read full test suite command from config (commands.test)
_FULL_SUITE_CMD=$(grep '^commands\.test=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)

# --- Discover staged source files ---
if [[ -n "$SOURCE_FILE" ]]; then
    STAGED_FILES="$SOURCE_FILE"
else
    STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
fi

if [[ -z "$STAGED_FILES" ]]; then
    # No staged files — nothing to test, exit cleanly
    exit 0
fi

# --- Merge/Rebase commit: scope to worktree-only files ---
# During a merge or rebase, staged files may include incoming changes from the
# merge/rebase target that were already reviewed on main. Scope to files the
# worktree branch actually changed. Uses shared merge-state.sh library.
#
# Note: ms_filter_to_worktree_only is NOT used here because it fails open on
# empty intersection (a valid state when all staged files are incoming-only).
# We compute the worktree-only file set and filter STAGED_FILES inline, so
# an empty result correctly exits 0 instead of falling through with all files.
# Fail-safe: if ms_get_worktree_only_files returns empty (merge-base failed),
# fall through to normal enforcement with the full staged file list.
if ms_is_merge_in_progress || ms_is_rebase_in_progress; then
    _worktree_only_files=$(ms_get_worktree_only_files 2>/dev/null || echo "")
    if [[ -n "$_worktree_only_files" ]]; then
        # Filter: keep only staged files that the worktree branch also changed
        _filtered_staged=""
        while IFS= read -r _rts_sf; do
            [[ -z "$_rts_sf" ]] && continue
            if echo "$_worktree_only_files" | grep -qxF "$_rts_sf" 2>/dev/null; then
                _filtered_staged+="$_rts_sf"$'\n'
            fi
        done <<< "$STAGED_FILES"

        if [[ -z "$_filtered_staged" ]]; then
            echo "Merge/rebase commit: all staged files are incoming-only — no worktree tests needed" >&2
            exit 0
        fi
        STAGED_FILES="$_filtered_staged"
    fi
    # Fail-safe: if worktree-only computation failed (empty _worktree_only_files),
    # fall through to normal enforcement with the full staged file list.
fi

# --- Discover associated test files ---
ASSOCIATED_TESTS=()
# Parallel array: RED marker for each entry in ASSOCIATED_TESTS (empty string = no marker)
ASSOCIATED_TEST_MARKERS=()
# Associative map: test_file -> marker (to preserve markers through dedup)
declare -A _TEST_MARKER_MAP=()

# Discover associated test files using fuzzy matching
while IFS= read -r src_file; do
    [[ -z "$src_file" ]] && continue

    # If src_file is itself a test file AND lives under a test directory,
    # add it directly to ASSOCIATED_TESTS and skip fuzzy matching.
    # Files in non-test directories (e.g., scripts/test-batched.sh) are source
    # files that happen to match test naming convention — they should be looked
    # up via .test-index and fuzzy matching, not executed directly as tests.
    _src_in_test_dir=false
    for _td in ${_TEST_DIRS//:/ }; do
        [[ "$src_file" == "$_td"* ]] && { _src_in_test_dir=true; break; }
    done
    if "$_src_in_test_dir" && fuzzy_is_test_file "$src_file"; then
        _test_self="$src_file"
        _test_self_path="$REPO_ROOT/$_test_self"
        if [[ -f "$_test_self_path" ]]; then
            if [[ "$_test_self" == *.sh ]] && [[ ! -x "$_test_self_path" ]]; then
                echo "WARNING: skipping non-executable shell test: $_test_self" >&2
            else
                ASSOCIATED_TESTS+=("$_test_self")
                # Look up RED marker from .test-index for this test file (bug 41dc-bb9b).
                # Without this, directly-staged test files with RED markers would have
                # their failures treated as real failures instead of tolerated.
                _direct_marker=""
                while IFS= read -r _idx_entry; do
                    [[ -z "$_idx_entry" ]] && continue
                    if [[ "$_idx_entry" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                        _idx_test="${BASH_REMATCH[1]}"
                        _idx_mk="${BASH_REMATCH[2]}"
                        # Strip source prefix (e.g., "source.md:tests/foo.sh" → "tests/foo.sh")
                        _idx_test="${_idx_test##*:}"
                        [[ "$_idx_test" == "$_test_self" ]] && { _direct_marker="$_idx_mk"; break; }
                    fi
                done < <(grep -F "$_test_self" "$REPO_ROOT/.test-index" 2>/dev/null || true)
                _TEST_MARKER_MAP["$_test_self"]="${_direct_marker}"
            fi
        fi
        # Do NOT continue — fall through to .test-index lookup below so that
        # other tests associated with this file (as a source) are also collected.
        # The test file itself is already added; the .test-index lookup may find
        # additional tests if the test file is also mapped as a source.
    fi

    # Collect from fuzzy matching (no markers from fuzzy match)
    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        full_test_path="$REPO_ROOT/$test_file"

        if [[ ! -f "$full_test_path" ]]; then
            echo "WARNING: skipping non-regular file: $test_file" >&2
            continue
        fi

        if [[ "$test_file" == *.sh ]] && [[ ! -x "$full_test_path" ]]; then
            echo "WARNING: skipping non-executable shell test: $test_file" >&2
            continue
        fi

        ASSOCIATED_TESTS+=("$test_file")
        # No marker from fuzzy match; only set if not already set by .test-index
        if [[ -z "${_TEST_MARKER_MAP[$test_file]+set}" ]]; then
            _TEST_MARKER_MAP["$test_file"]=""
        fi
    done < <(fuzzy_find_associated_tests "$src_file" "$REPO_ROOT" "$_TEST_DIRS")

    # Collect from .test-index (union with fuzzy results; may include [marker])
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        # Parse "test/path.ext [marker_name]" or just "test/path.ext"
        local_test_file=""
        local_marker=""
        if [[ "$entry" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
            local_test_file="${BASH_REMATCH[1]}"
            local_marker="${BASH_REMATCH[2]}"
        else
            local_test_file="$entry"
            local_marker=""
        fi

        full_test_path="$REPO_ROOT/$local_test_file"

        if [[ "$local_test_file" == *.sh ]] && [[ ! -x "$full_test_path" ]]; then
            echo "WARNING: skipping non-executable shell test: $local_test_file" >&2
            continue
        fi

        ASSOCIATED_TESTS+=("$local_test_file")
        # .test-index marker wins over fuzzy (no marker).
        # Bug A fix (b9a9-4cb3): non-empty marker must not be overwritten by
        # a later empty marker from a different source→test association.
        # Only overwrite if new marker is non-empty OR no entry exists yet.
        if [[ -n "$local_marker" ]] || [[ -z "${_TEST_MARKER_MAP[$local_test_file]:-}" ]]; then
            _TEST_MARKER_MAP["$local_test_file"]="$local_marker"
        fi
    done < <(read_test_index_for_source "$src_file")

done <<< "$STAGED_FILES"

# Deduplicate (preserving markers via the map)
if [[ ${#ASSOCIATED_TESTS[@]} -gt 0 ]]; then
    readarray -t ASSOCIATED_TESTS < <(printf '%s\n' "${ASSOCIATED_TESTS[@]}" | sort -u)
fi
# Bug B fix (b9a9-4cb3): global marker scan for test files that have no marker
# from the staged-source association path. A RED marker on ANY .test-index entry
# (even for a non-staged source) should apply — the marker is semantically a
# property of the test file's state, not the source→test association.
for _tf in "${ASSOCIATED_TESTS[@]}"; do
    if [[ -z "${_TEST_MARKER_MAP[$_tf]:-}" ]]; then
        _global_marker=$(find_global_red_marker_for_test "$_tf")
        if [[ -n "$_global_marker" ]]; then
            _TEST_MARKER_MAP["$_tf"]="$_global_marker"
        fi
    fi
done

# Rebuild marker array in the same order as deduplicated ASSOCIATED_TESTS
ASSOCIATED_TEST_MARKERS=()
for _tf in "${ASSOCIATED_TESTS[@]}"; do
    ASSOCIATED_TEST_MARKERS+=("${_TEST_MARKER_MAP[$_tf]:-}")
done

# --- Compute diff hash BEFORE centrality scoring (enables centrality caching) ---
# Computed early so centrality results can be cached keyed by diff hash.
# Also used later for test-gate-status and progress tracking.
DIFF_HASH=$("$HOOK_DIR/compute-diff-hash.sh")

# --- Centrality scoring: determine if full suite is needed ---
# Uses grep-based fan-in counting (no external tools required).
# When ast-grep (sg) is not installed, emits a diagnostic note but still
# performs centrality scoring via grep (the primary counting method).
FULL_SUITE=false
_max_centrality=0
_CENTRALITY_LOG="$ARTIFACTS_DIR/centrality-log.jsonl"
if ! command -v sg >/dev/null 2>&1; then
    echo "NOTE: ast-grep (sg) not installed — centrality scoring uses grep-based fan-in counting" >&2
fi

# Clean up stale centrality cache directories when diff hash changes.
# Keep only the cache for the current DIFF_HASH; remove all others.
for _old_cache_dir in "$ARTIFACTS_DIR"/centrality-cache-*/; do
    [[ -d "$_old_cache_dir" ]] || continue
    _old_cache_hash="${_old_cache_dir%/}"
    _old_cache_hash="${_old_cache_hash##*centrality-cache-}"
    if [[ "$_old_cache_hash" != "$DIFF_HASH" ]]; then
        rm -rf "$_old_cache_dir" 2>/dev/null || true
    fi
done

# Per-diff-hash centrality cache directory
_CENTRALITY_CACHE_DIR="$ARTIFACTS_DIR/centrality-cache-${DIFF_HASH}"

# Count staged source files for file count threshold check.
_staged_source_file_count=0
while IFS= read -r _scf; do
    [[ -z "$_scf" ]] && continue
    if ! fuzzy_is_test_file "$_scf"; then
        (( _staged_source_file_count++ )) || true
    fi
done <<< "$STAGED_FILES"

# File count threshold bypass: when staged file count exceeds threshold,
# skip per-file centrality computation and run the full suite directly.
if [[ "$_staged_source_file_count" -gt "$_FILE_COUNT_THRESHOLD" ]] 2>/dev/null; then
    FULL_SUITE=true
    echo "Staged file count ${_staged_source_file_count} exceeds threshold ${_FILE_COUNT_THRESHOLD} — skipping centrality, running full test suite" >&2
    # Log the threshold bypass decision to centrality-log.jsonl
    _ts_log=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
    printf '{"file":"(all)","centrality_score":0,"threshold":%s,"decision":"skipped_file_count","file_count":%s,"diff_hash":"%s","timestamp":"%s"}\n' \
        "$_FILE_COUNT_THRESHOLD" "$_staged_source_file_count" "$DIFF_HASH" "$_ts_log" \
        >> "$_CENTRALITY_LOG"
else
    while IFS= read -r _csf; do
        [[ -z "$_csf" ]] && continue
        # Skip test files — centrality is only meaningful for source files
        if fuzzy_is_test_file "$_csf"; then
            continue
        fi

        # Check per-file per-diff-hash cache before computing centrality
        _csf_safe="${_csf//\//_}"
        _cache_file="${_CENTRALITY_CACHE_DIR}/${_csf_safe}.centrality"
        _centrality=""
        if [[ -f "$_cache_file" ]]; then
            _centrality=$(cat "$_cache_file" 2>/dev/null || echo "")
        fi

        if [[ -z "$_centrality" ]] || ! [[ "$_centrality" =~ ^[0-9]+$ ]]; then
            _centrality=$(count_centrality "$_csf" "$REPO_ROOT" 2>/dev/null)
            _centrality="${_centrality:-0}"
            # Write to cache
            mkdir -p "$_CENTRALITY_CACHE_DIR"
            printf '%s\n' "$_centrality" > "$_cache_file"
        fi

        if [[ "$_centrality" -gt "$_max_centrality" ]] 2>/dev/null; then
            _max_centrality="$_centrality"
        fi

        # Determine decision for JSONL log
        _ts_log=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
        if [[ "$_centrality" -gt "$_CENTRALITY_THRESHOLD" ]] 2>/dev/null; then
            _decision="full_suite"
        elif ! command -v sg >/dev/null 2>&1; then
            _decision="skipped_no_sg"
        else
            _decision="associated_only"
        fi
        printf '{"file":"%s","centrality_score":%s,"threshold":%s,"decision":"%s","diff_hash":"%s","timestamp":"%s"}\n' \
            "$_csf" "$_centrality" "$_CENTRALITY_THRESHOLD" "$_decision" "$DIFF_HASH" "$_ts_log" \
            >> "$_CENTRALITY_LOG"
    done <<< "$STAGED_FILES"

    if [[ "$_max_centrality" -gt "$_CENTRALITY_THRESHOLD" ]] 2>/dev/null; then
        FULL_SUITE=true
        echo "Centrality score ${_max_centrality} exceeds threshold ${_CENTRALITY_THRESHOLD} — running full test suite" >&2
    fi
fi

# --- No associated tests: exit cleanly (exempt) ---
if [[ ${#ASSOCIATED_TESTS[@]} -eq 0 ]] && [[ "$FULL_SUITE" != "true" ]]; then
    # No associated tests — exit cleanly without writing
    # test-gate-status (the gate exempts files with no associated tests)
    exit 0
fi

# --- Incorporate .test-index content into cache key (dc5a-7663) ---
# .test-index is excluded from DIFF_HASH via the allowlist, so edits to it
# (e.g., RED marker removal) don't change DIFF_HASH. Salt the progress key
# with a short hash of .test-index content so cache is invalidated on edits.
_TEST_INDEX_FILE="$REPO_ROOT/.test-index"
if [[ -f "$_TEST_INDEX_FILE" ]]; then
    _TEST_INDEX_HASH=$(shasum -a 256 "$_TEST_INDEX_FILE" 2>/dev/null | cut -d' ' -f1 || echo "noindex")
else
    _TEST_INDEX_HASH="noindex"
fi

# --- Guard: clear stale status when code changed since last recorded test run ---
# If an existing 'passed' status was recorded for a DIFFERENT hash, clear it so
# the test loop below re-runs tests against the current code (dso-6x8o).
# Skip this guard in --source-file mode: that path is an incremental merge where
# the caller manages the status file across sequential per-file invocations.
# The merge block below (lines ~1200+) is the authoritative merging logic.
_EXISTING_STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"
if [[ -f "$_EXISTING_STATUS_FILE" ]] && [[ -z "$SOURCE_FILE" ]]; then
    _EXISTING_STATUS=$(head -1 "$_EXISTING_STATUS_FILE" 2>/dev/null || echo "")
    _EXISTING_HASH=$(grep '^diff_hash=' "$_EXISTING_STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2 || echo "")
    if [[ "$_EXISTING_STATUS" == "passed" ]] && [[ -n "$_EXISTING_HASH" ]] && [[ "$_EXISTING_HASH" != "$DIFF_HASH" ]]; then
        echo "WARNING: stale test-gate-status cleared — re-running tests for current hash." >&2
        echo "  Previously passed hash: ${_EXISTING_HASH:0:12}..." >&2
        echo "  Current diff hash:      ${DIFF_HASH:0:12}..." >&2
        rm -f "$_EXISTING_STATUS_FILE"
        # Also clear any stale progress files from previous hashes
        rm -f "$ARTIFACTS_DIR"/test-gate-progress-*
    fi
fi


# --- Resumable test progress ---
# Track which tests have passed in a progress file keyed by diff hash.
# On re-invocation (after SIGURG kills us at 73s), skip already-passed tests.
_PROGRESS_FILE="$ARTIFACTS_DIR/test-gate-progress-${DIFF_HASH:0:16}-${_TEST_INDEX_HASH:0:8}"
declare -A _COMPLETED_TESTS=()
if [[ -f "$_PROGRESS_FILE" ]]; then
    while IFS= read -r _done_test; do
        [[ -n "$_done_test" ]] && _COMPLETED_TESTS["$_done_test"]=1
    done < "$_PROGRESS_FILE"
    if [[ ${#_COMPLETED_TESTS[@]} -gt 0 ]]; then
        echo "Resuming: ${#_COMPLETED_TESTS[@]} tests already passed — skipping." >&2
    fi
fi

# --- Run associated tests ---
# Initialize before the SIGURG trap so ${STATUS} is never unbound when the
# trap fires.  Without this ordering, a SIGURG in the 3-line window between
# `trap` registration and the assignments below triggers an unbound-variable
# error under set -u and aborts the trap handler silently.
STATUS="passed"
HAD_TIMEOUT=false
TESTED_FILES_LIST=""
FAILED_TESTS_LIST=""

# SIGURG trap: write partial status before the tool kills us, so the next
# invocation can resume rather than restart.
# Write "partial" (not STATUS) to test-gate-status so the pre-commit test
# gate never accepts a mid-run snapshot as a valid pass — STATUS may still
# be "passed" while untested files remain in the queue.
_write_partial_status() {
    local _ts
    _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$ARTIFACTS_DIR/test-gate-status" <<PARTIAL
partial
diff_hash=${DIFF_HASH}
timestamp=${_ts}
tested_files=${TESTED_FILES_LIST}
PARTIAL
}
trap '_write_partial_status' URG

# --- Full suite execution path (centrality-triggered) ---
if [[ "$FULL_SUITE" == true ]]; then
    # Resume support: skip full suite if already completed for this diff hash
    _FULL_SUITE_PROGRESS_KEY="FULL_SUITE_COMPLETE"
    if [[ -n "${_COMPLETED_TESTS[$_FULL_SUITE_PROGRESS_KEY]:-}" ]]; then
        # Verify the status file still exists (could have been deleted between runs)
        _existing_status_file="$ARTIFACTS_DIR/test-gate-status"
        if [[ -f "$_existing_status_file" ]]; then
            _existing_hash=$(grep '^diff_hash=' "$_existing_status_file" 2>/dev/null | head -1 | cut -d= -f2 || echo "")
            if [[ "$_existing_hash" == "$DIFF_HASH" ]]; then
                echo "Resuming: full suite already passed — skipping." >&2
                exit 0
            fi
        fi
        # Status file missing or stale — fall through to re-run full suite
        echo "WARNING: progress file says full suite complete but status file missing/stale — re-running." >&2
    fi
fi

if [[ "$FULL_SUITE" == true ]]; then
    # Discover all test files in the configured test directories (single scan, reused below)
    _discovered_test_files=()
    _all_test_files=""
    IFS=':' read -ra _td_arr <<< "$_TEST_DIRS"
    for _td in "${_td_arr[@]}"; do
        _td="${_td%/}"
        if [[ -d "$REPO_ROOT/$_td" ]]; then
            while IFS= read -r _tf; do
                [[ -z "$_tf" ]] && continue
                _discovered_test_files+=("$_tf")
                _rel="${_tf#$REPO_ROOT/}"
                if [[ -n "$_all_test_files" ]]; then
                    _all_test_files="${_all_test_files},${_rel}"
                else
                    _all_test_files="$_rel"
                fi
            done < <(find "$REPO_ROOT/$_td" -not -path '*/__pycache__/*' -type f \( -name "test-*.sh" -o -name "test_*.sh" -o -name "test_*.py" -o -name "*.test.js" -o -name "*.test.ts" \) 2>/dev/null | sort)
        fi
    done

    # Bug 2 fix: guard against empty test dirs — if no test files discovered,
    # fall through to associated-tests behavior instead of false-positive "passed".
    if [[ ${#_discovered_test_files[@]} -eq 0 ]]; then
        echo "WARNING: full suite triggered but no test files found in configured dirs — falling back to associated tests" >&2
        FULL_SUITE=false
    fi

    _full_exit=0

    if [[ "$FULL_SUITE" != true ]]; then
        : # Fall through — FULL_SUITE was disabled by empty-test-dir guard above
    elif [[ -n "${RECORD_TEST_STATUS_RUNNER:-}" ]]; then
        # Use overridden runner (for testing) — reuse discovered file list
        TESTED_FILES_LIST="$_all_test_files"
        _runner_cmd=()
        read -ra _runner_cmd <<< "$RECORD_TEST_STATUS_RUNNER"
        # REVIEW-DEFENSE: First-failure-wins is intentional. The full-suite path
        # uses _full_exit to decide passed/failed/timeout (3 branches at line 626).
        # Exit 144 (SIGURG timeout) must take precedence over non-zero (test failure)
        # since the status file distinguishes "timeout" from "failed". Capturing only
        # the first non-zero exit ensures 144 is not overwritten by a later exit 1.
        # The per-file associated-tests path (line 700+) uses the same first-failure
        # pattern via its own exit_code variable.
        for _tf in "${_discovered_test_files[@]}"; do
            _tf_exit=0
            "${_runner_cmd[@]}" "$_tf" >/dev/null 2>&1 || _tf_exit=$?
            if [[ $_tf_exit -ne 0 ]] && [[ $_full_exit -eq 0 ]]; then
                _full_exit=$_tf_exit
            fi
        done
    elif [[ -n "$_FULL_SUITE_CMD" ]]; then
        # REVIEW-DEFENSE: TESTED_FILES_LIST is set BEFORE the suite runs so the
        # SIGURG trap (_write_partial_status) can report which files were targeted.
        # The trap writes status "partial" (not "passed"), so the pre-commit gate
        # never accepts this as a valid pass — it indicates an interrupted full-suite
        # run. Setting it after would leave TESTED_FILES_LIST empty on SIGURG, losing
        # observability about what was being tested when the kill occurred.
        TESTED_FILES_LIST="$_all_test_files"
        # Split config command into array (same pattern as RECORD_TEST_STATUS_RUNNER)
        _suite_cmd=()
        read -ra _suite_cmd <<< "$_FULL_SUITE_CMD"
        "${_suite_cmd[@]}" >/dev/null 2>&1 || _full_exit=$?
    else
        echo "WARNING: commands.test not configured — running associated tests only" >&2
        FULL_SUITE=false
    fi

    if [[ "$FULL_SUITE" == true ]]; then
        if [[ $_full_exit -eq 144 ]]; then
            STATUS="timeout"
        elif [[ $_full_exit -ne 0 ]]; then
            STATUS="failed"
        else
            STATUS="passed"
        fi

        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Write test-gate-status in standard format
        # REVIEW-DEFENSE: failed_tests is intentionally empty for full-suite runs.
        # The full suite runs as a single commands.test invocation — individual
        # failing test file names are not available (unlike the per-file path which
        # tracks each test_file independently). The pre-commit gate reads only the
        # first line (passed/failed/timeout) and diff_hash; failed_tests is informational.
        STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"
        cat > "$STATUS_FILE" <<EOF
${STATUS}
diff_hash=${DIFF_HASH}
timestamp=${TIMESTAMP}
tested_files=${TESTED_FILES_LIST}
failed_tests=
EOF

        echo "Test status recorded: ${STATUS} (full suite, diff_hash=${DIFF_HASH:0:12}..., tested=${TESTED_FILES_LIST})" >&2

        # Record full-suite completion in progress file for SIGURG resume support.
        # On success, write the key so a subsequent resume skips the full suite.
        # The progress file is cleaned up at the end of the script on normal exit.
        if [[ "$STATUS" == "passed" ]]; then
            echo "$_FULL_SUITE_PROGRESS_KEY" >> "$_PROGRESS_FILE"
        fi

        trap - URG

        # Clean up progress file on normal completion (same as associated-tests path)
        rm -f "$_PROGRESS_FILE" 2>/dev/null

        if [[ "$STATUS" == "failed" ]] || [[ "$STATUS" == "timeout" ]]; then
            exit 1
        fi
        exit 0
    fi
fi

# Isolate test subprocesses from real MERGE_HEAD/REBASE_HEAD state.
# Without this, test scripts that source merge-state.sh detect the live
# merge/rebase state instead of running in a clean context.
if ms_is_merge_in_progress || ms_is_rebase_in_progress; then
    _rts_isolation_dir=$(mktemp -d /tmp/rts-git-isolation-XXXXXX)
    git init -q "$_rts_isolation_dir" 2>/dev/null
    export _MERGE_STATE_GIT_DIR="$_rts_isolation_dir/.git"
    _rts_cleanup_isolation() { rm -rf "$_rts_isolation_dir" 2>/dev/null; }
    trap '_rts_cleanup_isolation' EXIT
fi

# ── Large test set advisory (bug 091a-368f) ──────────────────────────────────
# When the associated test count is large, the serial per-file loop may exceed
# the ~73s tool timeout ceiling. The existing resume mechanism (progress file)
# handles this by allowing re-invocation to skip already-passed tests.
# Log a note so the caller knows to expect potential resume cycles.
_BATCH_THRESHOLD=$(grep '^test_gate\.batch_threshold=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)
_BATCH_THRESHOLD="${_BATCH_THRESHOLD:-20}"

if [[ ${#ASSOCIATED_TESTS[@]} -gt $_BATCH_THRESHOLD ]]; then
    echo "NOTE: ${#ASSOCIATED_TESTS[@]} associated tests exceed advisory threshold ($_BATCH_THRESHOLD). If SIGURG interrupts, re-invoke to resume from progress file." >&2
fi

_test_idx=0
for test_file in "${ASSOCIATED_TESTS[@]}"; do
    red_marker="${ASSOCIATED_TEST_MARKERS[$_test_idx]:-}"
    (( _test_idx++ )) || true

    [[ -z "$test_file" ]] && continue

    # Skip tests that already passed in a previous invocation (resume support)
    if [[ -n "${_COMPLETED_TESTS[$test_file]:-}" ]]; then
        # Still include in the tested list for the final status record
        if [[ -n "$TESTED_FILES_LIST" ]]; then
            TESTED_FILES_LIST="${TESTED_FILES_LIST},${test_file}"
        else
            TESTED_FILES_LIST="$test_file"
        fi
        continue
    fi

    full_test_path="$REPO_ROOT/$test_file"

    # Append to tested_files list BEFORE running the test — intentional ordering.
    # This ensures that every test we attempted (including ones that time out with
    # exit 144 and hit `continue` below) appears in the audit record. Recording
    # attempted tests rather than only completed ones gives accurate observability
    # when tests are interrupted mid-run.
    if [[ -n "$TESTED_FILES_LIST" ]]; then
        TESTED_FILES_LIST="${TESTED_FILES_LIST},${test_file}"
    else
        TESTED_FILES_LIST="$test_file"
    fi

    # Determine runner — capture output to temp file for failure diagnostics
    exit_code=0
    test_output_file=$(mktemp /tmp/rts-output-XXXXXX)
    if [[ -n "${RECORD_TEST_STATUS_RUNNER:-}" ]]; then
        # Use overridden runner (for testing) — split into array to support multi-word commands
        _runner_cmd=()
        read -ra _runner_cmd <<< "$RECORD_TEST_STATUS_RUNNER"
        "${_runner_cmd[@]}" "$full_test_path" >"$test_output_file" 2>&1 || exit_code=$?
    elif [[ "$test_file" == *.sh ]]; then
        bash "$full_test_path" >"$test_output_file" 2>&1 || exit_code=$?
    elif [[ "$test_file" == *.py ]]; then
        # Use a per-invocation cache dir to avoid races when multiple
        # record-test-status processes run in parallel (e.g., concurrent worktrees).
        _rts_pytest_cache=$(mktemp -d "${TMPDIR:-/tmp}/pytest-rts-cache-XXXXXX")
        PYTHONDONTWRITEBYTECODE=1 python3 -m pytest "$full_test_path" --tb=short -q -p no:cacheprovider --override-ini="cache_dir=$_rts_pytest_cache" >"$test_output_file" 2>&1 || exit_code=$?
        rm -rf "$_rts_pytest_cache" 2>/dev/null || true
    elif [[ "$test_file" == *.ts ]] || [[ "$test_file" == *.tsx ]]; then
        npx --no-install jest "$full_test_path" --no-coverage >"$test_output_file" 2>&1 || exit_code=$?
    else
        # Unknown extension — try executing directly
        bash "$full_test_path" >"$test_output_file" 2>&1 || exit_code=$?
    fi

    # Handle test failure with RED marker logic
    if [[ $exit_code -eq 144 ]]; then
        rm -f "$test_output_file"
        STATUS="timeout"
        HAD_TIMEOUT=true
        continue
    fi

    # EAGAIN detection: exit 254 + resource-exhaustion pattern in output.
    # Must run BEFORE rm -f "$test_output_file" so the file still exists.
    # Severity: resource_exhaustion is below failed and timeout — only set if
    # current STATUS is "passed" (i.e., no worse status has been recorded yet).
    if _is_eagain_failure "$exit_code" "$test_output_file"; then
        rm -f "$test_output_file"
        if [[ "$STATUS" != "timeout" ]] && [[ "$STATUS" != "failed" ]]; then
            STATUS="resource_exhaustion"
        fi
        continue
    fi

    if [[ $exit_code -ne 0 ]] && [[ -n "$red_marker" ]]; then
        # RED marker present — check if all failures are in the RED zone
        red_zone_line=$(get_red_zone_line_number "$test_file" "$red_marker")

        if [[ "$red_zone_line" -eq -1 ]]; then
            # Marker not found in file: warn (already done in get_red_zone_line_number) and block
            echo "--- Test output for $test_file (exit $exit_code) ---" >&2
            cat "$test_output_file" >&2
            echo "--- End of test output ---" >&2
            rm -f "$test_output_file"
            # Record the failing test file for diagnostic clarity (bug 091a-368f)
            if [[ -n "$FAILED_TESTS_LIST" ]]; then
                FAILED_TESTS_LIST="${FAILED_TESTS_LIST},${test_file}"
            else
                FAILED_TESTS_LIST="$test_file"
            fi
            if [[ "$STATUS" != "timeout" ]]; then
                STATUS="failed"
            fi
            continue
        fi

        # Parse failing test names from output
        mapfile -t failing_tests < <(parse_failing_tests_from_output "$test_output_file")

        if [[ ${#failing_tests[@]} -eq 0 ]]; then
            # REVIEW-DEFENSE (091a-368f): Tolerating an empty parse result when a RED
            # marker is present is intentional and safe. The RED marker in .test-index
            # IS the guard: only files explicitly annotated with [marker] in .test-index
            # reach this path. Files without a RED marker still block on any failure
            # (they never enter this branch). The empty-parse case arises legitimately
            # for bash tests using assert_eq with multi-word labels, where the parser
            # correctly finds no function-name-style tokens in the FAIL output — this
            # is a property of the test authoring style, not an infrastructure crash.
            # An infrastructure crash (e.g., mktemp failure before any test runs) would
            # typically produce a non-zero exit and no FAIL lines, but it would also
            # produce no RED-marker annotation in .test-index in the first place — the
            # marker is placed deliberately by the developer to indicate known-failing
            # tests. Tolerating this path therefore cannot mask a crash for a test file
            # that was never intentionally marked RED.
            echo "INFO: RED marker '${red_marker}' set for ${test_file} but parser found no matching function names; tolerating as RED-zone failure." >&2
            rm -f "$test_output_file"
            # Do NOT downgrade STATUS — this test is non-blocking
            continue
        fi

        # Check each failing test's position against the RED zone start
        all_in_red_zone=true
        for failing_test in "${failing_tests[@]}"; do
            [[ -z "$failing_test" ]] && continue
            test_line=$(get_test_line_number "$test_file" "$failing_test")
            if [[ "$test_line" -eq -1 ]]; then
                # Can't locate the test in the file — treat conservatively
                # If the failing test name IS the marker, it's in the RED zone (at marker)
                if [[ "$failing_test" == "$red_marker" ]]; then
                    continue
                fi
                # Unknown position — fall back to blocking for this test
                all_in_red_zone=false
                break
            fi
            if [[ "$test_line" -lt "$red_zone_line" ]]; then
                all_in_red_zone=false
                break
            fi
        done

        if [[ "$all_in_red_zone" == true ]]; then
            # All failures are in the RED zone — tolerate them (partial progress is normal).
            # But first: check if the marker test itself is now passing (stale marker).
            # When exit_code != 0 but the marker test passes, the RED boundary has been
            # crossed — the marker is stale and must be removed.
            mapfile -t _passing_tests < <(parse_passing_tests_from_output "$test_output_file")
            _marker_is_passing=false
            for _pt in "${_passing_tests[@]}"; do
                if [[ "$_pt" == "$red_marker" ]]; then
                    _marker_is_passing=true
                    break
                fi
            done
            if [[ "$_marker_is_passing" == true ]]; then
                echo "STALE RED MARKER: ${test_file} (marker: ${red_marker}) — all RED-zone tests passed; remove the [${red_marker}] marker from .test-index" >&2
                rm -f "$test_output_file"
                if [[ "$STATUS" != "timeout" ]]; then
                    STATUS="failed"
                fi
                continue
            fi
            echo "INFO: RED zone failures tolerated for ${test_file} (marker: ${red_marker}, zone starts line ${red_zone_line})" >&2
            rm -f "$test_output_file"
            # Do NOT downgrade STATUS — this test is non-blocking
            continue
        else
            # Some failures are before the RED zone — block
            echo "--- Test output for $test_file (exit $exit_code) ---" >&2
            cat "$test_output_file" >&2
            echo "--- End of test output ---" >&2
            rm -f "$test_output_file"
            # Record the failing test file for diagnostic clarity (bug 091a-368f)
            if [[ -n "$FAILED_TESTS_LIST" ]]; then
                FAILED_TESTS_LIST="${FAILED_TESTS_LIST},${test_file}"
            else
                FAILED_TESTS_LIST="$test_file"
            fi
            if [[ "$STATUS" != "timeout" ]]; then
                STATUS="failed"
            fi
            continue
        fi
    fi

    # ── Stale RED marker detection: exit 0 + RED marker ───────────────────
    # If the test file passed (exit 0) but has a RED marker, the marker is
    # stale — all RED-zone tests are now passing. Block and report.
    if [[ $exit_code -eq 0 ]] && [[ -n "$red_marker" ]]; then
        echo "STALE RED MARKER: ${test_file} (marker: ${red_marker}) — all RED-zone tests passed; remove the [${red_marker}] marker from .test-index" >&2
        rm -f "$test_output_file"
        if [[ "$STATUS" != "timeout" ]]; then
            STATUS="failed"
        fi
        # Include in FAILED_TESTS_LIST so the test gate shows which file has the stale marker
        if [[ -n "$FAILED_TESTS_LIST" ]]; then
            FAILED_TESTS_LIST="${FAILED_TESTS_LIST},${test_file}[stale-red-marker:${red_marker}]"
        else
            FAILED_TESTS_LIST="${test_file}[stale-red-marker:${red_marker}]"
        fi
        continue
    fi

    # No RED marker (or test passed without marker) — standard behavior
    if [[ $exit_code -ne 0 ]]; then
        echo "--- Test output for $test_file (exit $exit_code) ---" >&2
        cat "$test_output_file" >&2
        echo "--- End of test output ---" >&2
    fi
    rm -f "$test_output_file"

    # Apply severity hierarchy: timeout > failed > passed (never downgrade severity)
    if [[ $exit_code -ne 0 ]] && [[ "$STATUS" != "timeout" ]]; then
        STATUS="failed"
        # Track which test files caused the failure for diagnostic clarity
        if [[ -n "$FAILED_TESTS_LIST" ]]; then
            FAILED_TESTS_LIST="${FAILED_TESTS_LIST},${test_file}"
        else
            FAILED_TESTS_LIST="${test_file}"
        fi
    fi

    # Record progress: append passed test to progress file for resume support.
    # Only record on success (exit 0) — failed/timeout tests must be re-run.
    if [[ $exit_code -eq 0 ]]; then
        echo "$test_file" >> "$_PROGRESS_FILE"
    fi
done

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Write test-gate-status ---
STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"

# When called with --source-file, merge tested_files with existing status file
# to support per-file invocations without losing prior results.
if [[ -n "$SOURCE_FILE" ]] && [[ -f "$STATUS_FILE" ]]; then
    _existing_tested=$(grep '^tested_files=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    _existing_status=$(head -1 "$STATUS_FILE" 2>/dev/null || echo "")
    if [[ -n "$_existing_tested" ]]; then
        # Merge: append new tested_files, deduplicate
        _merged=$(printf '%s\n' "$_existing_tested" "$TESTED_FILES_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u | paste -sd ',' -)
        TESTED_FILES_LIST="$_merged"
    fi
    # Merge failed_tests list
    _existing_failed=$(grep '^failed_tests=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ -n "$_existing_failed" ]] && [[ -n "$FAILED_TESTS_LIST" ]]; then
        FAILED_TESTS_LIST=$(printf '%s\n' "$_existing_failed" "$FAILED_TESTS_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u | paste -sd ',' -)
    elif [[ -n "$_existing_failed" ]]; then
        FAILED_TESTS_LIST="$_existing_failed"
    fi
    # Enforce severity hierarchy: timeout > failed > resource_exhaustion; passed from suite-engine is authoritative over resource_exhaustion
    # Compare both existing and current, keep the more severe.
    # Deference check: when existing status is "passed" and new STATUS is
    # "resource_exhaustion", preserve "passed" — suite-engine result is authoritative.
    if [[ "$_existing_status" == "timeout" ]] || [[ "$STATUS" == "timeout" ]]; then
        STATUS="timeout"
    elif [[ "$_existing_status" == "failed" ]] || [[ "$STATUS" == "failed" ]]; then
        STATUS="failed"
    elif [[ "$_existing_status" == "resource_exhaustion" ]] || [[ "$STATUS" == "resource_exhaustion" ]]; then
        # Only set resource_exhaustion if neither existing nor current is "passed"
        # (passed means the suite-engine ran successfully — authoritative)
        if [[ "$_existing_status" != "passed" ]] && [[ "$STATUS" != "passed" ]]; then
            STATUS="resource_exhaustion"
        else
            STATUS="passed"
        fi
    fi
fi

cat > "$STATUS_FILE" <<EOF
${STATUS}
diff_hash=${DIFF_HASH}
timestamp=${TIMESTAMP}
tested_files=${TESTED_FILES_LIST}
failed_tests=${FAILED_TESTS_LIST}
EOF

if [[ -n "$FAILED_TESTS_LIST" ]]; then
    echo "Test status recorded: ${STATUS} — failed tests: ${FAILED_TESTS_LIST} (diff_hash=${DIFF_HASH:0:12}..., tested=${TESTED_FILES_LIST})" >&2
else
    echo "Test status recorded: ${STATUS} (diff_hash=${DIFF_HASH:0:12}..., tested=${TESTED_FILES_LIST})" >&2
fi

# Clean up progress file — all tests ran to completion (no SIGURG kill)
rm -f "$_PROGRESS_FILE"

# Clear SIGURG trap — no longer needed
trap - URG

# --- Handle exit 144 (SIGURG/timeout) ---
if [[ "$HAD_TIMEOUT" == true ]]; then
    echo "Test runner terminated (exit 144). Complete tests using test-batched.sh:" >&2
    echo "bash plugins/dso/scripts/test-batched.sh --timeout=50 \"bash tests/hooks/test-<name>.sh\"" >&2  # shim-exempt: user-facing error message showing literal command
    echo "Then resume with the NEXT: command printed by test-batched.sh." >&2
    exit 1
fi

# --- Exit with appropriate code ---
if [[ "$STATUS" == "failed" ]]; then
    exit 1
fi

exit 0
