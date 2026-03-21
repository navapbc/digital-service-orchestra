#!/usr/bin/env bash
# hooks/pre-commit-test-gate.sh
# git pre-commit hook: fuzzy-match-based test gate for staged source files.
#
# DESIGN:
#   This hook runs at git pre-commit time, where staged files are natively
#   available via `git diff --cached --name-only`. For each staged source file
#   (any language) with an associated test found via fuzzy matching, the hook
#   verifies that test-gate-status has been recorded and is valid.
#
#   Test association uses alphanum normalization from fuzzy-match.sh:
#   source "bump-version.sh" normalizes to "bumpversionsh", and test file
#   "test-bump-version.sh" normalizes to "testbumpversionsh" — since the
#   normalized source is a substring of the normalized test name, they match.
#   See plugins/dso/hooks/lib/fuzzy-match.sh for the full algorithm.
#
# LOGIC:
#   1. Get list of staged files from `git diff --cached --name-only`
#   2. For each staged source file (not test files per fuzzy_is_test_file):
#        a. Use fuzzy_find_associated_tests to find matching test files
#        b. Files with no associated test are exempt (gate passes without blocking)
#   3. For files with associated tests, check $ARTIFACTS_DIR/test-gate-status:
#        a. If test-gate-status file is absent -> exit 1 (MISSING)
#        b. Read first line: must be 'passed' -> else exit 1 (NOT_PASSED)
#        c. Read diff_hash line: compute current staged diff hash via
#           compute-diff-hash.sh -> compare; if mismatch -> exit 1 (HASH_MISMATCH)
#   4. All checks pass -> exit 0
#
# ERROR MESSAGES:
#   MISSING:       'BLOCKED: test gate — no test-status recorded. Run record-test-status.sh or use /dso:commit'
#   HASH_MISMATCH: 'BLOCKED: test gate — code changed since tests were recorded. Re-run record-test-status.sh'
#   NOT_PASSED:    'BLOCKED: test gate — tests did not pass. Fix failures before committing'
#   exit 144 hint: 'Run: plugins/dso/scripts/test-batched.sh --timeout=50 "<test cmd>"'
#
# INSTALL:
#   Registered in .pre-commit-config.yaml as a local hook (NOT via core.hooksPath).
#
# ENVIRONMENT:
#   WORKFLOW_PLUGIN_ARTIFACTS_DIR  — override for artifacts dir (used in tests)
#   CLAUDE_PLUGIN_ROOT             — optional; used to locate compute-diff-hash.sh
#   COMPUTE_DIFF_HASH_OVERRIDE     — override path to compute-diff-hash.sh (used in tests)
#   TEST_EXEMPTIONS_OVERRIDE       — override path to test-exemptions file (used in tests)

set -uo pipefail

# ── Locate hook and plugin directories ──────────────────────────────────────
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared dependency library (provides get_artifacts_dir, hash_stdin, etc.)
source "$HOOK_DIR/lib/deps.sh"

# Source fuzzy match library (provides fuzzy_find_associated_tests, fuzzy_is_test_file)
source "$HOOK_DIR/lib/fuzzy-match.sh"

# ── Determine path to compute-diff-hash.sh ───────────────────────────────────
# Supports COMPUTE_DIFF_HASH_OVERRIDE env var for test injection.
# REVIEW-DEFENSE: COMPUTE_DIFF_HASH_OVERRIDE is a test-only seam, not a production bypass vector.
# Layer 2 (review-gate-bypass-sentinel.sh) blocks direct writes to test-gate-status and prevents
# --no-verify from circumventing PreToolUse hooks. The fail-open behavior on hash error is a
# deliberate safety-over-correctness tradeoff documented in the epic spec (dso-ppwp AC6).
_COMPUTE_DIFF_HASH="${COMPUTE_DIFF_HASH_OVERRIDE:-$HOOK_DIR/compute-diff-hash.sh}"

# ── Get staged files ──────────────────────────────────────────────────────────
# git diff --cached lists only staged (index-vs-HEAD) changes.
STAGED_FILES=()
_staged_output=$(git diff --cached --name-only 2>/dev/null || true)
if [[ -n "$_staged_output" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        STAGED_FILES+=("$f")
    done <<< "$_staged_output"
fi

# No staged files → nothing to check
if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# ── Determine repo root ────────────────────────────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# ── Read test directories from config ─────────────────────────────────────────
# Supports TEST_GATE_TEST_DIRS_OVERRIDE for testing, falls back to dso-config.conf,
# then defaults to "tests/"
if [[ -n "${TEST_GATE_TEST_DIRS_OVERRIDE:-}" ]]; then
    _TEST_DIRS="$TEST_GATE_TEST_DIRS_OVERRIDE"
else
    _TEST_DIRS=$(grep '^test_gate\.test_dirs=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)
    _TEST_DIRS="${_TEST_DIRS:-tests/}"
fi

# ── Fuzzy-match-based test association ─────────────────────────────────────────
# For each staged source file (any language), use fuzzy matching to find
# associated test files in the configured test directories.
# Returns 0 (true) if any associated test file exists, 1 (false) otherwise.
_has_associated_test() {
    local src_file="$1"

    # Skip test files themselves using shared fuzzy_is_test_file()
    if fuzzy_is_test_file "$src_file"; then
        return 1
    fi

    local _found
    _found=$(fuzzy_find_associated_tests "$src_file" "${REPO_ROOT:-.}" "$_TEST_DIRS" | head -1 || true)
    [[ -n "$_found" ]]
}

# ── Get associated test file path for a source file ──────────────────────────
# Returns the relative test file path on stdout, or empty if none found.
_get_associated_test_path() {
    local src_file="$1"

    if fuzzy_is_test_file "$src_file"; then
        return
    fi

    fuzzy_find_associated_tests "$src_file" "${REPO_ROOT:-.}" "$_TEST_DIRS" | head -1 || true
}

# ── Check if a test file is exempted ─────────────────────────────────────────
# Reads the exemptions file and checks for a line where node_id=<test-file-path>.
# Returns 0 if exempted, 1 if not.
_is_test_exempted() {
    local test_file_path="$1"
    local exemptions_file="${TEST_EXEMPTIONS_OVERRIDE:-${ARTIFACTS_DIR:-}/test-exemptions}"

    # If exemptions file does not exist, no tests are exempted (fail-safe)
    if [[ ! -f "$exemptions_file" ]]; then
        return 1
    fi

    # Check for a matching node_id= line
    if grep -q "^node_id=${test_file_path}$" "$exemptions_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ── Check if any staged file has an associated test ───────────────────────────
NEEDS_TEST_GATE=false
for _staged_file in "${STAGED_FILES[@]}"; do
    if _has_associated_test "$_staged_file"; then
        NEEDS_TEST_GATE=true
        break
    fi
done

# No staged files require test gate → allow
if [[ "$NEEDS_TEST_GATE" == false ]]; then
    exit 0
fi

# ── Resolve artifacts directory ────────────────────────────────────────────────
ARTIFACTS_DIR=$(get_artifacts_dir)
TEST_GATE_STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"

# ── Exemption check ──────────────────────────────────────────────────────────
# For each staged source file with an associated test, check if ALL associated
# tests are exempted. If after filtering, no files require the gate, exit 0.
_STILL_NEEDS_GATE=false
for _staged_file in "${STAGED_FILES[@]}"; do
    local_test_path=$(_get_associated_test_path "$_staged_file")
    if [[ -z "$local_test_path" ]]; then
        # No associated test — this file doesn't need the gate anyway
        continue
    fi
    if ! _is_test_exempted "$local_test_path"; then
        # At least one non-exempted test remains
        _STILL_NEEDS_GATE=true
        break
    fi
done

# All tests are exempted → allow commit without test-gate-status check
if [[ "$_STILL_NEEDS_GATE" == false ]]; then
    exit 0
fi

# ── Check test-gate-status exists ─────────────────────────────────────────────
if [[ ! -f "$TEST_GATE_STATUS_FILE" ]]; then
    echo "" >&2
    echo "BLOCKED: test gate — no test-status recorded. Run record-test-status.sh or use /dso:commit" >&2
    echo "" >&2
    echo "  Staged files requiring test verification:" >&2
    for _f in "${STAGED_FILES[@]}"; do
        if _has_associated_test "$_f"; then
            echo "    - ${_f}" >&2
        fi
    done
    echo "" >&2
    echo "  To unblock: run record-test-status.sh or use /dso:commit to record test status," >&2
    echo "  then retry your commit." >&2
    echo "" >&2
    echo "  If tests are timing out, run:" >&2
    echo "  plugins/dso/scripts/test-batched.sh --timeout=50 \"<test cmd>\"" >&2
    echo "" >&2
    exit 1
fi

# ── Check first line is 'passed' ───────────────────────────────────────────────
TEST_STATUS_LINE=$(head -1 "$TEST_GATE_STATUS_FILE" 2>/dev/null || echo "")
if [[ "$TEST_STATUS_LINE" != "passed" ]]; then
    echo "" >&2
    echo "BLOCKED: test gate — tests did not pass. Fix failures before committing" >&2
    echo "" >&2
    echo "  Recorded status: ${TEST_STATUS_LINE}" >&2
    echo "" >&2
    if [[ "$TEST_STATUS_LINE" == "timeout" ]]; then
        echo "  Tests timed out (exit 144). Run:" >&2
        echo "  plugins/dso/scripts/test-batched.sh --timeout=50 \"<test cmd>\"" >&2
        echo "" >&2
    fi
    exit 1
fi

# ── Verify diff hash matches ───────────────────────────────────────────────────
RECORDED_HASH=$(grep '^diff_hash=' "$TEST_GATE_STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
if [[ -z "$RECORDED_HASH" ]]; then
    echo "" >&2
    echo "BLOCKED: test gate — test-gate-status has no diff_hash (corrupted or outdated)" >&2
    echo "" >&2
    echo "  Re-run record-test-status.sh or use /dso:commit to re-record test status." >&2
    echo "" >&2
    exit 1
fi

# Compute the current diff hash using the shared compute-diff-hash.sh script.
CURRENT_HASH=$(bash "$_COMPUTE_DIFF_HASH" 2>/dev/null || echo "")
if [[ -z "$CURRENT_HASH" ]]; then
    # Hash computation failed — fail open to avoid blocking on infrastructure issues
    echo "pre-commit-test-gate: WARNING: hash computation failed — failing open" >&2
    exit 0
fi

if [[ "$RECORDED_HASH" != "$CURRENT_HASH" ]]; then
    echo "" >&2
    echo "BLOCKED: test gate — code changed since tests were recorded. Re-run record-test-status.sh" >&2
    echo "" >&2
    echo "  Recorded hash: ${RECORDED_HASH:0:12}..." >&2
    echo "  Current hash:  ${CURRENT_HASH:0:12}..." >&2
    echo "" >&2
    echo "  Re-run record-test-status.sh or use /dso:commit to re-record test status." >&2
    echo "" >&2
    echo "  If tests are timing out, run:" >&2
    echo "  plugins/dso/scripts/test-batched.sh --timeout=50 \"<test cmd>\"" >&2
    echo "" >&2
    exit 1
fi

# ── All checks passed → allow commit ──────────────────────────────────────────
exit 0
