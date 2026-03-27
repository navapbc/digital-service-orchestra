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

# ── Fail-open on timeout ─────────────────────────────────────────────────────
# pre-commit sends SIGTERM after the configured timeout (default 10s), which
# results in exit 124. Claude Code's tool timeout sends SIGURG (exit 144).
# A gate timeout is an infrastructure failure, not a test failure — blocking
# commits when the hook mechanism itself fails is a bad state that agents can't
# recover from. Trap both signals and exit 0 (fail-open) with a warning so the
# commit proceeds. This is consistent with the existing fail-open behavior on
# hash computation errors (compute-diff-hash.sh failure).
_fail_open_on_timeout() {
    echo "pre-commit-test-gate: WARNING: timed out — failing open (commit allowed)" >&2
    exit 0
}
trap _fail_open_on_timeout TERM URG

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

# ── Mechanical amend bypass (merge-to-main.sh version_bump / validate) ────────
# DSO_MECHANICAL_AMEND=1 is set by merge-to-main.sh before git commit --amend
# for mechanical operations (version bump, post-merge validation fold-in).
# These are single-field or auto-fix changes that don't require test verification.
# Layer 2 (review-gate-bypass-sentinel.sh) blocks misuse on non-amend commits.
if [[ "${DSO_MECHANICAL_AMEND:-}" == "1" ]]; then
    exit 0
fi

# ── Determine repo root ────────────────────────────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# ── Filter out allowlisted (non-reviewable) files ─────────────────────────────
# Uses the same allowlist and shared functions as the review gate to skip files
# that don't need test verification (tickets, images, docs, etc.). This prevents
# timeout when large numbers of non-reviewable files are staged.
# Shared functions _load_allowlist_patterns and _allowlist_to_grep_regex are
# sourced from deps.sh above.
_ALLOWLIST_FILE="${HOOK_DIR}/lib/review-gate-allowlist.conf"
if [[ -f "$_ALLOWLIST_FILE" ]] && declare -f _load_allowlist_patterns &>/dev/null; then
    _AL_PATTERNS=$(_load_allowlist_patterns "$_ALLOWLIST_FILE" 2>/dev/null || true)
    if [[ -n "$_AL_PATTERNS" ]]; then
        _AL_REGEX=$(_allowlist_to_grep_regex "$_AL_PATTERNS")
        if [[ -n "$_AL_REGEX" ]]; then
            _FILTERED_FILES=()
            for _f in "${STAGED_FILES[@]}"; do
                if ! echo "$_f" | grep -qE "$_AL_REGEX"; then
                    _FILTERED_FILES+=("$_f")
                fi
            done
            STAGED_FILES=("${_FILTERED_FILES[@]+"${_FILTERED_FILES[@]}"}")

            # All files were allowlisted → nothing to check
            if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
                exit 0
            fi
        fi
    fi
fi

# ── Merge commit: filter out incoming-only files ───────────────────────────────
# When MERGE_HEAD exists (e.g., `git merge --no-commit origin/main`), staged
# files include changes from the incoming branch that were already reviewed
# and merged on main. These incoming-only files should not require re-verification.
#
# Algorithm:
#   1. Compute merge base between HEAD and MERGE_HEAD
#   2. Get files changed on the worktree branch: merge-base..HEAD
#   3. Filter STAGED_FILES to only include files that the worktree branch touched
#   4. Files in staged but NOT in worktree-branch changes are incoming-only → exempt
#
# Fail-safe: if merge-base computation fails (e.g., fake MERGE_HEAD), fall
# through to normal enforcement with the full staged file list.
if [[ -f "$(git rev-parse --git-dir 2>/dev/null)/MERGE_HEAD" ]]; then
    _merge_head_sha=$(cat "$(git rev-parse --git-dir)/MERGE_HEAD" 2>/dev/null | head -1)
    if [[ -n "$_merge_head_sha" ]]; then
        _merge_base=$(git merge-base HEAD "$_merge_head_sha" 2>/dev/null || echo "")
        _head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        _merge_head_resolved=$(git rev-parse "$_merge_head_sha" 2>/dev/null || echo "")
        # Guard: MERGE_HEAD must resolve to a real commit different from HEAD.
        # If MERGE_HEAD == HEAD (fake/self-referencing), skip filtering to prevent bypass.
        # In a real merge, MERGE_HEAD points to the incoming branch tip (different from HEAD).
        if [[ -n "$_merge_base" && -n "$_merge_head_resolved" && "$_merge_head_resolved" != "$_head_sha" ]]; then
            # Get files changed on the worktree branch (merge-base..HEAD)
            _worktree_changed=$(git diff --name-only "$_merge_base" HEAD 2>/dev/null || echo "")

            # Filter staged files: keep only those that the worktree branch changed
            _filtered_staged=()
            for _sf in "${STAGED_FILES[@]}"; do
                if echo "$_worktree_changed" | grep -qxF "$_sf" 2>/dev/null; then
                    _filtered_staged+=("$_sf")
                fi
            done

            # Replace STAGED_FILES with filtered list
            STAGED_FILES=("${_filtered_staged[@]+"${_filtered_staged[@]}"}")

            # If all staged files were incoming-only, nothing to check
            if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
                exit 0
            fi
        fi
    fi
fi

# ── Read test directories from config ─────────────────────────────────────────
# Supports TEST_GATE_TEST_DIRS_OVERRIDE for testing, falls back to dso-config.conf,
# then defaults to "tests/"
if [[ -n "${TEST_GATE_TEST_DIRS_OVERRIDE:-}" ]]; then
    _TEST_DIRS="$TEST_GATE_TEST_DIRS_OVERRIDE"
else
    _TEST_DIRS=$(grep '^test_gate\.test_dirs=' "${REPO_ROOT}/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2- || true)
    _TEST_DIRS="${_TEST_DIRS:-tests/}"
fi

# ── .test-index parsing ──────────────────────────────────────────────────────
# Reads $REPO_ROOT/.test-index and returns test paths mapped to a given source file.
# Format per line: 'source/path.ext: test/path1.ext, test/path2.ext'
#   - Lines starting with # are comments; blank lines are ignored
#   - Colons and commas in paths are not supported
#   - Empty right-hand side = no association for that line
# Returns test paths on stdout, one per line. Missing file = no output (no error).
parse_test_index() {
    local src_file="$1"
    local index_file="${REPO_ROOT:-.}/.test-index"

    if [[ ! -f "$index_file" ]]; then
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
        # Strip optional [marker] suffix (e.g., "tests/foo.sh [test_red]" → "tests/foo.sh")
        # The gate only needs the real file path for association/coverage checks.
        IFS=',' read -ra parts <<< "$right"
        for part in "${parts[@]}"; do
            # Trim whitespace
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            if [[ -n "$part" ]]; then
                # Strip optional [marker] suffix: "test/path.ext [marker_name]" → "test/path.ext"
                if [[ "$part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                    part="${BASH_REMATCH[1]}"
                    # Trim any trailing whitespace from the extracted path
                    part="${part%"${part##*[![:space:]]}"}"
                fi
                echo "$part"
            fi
        done
    done < "$index_file"
}

# ── Auto-prune stale .test-index entries ─────────────────────────────────────
# Scans .test-index for entries whose test files don't exist on disk.
# Removes nonexistent test paths from each line; if all test paths for a
# source entry are stale, removes the entire line. Writes back atomically
# (tmp + mv) and auto-stages the modified file.
prune_test_index() {
    local index_file="${REPO_ROOT:-.}/.test-index"

    # Skip pruning during merge commits — auto-staging .test-index during a merge
    # can interfere with the merge state. The pre-commit-review-gate guards MERGE_HEAD
    # natively; this guard mirrors that behavior for the test gate.
    if [[ -f "${REPO_ROOT:-.}/.git/MERGE_HEAD" ]]; then
        return 0
    fi

    # No .test-index → nothing to prune
    if [[ ! -f "$index_file" ]]; then
        return 0
    fi

    local pruned_count=0
    local output_lines=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Preserve comments and blank lines as-is
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            output_lines+=("$line")
            continue
        fi

        # Split on first colon: left = source path, right = comma-separated test paths
        local left="${line%%:*}"
        local right="${line#*:}"

        # Trim whitespace from left side
        left="${left#"${left%%[![:space:]]*}"}"
        left="${left%"${left##*[![:space:]]}"}"

        # Split right side on commas and check each test path
        # Entries may have an optional [marker] suffix (e.g., "tests/foo.sh [test_red]").
        # Strip the marker before checking file existence, but preserve it in valid_paths.
        local valid_paths=()
        IFS=',' read -ra parts <<< "$right"
        for part in "${parts[@]}"; do
            # Trim whitespace
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            [[ -z "$part" ]] && continue

            # Extract optional [marker] suffix to preserve it in rewritten output
            local _test_path_bare _marker_suffix
            if [[ "$part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                _test_path_bare="${BASH_REMATCH[1]}"
                _test_path_bare="${_test_path_bare%"${_test_path_bare##*[![:space:]]}"}"
                _marker_suffix=" [${BASH_REMATCH[2]}]"
            else
                _test_path_bare="$part"
                _marker_suffix=""
            fi

            # Check if the test file exists on disk (relative to REPO_ROOT)
            if [[ -f "${REPO_ROOT:-.}/${_test_path_bare}" ]]; then
                # Preserve marker in the rewritten entry
                valid_paths+=("${_test_path_bare}${_marker_suffix}")
            else
                pruned_count=$((pruned_count + 1))
            fi
        done

        # If any valid paths remain, keep the line with only valid paths
        if [[ ${#valid_paths[@]} -gt 0 ]]; then
            local joined=""
            for vp in "${valid_paths[@]}"; do
                if [[ -z "$joined" ]]; then
                    joined="$vp"
                else
                    joined="${joined},${vp}"
                fi
            done
            output_lines+=("${left}:${joined}")
        fi
        # If no valid paths remain, the entire line is dropped (not added to output_lines)
    done < "$index_file"

    # Nothing pruned → no-op
    if [[ "$pruned_count" -eq 0 ]]; then
        return 0
    fi

    # Atomic write: write to .test-index.tmp, then mv to .test-index
    local tmp_file="${REPO_ROOT:-.}/.test-index.tmp"
    printf '%s\n' "${output_lines[@]}" > "$tmp_file"
    mv "$tmp_file" "$index_file"

    # Auto-stage the modified .test-index.
    # On failure, restore the original file (reverse the mv) and exit non-zero so
    # the user is alerted rather than silently proceeding with a mismatched
    # disk/staged state (the pruned version is on disk but the pre-prune version
    # remains staged, which would cause inconsistent association-check behavior).
    if ! git -C "${REPO_ROOT:-.}" add .test-index 2>/dev/null; then
        echo "pre-commit-test-gate: ERROR: failed to stage .test-index after pruning — aborting commit to prevent disk/staged mismatch" >&2
        echo "pre-commit-test-gate: Re-run your commit to retry, or manually run: git add .test-index" >&2
        exit 1
    fi

    echo "pre-commit-test-gate: pruned ${pruned_count} stale entries from .test-index, re-staged" >&2
}

# ── Get ALL associated test paths for a source file (union of fuzzy + index) ──
# Returns all associated test paths on stdout, one per line, deduplicated.
_get_all_associated_tests() {
    local src_file="$1"

    if fuzzy_is_test_file "$src_file"; then
        return
    fi

    # Collect from both sources into a combined set
    {
        fuzzy_find_associated_tests "$src_file" "${REPO_ROOT:-.}" "$_TEST_DIRS" 2>/dev/null || true
        parse_test_index "$src_file"
    } | sort -u
}

# ── Fuzzy-match-based test association ─────────────────────────────────────────
# For each staged source file (any language), use fuzzy matching and .test-index
# to find associated test files. Returns 0 (true) if any associated test exists.
_has_associated_test() {
    local src_file="$1"

    # Skip test files themselves using shared fuzzy_is_test_file()
    if fuzzy_is_test_file "$src_file"; then
        return 1
    fi

    local _found
    _found=$(_get_all_associated_tests "$src_file" | head -1)
    [[ -n "$_found" ]]
}

# ── Get associated test file path for a source file ──────────────────────────
# Returns the first relative test file path on stdout, or empty if none found.
# For the full union set, use _get_all_associated_tests().
_get_associated_test_path() {
    local src_file="$1"

    if fuzzy_is_test_file "$src_file"; then
        return
    fi

    _get_all_associated_tests "$src_file" | head -1 || true
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

# ── Prune stale .test-index entries before association checks ─────────────────
prune_test_index

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
# For each staged source file with associated tests (union of fuzzy + index),
# check if ALL associated tests are exempted. If after filtering, no files
# require the gate, exit 0.
_STILL_NEEDS_GATE=false
for _staged_file in "${STAGED_FILES[@]}"; do
    _all_tests=$(_get_all_associated_tests "$_staged_file")
    if [[ -z "$_all_tests" ]]; then
        # No associated test — this file doesn't need the gate anyway
        continue
    fi
    while IFS= read -r _test_path; do
        [[ -z "$_test_path" ]] && continue
        if ! _is_test_exempted "$_test_path"; then
            # At least one non-exempted test remains
            _STILL_NEEDS_GATE=true
            break 2
        fi
    done <<< "$_all_tests"
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

# ── Verify tested_files covers the full union of required tests ───────────────
# When .test-index maps tests for staged source files, verify that ALL tests
# in the union (fuzzy + index) are listed in the tested_files field.
# This check only activates when .test-index contributes at least one mapping
# for the staged files, to preserve backward compatibility with existing workflows.
_HAS_INDEX_TESTS=false
_REQUIRED_TESTS=()
for _staged_file in "${STAGED_FILES[@]}"; do
    # Check if .test-index provides any mappings for this file
    _index_tests=$(parse_test_index "$_staged_file")
    if [[ -n "$_index_tests" ]]; then
        _HAS_INDEX_TESTS=true
        # Collect the full union (fuzzy + index) for this file
        _all_tests=$(_get_all_associated_tests "$_staged_file")
        while IFS= read -r _test_path; do
            [[ -z "$_test_path" ]] && continue
            _REQUIRED_TESTS+=("$_test_path")
        done <<< "$_all_tests"
    fi
done

if [[ "$_HAS_INDEX_TESTS" == true ]]; then
    RECORDED_TESTED_FILES=$(grep '^tested_files=' "$TEST_GATE_STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ -n "$RECORDED_TESTED_FILES" ]]; then
        for _req_test in "${_REQUIRED_TESTS[@]}"; do
            _found_in_tested=false
            IFS=',' read -ra _tested_arr <<< "$RECORDED_TESTED_FILES"
            for _tested in "${_tested_arr[@]}"; do
                # Trim whitespace
                _tested="${_tested#"${_tested%%[![:space:]]*}"}"
                _tested="${_tested%"${_tested##*[![:space:]]}"}"
                if [[ "$_tested" == "$_req_test" ]]; then
                    _found_in_tested=true
                    break
                fi
            done
            if [[ "$_found_in_tested" == false ]]; then
                echo "" >&2
                echo "BLOCKED: test gate — not all required tests were run. Missing: ${_req_test}" >&2
                echo "" >&2
                echo "  Re-run record-test-status.sh or use /dso:commit to re-record test status." >&2
                echo "" >&2
                exit 1
            fi
        done
    fi
fi

# ── All checks passed → allow commit ──────────────────────────────────────────
exit 0
