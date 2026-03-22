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

set -euo pipefail

# Source shared dependency library (provides get_artifacts_dir, hash_stdin, etc.)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"
source "$HOOK_DIR/lib/fuzzy-match.sh"

# ── .test-index parsing ──────────────────────────────────────────────────────
# Reads $REPO_ROOT/.test-index and returns test paths mapped to a given source file.
# Format per line: 'source/path.ext: test/path1.ext, test/path2.ext'
#   - Lines starting with # are comments; blank lines are ignored
#   - Colons and commas in paths are not supported
#   - Empty right-hand side = no association for that line
# Returns test paths on stdout, one per line. Missing file = no output (no error).
# Nonexistent test paths are emitted as warnings to stderr and skipped.
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

        # Split right side on commas and emit each non-empty test path
        IFS=',' read -ra parts <<< "$right"
        for part in "${parts[@]}"; do
            # Trim whitespace
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            if [[ -n "$part" ]]; then
                local full_path="${repo_root}/${part}"
                if [[ ! -f "$full_path" ]]; then
                    echo "WARNING: .test-index entry points to nonexistent file: $part" >&2
                    continue
                fi
                echo "$part"
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

# --- Discover associated test files ---
ASSOCIATED_TESTS=()

# Discover associated test files using fuzzy matching
while IFS= read -r src_file; do
    [[ -z "$src_file" ]] && continue

    # Skip if src_file is itself a test file
    if fuzzy_is_test_file "$src_file"; then
        continue
    fi

    # Collect from fuzzy matching
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
    done < <(fuzzy_find_associated_tests "$src_file" "$REPO_ROOT" "$_TEST_DIRS")

    # Collect from .test-index (union with fuzzy results; dedup happens below)
    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        full_test_path="$REPO_ROOT/$test_file"

        if [[ "$test_file" == *.sh ]] && [[ ! -x "$full_test_path" ]]; then
            echo "WARNING: skipping non-executable shell test: $test_file" >&2
            continue
        fi

        ASSOCIATED_TESTS+=("$test_file")
    done < <(read_test_index_for_source "$src_file")

done <<< "$STAGED_FILES"

# Deduplicate
if [[ ${#ASSOCIATED_TESTS[@]} -gt 0 ]]; then
    readarray -t ASSOCIATED_TESTS < <(printf '%s\n' "${ASSOCIATED_TESTS[@]}" | sort -u)
fi

# --- No associated tests: exit cleanly (exempt) ---
if [[ ${#ASSOCIATED_TESTS[@]} -eq 0 ]]; then
    # No associated tests found — exit cleanly without writing test-gate-status
    # (the gate exempts files with no associated tests)
    exit 0
fi

# --- Compute diff hash BEFORE running tests (AFTER git add, same as record-review.sh) ---
# Must be captured before test execution, which may create cache files that would
# alter the untracked file list and produce a different hash.
DIFF_HASH=$("$HOOK_DIR/compute-diff-hash.sh")

# --- Guard: reject re-stamping when code changed since last recorded test run ---
# If an existing 'passed' status was recorded for a DIFFERENT hash, refuse to
# overwrite it. This prevents the test gate from being satisfied without re-running
# tests against the actual code being committed (dso-6x8o).
_EXISTING_STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"
if [[ -f "$_EXISTING_STATUS_FILE" ]]; then
    _EXISTING_STATUS=$(head -1 "$_EXISTING_STATUS_FILE" 2>/dev/null || echo "")
    _EXISTING_HASH=$(grep '^diff_hash=' "$_EXISTING_STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2 || echo "")
    if [[ "$_EXISTING_STATUS" == "passed" ]] && [[ -n "$_EXISTING_HASH" ]] && [[ "$_EXISTING_HASH" != "$DIFF_HASH" ]]; then
        echo "ERROR: stale test-gate-status detected — code changed since tests last passed." >&2
        echo "  Previously passed hash: ${_EXISTING_HASH:0:12}..." >&2
        echo "  Current diff hash:      ${DIFF_HASH:0:12}..." >&2
        echo "  Re-run your tests from a clean state before committing." >&2
        exit 1
    fi
fi


# --- Run associated tests ---
STATUS="passed"
HAD_TIMEOUT=false
TESTED_FILES_LIST=""

for test_file in "${ASSOCIATED_TESTS[@]}"; do
    [[ -z "$test_file" ]] && continue

    full_test_path="$REPO_ROOT/$test_file"

    # Build comma-separated list
    if [[ -n "$TESTED_FILES_LIST" ]]; then
        TESTED_FILES_LIST="${TESTED_FILES_LIST},${test_file}"
    else
        TESTED_FILES_LIST="$test_file"
    fi

    # Determine runner — capture output to temp file for failure diagnostics
    exit_code=0
    test_output_file=$(mktemp /tmp/rts-output-XXXXXX)
    if [[ -n "${RECORD_TEST_STATUS_RUNNER:-}" ]]; then
        # Use overridden runner (for testing)
        "$RECORD_TEST_STATUS_RUNNER" "$full_test_path" >"$test_output_file" 2>&1 || exit_code=$?
    elif [[ "$test_file" == *.sh ]]; then
        bash "$full_test_path" >"$test_output_file" 2>&1 || exit_code=$?
    elif [[ "$test_file" == *.py ]]; then
        PYTHONDONTWRITEBYTECODE=1 python3 -m pytest "$full_test_path" --tb=short -q -p no:cacheprovider --override-ini="cache_dir=/tmp/pytest-rts-cache" >"$test_output_file" 2>&1 || exit_code=$?
    else
        # Unknown extension — try executing directly
        bash "$full_test_path" >"$test_output_file" 2>&1 || exit_code=$?
    fi

    # Display output on failure so the user can diagnose without re-running
    if [[ $exit_code -ne 0 ]]; then
        echo "--- Test output for $test_file (exit $exit_code) ---" >&2
        cat "$test_output_file" >&2
        echo "--- End of test output ---" >&2
    fi
    rm -f "$test_output_file"

    # Apply severity hierarchy: timeout > failed > passed (never downgrade severity)
    if [[ $exit_code -eq 144 ]]; then
        STATUS="timeout"
        HAD_TIMEOUT=true
    elif [[ $exit_code -ne 0 ]] && [[ "$STATUS" != "timeout" ]]; then
        STATUS="failed"
    fi
done

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Write test-gate-status ---
STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"
cat > "$STATUS_FILE" <<EOF
${STATUS}
diff_hash=${DIFF_HASH}
timestamp=${TIMESTAMP}
tested_files=${TESTED_FILES_LIST}
EOF

echo "Test status recorded: ${STATUS} (diff_hash=${DIFF_HASH:0:12}..., tested=${TESTED_FILES_LIST})" >&2

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
