#!/usr/bin/env bash
# Require bash 4+ for associative array support (declare -A).
# macOS ships with bash 3.2 at /bin/bash; install bash 4+ via Homebrew.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: record-test-status.sh requires bash 4+ (found ${BASH_VERSION})." >&2
    echo "Install a newer bash with: brew install bash" >&2
    exit 1
fi
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# record-test-status.sh
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
#   For each staged source file (e.g., ${CLAUDE_PLUGIN_ROOT}/hooks/foo.sh or src/bar.py):
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

# Source .test-index parsing helpers (read_test_index_for_source, find_global_red_marker_for_test)
source "$HOOK_DIR/lib/test-index.sh"

# Source centrality scoring helpers (_is_astgrep_sg, count_centrality)
source "$HOOK_DIR/lib/centrality.sh"

# Source per-test result processing helpers (EAGAIN_PATTERN, _is_eagain_failure, _process_test_result)
source "$HOOK_DIR/lib/test-result-processor.sh"

# Parse arguments
SOURCE_FILE=""
_RESTART=false
_ATTEST_DIR=""
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
        --attest)
            _ATTEST_DIR="$2"
            shift 2
            ;;
        --attest=*)
            _ATTEST_DIR="${1#*=}"
            shift
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "" >&2
            echo "Usage: record-test-status.sh [--source-file <path>] [--restart] [--attest <worktree-artifacts-dir>]" >&2
            exit 1
            ;;
    esac
done

# ── --attest mode: import test status from a source worktree ─────────────────
# When --attest is provided, skip ALL test discovery and execution. Instead:
# 1. Read source worktree's test-gate-status and validate it
# 2. Compute the current session diff hash
# 3. Write an attested test-gate-status to the session artifacts dir
if [[ -n "$_ATTEST_DIR" ]]; then
    _attest_source_status_file="$_ATTEST_DIR/test-gate-status"

    # Verify source status file exists
    if [[ ! -f "$_attest_source_status_file" ]]; then
        echo "ERROR: --attest: source test-gate-status not found at $_attest_source_status_file" >&2
        exit 1
    fi

    # Read and verify source status is "passed"
    _attest_src_status=$(head -1 "$_attest_source_status_file" 2>/dev/null || echo "")
    if [[ "$_attest_src_status" != "passed" ]]; then
        echo "ERROR: --attest: source status is '$_attest_src_status', expected 'passed'" >&2
        exit 1
    fi

    # Extract source diff hash and verify it is a valid SHA-256 hash
    # (ensures the source status is internally consistent, not a placeholder)
    _attest_src_hash=$(grep '^diff_hash=' "$_attest_source_status_file" 2>/dev/null | head -1 | cut -d= -f2 || echo "")
    if [[ -z "$_attest_src_hash" ]] || ! [[ "$_attest_src_hash" =~ ^[0-9a-f]{64}$ ]]; then
        echo "ERROR: --attest: source diff_hash is missing or invalid: '$_attest_src_hash'" >&2
        exit 1
    fi

    # Compute the current session diff hash (used in output, not for comparison with source)
    _attest_current_hash=$("$HOOK_DIR/compute-diff-hash.sh")

    # Extract tested_files from source
    _attest_src_tested=$(grep '^tested_files=' "$_attest_source_status_file" 2>/dev/null | head -1 | cut -d= -f2 || echo "")

    # Discover locally-required test files from .test-index for staged source files
    _attest_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    REPO_ROOT="$_attest_repo_root"  # Set global for read_test_index_for_source
    _attest_local_tests=""
    if [[ -n "$_attest_repo_root" ]]; then
        _attest_staged=$(git diff --cached --name-only 2>/dev/null || true)
        if [[ -n "$_attest_staged" ]]; then
            while IFS= read -r _asf; do
                [[ -z "$_asf" ]] && continue
                while IFS= read -r _at_entry; do
                    [[ -z "$_at_entry" ]] && continue
                    # Strip optional [marker] suffix
                    local_test_path="$_at_entry"
                    if [[ "$_at_entry" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                        local_test_path="${BASH_REMATCH[1]}"
                    fi
                    if [[ -n "$local_test_path" ]]; then
                        if [[ -n "$_attest_local_tests" ]]; then
                            _attest_local_tests="${_attest_local_tests},${local_test_path}"
                        else
                            _attest_local_tests="$local_test_path"
                        fi
                    fi
                done < <(read_test_index_for_source "$_asf")
            done <<< "$_attest_staged"
        fi
    fi

    # Union source tested_files with locally-discovered tests (deduplicated)
    _attest_all_tests="$_attest_src_tested"
    if [[ -n "$_attest_local_tests" ]]; then
        # Merge: add local tests not already in source list
        IFS=',' read -ra _local_arr <<< "$_attest_local_tests"
        for _lt in "${_local_arr[@]}"; do
            _lt="${_lt#"${_lt%%[![:space:]]*}"}"
            _lt="${_lt%"${_lt##*[![:space:]]}"}"
            [[ -z "$_lt" ]] && continue
            # Check if already present in the union
            if [[ ",$_attest_all_tests," != *",$_lt,"* ]]; then
                if [[ -n "$_attest_all_tests" ]]; then
                    _attest_all_tests="${_attest_all_tests},${_lt}"
                else
                    _attest_all_tests="$_lt"
                fi
            fi
        done
    fi

    # Extract worktree ID from basename of the artifacts dir path
    _attest_worktree_id=$(basename "$_ATTEST_DIR")

    # Write attested test-gate-status to session artifacts dir
    _attest_artifacts=$(get_artifacts_dir)
    mkdir -p "$_attest_artifacts"
    _attest_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$_attest_artifacts/test-gate-status" <<EOF
passed
diff_hash=${_attest_current_hash}
timestamp=${_attest_ts}
tested_files=${_attest_all_tests}
attest_source=${_attest_worktree_id}
EOF

    exit 0
fi

# --restart: clear stale status and progress files so the full suite runs fresh
if [[ "$_RESTART" == true ]]; then
    _artifacts=$(get_artifacts_dir)
    rm -f "$_artifacts/test-gate-status"
    rm -f "$_artifacts"/test-gate-progress-*
    echo "Restart: cleared test-gate-status and progress files." >&2
fi

# Determine repo root
# Use resolve_repo_root() from deps.sh (sourced above) so that PROJECT_ROOT and
# CLAUDE_PROJECT_DIR override git rev-parse --show-toplevel. This is critical when
# the script is invoked with a worktree CWD (e.g., the DSO plugin worktree) but the
# --source-file refers to a file in the host project: git rev-parse would return the
# worktree path instead of the host project root, causing a silent no-op (c7f3-3de6).
REPO_ROOT=$(resolve_repo_root)
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
if ! _is_astgrep_sg; then
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
        elif ! _is_astgrep_sg; then
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
    # Before exiting, clear any stale "failed" status caused by RED markers that
    # have since been removed from .test-index (137a-b61a). When only .test-index
    # is staged (not the original source file), ASSOCIATED_TESTS is empty and the
    # hook would exit 0 without updating the status file, leaving a stale "failed"
    # that blocks the pre-commit gate even though the marker is gone.
    _exempt_status_file="$ARTIFACTS_DIR/test-gate-status"
    if [[ -f "$_exempt_status_file" ]]; then
        _exempt_status=$(head -1 "$_exempt_status_file" 2>/dev/null || echo "")
        _exempt_failed=$(grep '^failed_tests=' "$_exempt_status_file" 2>/dev/null | head -1 | cut -d= -f2- || echo "")
        if [[ "$_exempt_status" == "failed" ]] && [[ "$_exempt_failed" == *"stale-red-marker:"* ]]; then
            _all_markers_gone=true
            # Pre-check: any non-stale-marker failure means we cannot safely clear
            # (mixed real + stale failures must not lose the real failure record)
            while IFS= read -r _entry; do
                [[ -z "$_entry" ]] && continue
                if [[ "$_entry" != *"stale-red-marker:"* ]]; then
                    _all_markers_gone=false
                    break
                fi
            done < <(echo "$_exempt_failed" | tr ',' '\n')
            # If all entries are stale-marker entries, check each marker is gone
            if [[ "$_all_markers_gone" == "true" ]]; then
                while IFS= read -r _entry; do
                    if [[ "$_entry" == *"stale-red-marker:"* ]]; then
                        _marker="${_entry##*stale-red-marker:}"
                        _marker="${_marker%%]*}"
                        if grep -qF "[$_marker]" "${REPO_ROOT}/.test-index" 2>/dev/null; then
                            _all_markers_gone=false
                            break
                        fi
                    fi
                done < <(echo "$_exempt_failed" | tr ',' '\n')
            fi
            if [[ "$_all_markers_gone" == "true" ]]; then
                echo "INFO: Stale RED-marker 'failed' status cleared — markers no longer in .test-index" >&2
                rm -f "$_exempt_status_file"
            fi
        fi
    fi
    # No associated tests — write passed with doc-only-exempt note so
    # harvest-worktree.sh finds the file (without this, harvest exits 2 with
    # "test-gate-status not found" even though the pre-commit gate passed the
    # doc-only commit as exempt — a2e0-3ae8).
    cat > "$ARTIFACTS_DIR/test-gate-status" <<EOF
passed
diff_hash=${DIFF_HASH}
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tested_files=doc-only-exempt
EOF
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
# shellcheck disable=SC2329  # invoked indirectly via: trap '_write_partial_status' URG
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
                _rel="${_tf#"$REPO_ROOT"/}"
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
    # shellcheck disable=SC2329  # invoked indirectly via: trap '_rts_cleanup_isolation' EXIT
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
    # exit 144 inside _process_test_result) appears in the audit record. Recording
    # attempted tests rather than only completed ones gives accurate observability
    # when tests are interrupted mid-run.
    if [[ -n "$TESTED_FILES_LIST" ]]; then
        TESTED_FILES_LIST="${TESTED_FILES_LIST},${test_file}"
    else
        TESTED_FILES_LIST="$test_file"
    fi

    # Run the test and update STATUS/FAILED_TESTS_LIST/HAD_TIMEOUT via _process_test_result.
    # The function is defined in lib/test-result-processor.sh (sourced above).
    _process_test_result "$test_file" "$red_marker" "$full_test_path"
done

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Write test-gate-status ---
STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"

# When called with --source-file, merge tested_files with existing status file
# to support per-file invocations without losing prior results.
if [[ -n "$SOURCE_FILE" ]] && [[ -f "$STATUS_FILE" ]]; then
    _existing_tested=$(grep '^tested_files=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    _existing_status=$(head -1 "$STATUS_FILE" 2>/dev/null || echo "")
    # Capture new-run-only tested files BEFORE merging with existing.
    # Used below to strip covered tests from _existing_failed (bug a8b0-7fbc).
    _new_run_tested="$TESTED_FILES_LIST"
    if [[ -n "$_existing_tested" ]]; then
        # Merge: append new tested_files, deduplicate
        _merged=$(printf '%s\n' "$_existing_tested" "$TESTED_FILES_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u | paste -sd ',' -)
        TESTED_FILES_LIST="$_merged"
    fi
    # Merge failed_tests list.
    # The new run is authoritative for any test it covered (_new_run_tested).
    # Strip those from _existing_failed before restoring, to prevent re-adding
    # RED-zone-tolerated failures from historical state (bug a8b0-7fbc).
    _existing_failed=$(grep '^failed_tests=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ -n "$_existing_failed" ]]; then
        _new_run_tests=$(printf '%s\n' "$_new_run_tested" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
        _filtered_existing_failed=""
        while IFS= read -r _ef_entry; do
            [[ -z "$_ef_entry" ]] && continue
            _ef_base="${_ef_entry%%\[*}"
            _ef_base="${_ef_base%"${_ef_base##*[![:space:]]}"}"
            _covered=false
            while IFS= read -r _nt; do
                [[ -z "$_nt" ]] && continue
                if [[ "$_ef_base" == "$_nt" ]]; then
                    _covered=true
                    break
                fi
            done <<< "$_new_run_tests"
            if [[ "$_covered" == false ]]; then
                if [[ -n "$_filtered_existing_failed" ]]; then
                    _filtered_existing_failed="${_filtered_existing_failed},$_ef_entry"
                else
                    _filtered_existing_failed="$_ef_entry"
                fi
            fi
        done < <(printf '%s\n' "$_existing_failed" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
        if [[ -n "$_filtered_existing_failed" ]] && [[ -n "$FAILED_TESTS_LIST" ]]; then
            FAILED_TESTS_LIST=$(printf '%s\n' "$_filtered_existing_failed" "$FAILED_TESTS_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u | paste -sd ',' -)
        elif [[ -n "$_filtered_existing_failed" ]]; then
            FAILED_TESTS_LIST="$_filtered_existing_failed"
        fi
        # (if _filtered_existing_failed empty, FAILED_TESTS_LIST stays as-is from new run)

        # Warn when merged result inherits failures from tests not re-run in this invocation.
        if [[ -n "$_filtered_existing_failed" ]]; then
            echo "WARNING: --source-file merge preserved inherited failures from tests not re-run in this invocation:" >&2
            echo "  Inherited (not re-run): ${_filtered_existing_failed}" >&2
            echo "  Newly run in this invocation: ${_new_run_tested:-<none>}" >&2
            echo "  If those tests now pass after your fix, use --restart to clear stale state and re-run." >&2
        fi
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
    echo "bash ${_PLUGIN_ROOT}/scripts/test-batched.sh --timeout=50 \"bash tests/hooks/test-<name>.sh\"" >&2  # shim-exempt: user-facing error message showing literal command
    echo "Then resume with the NEXT: command printed by test-batched.sh." >&2
    exit 1
fi

# --- Exit with appropriate code ---
if [[ "$STATUS" == "failed" ]]; then
    exit 1
fi

exit 0
