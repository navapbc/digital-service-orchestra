#!/usr/bin/env bash
# hooks/record-test-status.sh
# Utility: discovers associated test files for staged source files, runs them,
# and records pass/fail status with diff_hash to test-gate-status.
#
# Mirrors the structure of record-review.sh. Called from COMMIT-WORKFLOW.md
# before the commit step to ensure changed code passes its associated tests.
#
# Usage:
#   record-test-status.sh [--source-file <path>]
#   When --source-file is omitted, runs discovery for all staged source files.
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

# Parse arguments
SOURCE_FILE=""
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
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "" >&2
            echo "Usage: record-test-status.sh [--source-file <path>]" >&2
            exit 1
            ;;
    esac
done

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

# --- Detect staged skill files (for Tier 1 eval invocation) ---
# Collected here (before the "no associated tests" early exit) so that skill evals
# run even when no unit tests are associated with the staged files.
_SKILL_PATTERN="plugins/dso/skills/"
_staged_skill_paths=""
while IFS= read -r _sf; do
    [[ -z "$_sf" ]] && continue
    case "$_sf" in
        *"${_SKILL_PATTERN}"*)
            _staged_skill_paths="${_staged_skill_paths}${REPO_ROOT}/${_sf}"$'\n'
            ;;
    esac
done <<< "$STAGED_FILES"

# --- Discover associated test files ---
ASSOCIATED_TESTS=()
# Parallel array: RED marker for each entry in ASSOCIATED_TESTS (empty string = no marker)
ASSOCIATED_TEST_MARKERS=()
# Associative map: test_file -> marker (to preserve markers through dedup)
declare -A _TEST_MARKER_MAP=()

# Discover associated test files using fuzzy matching
while IFS= read -r src_file; do
    [[ -z "$src_file" ]] && continue

    # If src_file is itself a test file, add it directly to ASSOCIATED_TESTS
    # (the test must pass before it can be committed) and skip fuzzy matching.
    if fuzzy_is_test_file "$src_file"; then
        _test_self="$src_file"
        _test_self_path="$REPO_ROOT/$_test_self"
        if [[ -f "$_test_self_path" ]]; then
            if [[ "$_test_self" == *.sh ]] && [[ ! -x "$_test_self_path" ]]; then
                echo "WARNING: skipping non-executable shell test: $_test_self" >&2
            else
                ASSOCIATED_TESTS+=("$_test_self")
                if [[ -z "${_TEST_MARKER_MAP[$_test_self]+set}" ]]; then
                    _TEST_MARKER_MAP["$_test_self"]=""
                fi
            fi
        fi
        continue
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

# --- No associated tests and no staged skill files: exit cleanly (exempt) ---
if [[ ${#ASSOCIATED_TESTS[@]} -eq 0 ]] && [[ -z "$_staged_skill_paths" ]]; then
    # No associated tests and no skill evals to run — exit cleanly without writing
    # test-gate-status (the gate exempts files with no associated tests)
    exit 0
fi

# --- Compute diff hash BEFORE running tests (AFTER git add, same as record-review.sh) ---
# Must be captured before test execution, which may create cache files that would
# alter the untracked file list and produce a different hash.
DIFF_HASH=$("$HOOK_DIR/compute-diff-hash.sh")

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
_EXISTING_STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"
if [[ -f "$_EXISTING_STATUS_FILE" ]]; then
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

    if [[ $exit_code -ne 0 ]] && [[ -n "$red_marker" ]]; then
        # RED marker present — check if all failures are in the RED zone
        red_zone_line=$(get_red_zone_line_number "$test_file" "$red_marker")

        if [[ "$red_zone_line" -eq -1 ]]; then
            # Marker not found in file: warn (already done in get_red_zone_line_number) and block
            echo "--- Test output for $test_file (exit $exit_code) ---" >&2
            cat "$test_output_file" >&2
            echo "--- End of test output ---" >&2
            rm -f "$test_output_file"
            if [[ "$STATUS" != "timeout" ]]; then
                STATUS="failed"
            fi
            continue
        fi

        # Parse failing test names from output
        mapfile -t failing_tests < <(parse_failing_tests_from_output "$test_output_file")

        if [[ ${#failing_tests[@]} -eq 0 ]]; then
            # Fail-safe: can't parse failing tests → block
            echo "WARNING: RED marker '${red_marker}' set for ${test_file} but could not parse failing test names from output; treating as blocking failure." >&2
            echo "--- Test output for $test_file (exit $exit_code) ---" >&2
            cat "$test_output_file" >&2
            echo "--- End of test output ---" >&2
            rm -f "$test_output_file"
            if [[ "$STATUS" != "timeout" ]]; then
                STATUS="failed"
            fi
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

# --- Skill eval integration (Tier 1) ---
# _staged_skill_paths was collected earlier (before the "no associated tests" early exit).
# Invoke run-skill-evals.sh with absolute paths to staged skill files.
# run-skill-evals.sh maps file paths to skill directories, deduplicates, and
# runs promptfoo evals only if evals/promptfooconfig.yaml exists.
# Non-zero exit = eval failure → downgrade STATUS to 'failed' (or preserve 'timeout').
if [[ -n "$_staged_skill_paths" ]]; then
    _RUN_EVALS_SCRIPT="${RECORD_TEST_STATUS_EVALS_RUNNER:-${HOOK_DIR}/../scripts/run-skill-evals.sh}"
    # Skip evals when ANTHROPIC_API_KEY is not set (evals require API access),
    # unless an explicit override runner is provided (RECORD_TEST_STATUS_EVALS_RUNNER)
    # which allows tests to supply a mock runner without requiring API credentials.
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -z "${RECORD_TEST_STATUS_EVALS_RUNNER:-}" ]]; then
        echo "NOTE: ANTHROPIC_API_KEY not set; skipping skill evals (evals require API access)." >&2
    elif [[ -x "$_RUN_EVALS_SCRIPT" ]]; then
        # Build argument list from newline-separated paths
        _eval_args=()
        while IFS= read -r _sp; do
            [[ -z "$_sp" ]] && continue
            _eval_args+=("$_sp")
        done <<< "$_staged_skill_paths"

        _eval_exit=0
        bash "$_RUN_EVALS_SCRIPT" "${_eval_args[@]}" >&2 || _eval_exit=$?

        if [[ $_eval_exit -eq 2 ]]; then
            # npx/promptfoo not available — warn and skip (non-blocking)
            echo "WARNING: run-skill-evals.sh exited 2 (npx/promptfoo not available); skipping skill evals." >&2
        elif [[ $_eval_exit -ne 0 ]]; then
            # Eval failures at commit time are non-blocking warnings (LLM grading is non-deterministic).
            # The daily CI workflow (Tier 2) is the authoritative blocking gate for eval regressions.
            echo "WARNING: Skill eval failed (exit ${_eval_exit}) — non-blocking at commit time. Daily CI will catch regressions." >&2
        fi
    else
        echo "WARNING: run-skill-evals.sh not found or not executable at ${_RUN_EVALS_SCRIPT}; skipping skill evals." >&2
    fi
fi

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
    # Enforce severity hierarchy: timeout > failed > passed (never downgrade severity)
    # Compare both existing and current, keep the more severe.
    if [[ "$_existing_status" == "timeout" ]] || [[ "$STATUS" == "timeout" ]]; then
        STATUS="timeout"
    elif [[ "$_existing_status" == "failed" ]] || [[ "$STATUS" == "failed" ]]; then
        STATUS="failed"
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
    echo "bash plugins/dso/scripts/test-batched.sh --timeout=50 \"bash tests/hooks/test-<name>.sh\"" >&2
    echo "Then resume with the NEXT: command printed by test-batched.sh." >&2
    exit 1
fi

# --- Exit with appropriate code ---
if [[ "$STATUS" == "failed" ]]; then
    exit 1
fi

exit 0
