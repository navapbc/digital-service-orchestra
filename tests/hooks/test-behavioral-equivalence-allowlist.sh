#!/usr/bin/env bash
# tests/hooks/test-behavioral-equivalence-allowlist.sh
# Behavioral equivalence test: verifies that compute-diff-hash.sh and
# skip-review-check.sh produce IDENTICAL classification results for every
# pattern group in the shared review-gate-allowlist.conf.
#
# This is the integration/E2E test for the shared-allowlist epic. It ensures
# both consumers agree on which files are non-reviewable, preventing the class
# of stale-hash and false-block bugs the epic aims to eliminate.
#
# Tests:
#   test_tickets_non_reviewable_both_consumers
#   test_sync_state_non_reviewable_both_consumers
#   test_checkpoint_sentinel_non_reviewable_both_consumers
#   test_images_non_reviewable_both_consumers
#   test_binary_docs_non_reviewable_both_consumers
#   test_docs_non_reviewable_both_consumers
#   test_claude_docs_non_reviewable_both_consumers
#   test_claude_session_logs_non_reviewable_both_consumers
#   test_python_file_reviewable_both_consumers
#   test_shell_script_reviewable_both_consumers
#   test_javascript_file_reviewable_both_consumers

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

COMPUTE_DIFF_HASH="$PLUGIN_ROOT/hooks/compute-diff-hash.sh"
SKIP_REVIEW_CHECK="$PLUGIN_ROOT/scripts/skip-review-check.sh"
ALLOWLIST="$PLUGIN_ROOT/hooks/lib/review-gate-allowlist.conf"

# --- Prerequisite checks ---
if [[ ! -f "$COMPUTE_DIFF_HASH" ]]; then
    echo "SKIP: compute-diff-hash.sh not found"
    exit 0
fi
if [[ ! -f "$SKIP_REVIEW_CHECK" ]]; then
    echo "SKIP: skip-review-check.sh not found"
    exit 0
fi
if [[ ! -f "$ALLOWLIST" ]]; then
    echo "SKIP: review-gate-allowlist.conf not found"
    exit 0
fi

# --- Create isolated temp git repo ---
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cd "$TMPDIR_TEST"
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"

# Create initial commit so HEAD exists
echo "init" > README.md
git add README.md
git commit -q -m "init"

# --- Helper: check if skip-review-check classifies a file as non-reviewable ---
# Returns 0 if non-reviewable (skip review), 1 if reviewable (needs review)
skip_review_classifies_non_reviewable() {
    local file="$1"
    echo "$file" | bash "$SKIP_REVIEW_CHECK" 2>/dev/null
    return $?
}

# --- Helper: check if compute-diff-hash excludes a file ---
# Creates the file, stages it, computes hash with and without it.
# If hashes are equal, the file is excluded (non-reviewable). Returns 0.
# If hashes differ, the file is included (reviewable). Returns 1.
compute_diff_hash_excludes_file() {
    local filepath="$1"
    local content="${2:-test content}"

    # Get baseline hash (clean state)
    local hash_before
    hash_before=$(bash "$COMPUTE_DIFF_HASH" 2>/dev/null)

    # Create the file as an unstaged change
    local dir
    dir=$(dirname "$filepath")
    [[ "$dir" != "." ]] && mkdir -p "$dir"
    echo "$content" > "$filepath"

    # Get hash with the file present (unstaged)
    local hash_after
    hash_after=$(bash "$COMPUTE_DIFF_HASH" 2>/dev/null)

    # Clean up
    rm -f "$filepath"
    # Remove empty parent dirs
    [[ "$dir" != "." ]] && rmdir -p "$dir" 2>/dev/null || true

    if [[ "$hash_before" == "$hash_after" ]]; then
        return 0  # excluded (non-reviewable)
    else
        return 1  # included (reviewable)
    fi
}

# ============================================================
# Pattern group 1: .tickets/**
# ============================================================
test_tickets_non_reviewable_both_consumers() {
    local file=".tickets/test-ticket.md"

    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "tickets: skip-review-check classifies as non-reviewable" "0" "$skip_rc"

    local hash_rc=0
    compute_diff_hash_excludes_file "$file" || hash_rc=$?
    assert_eq "tickets: compute-diff-hash excludes file" "0" "$hash_rc"

    # Both must agree
    assert_eq "tickets: both consumers agree (non-reviewable)" "$skip_rc" "$hash_rc"
}

# ============================================================
# Pattern group 2: .sync-state.json
# ============================================================
test_sync_state_non_reviewable_both_consumers() {
    local file=".sync-state.json"

    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "sync-state: skip-review-check classifies as non-reviewable" "0" "$skip_rc"

    local hash_rc=0
    compute_diff_hash_excludes_file "$file" '{"last_sync":"2026-01-01"}' || hash_rc=$?
    assert_eq "sync-state: compute-diff-hash excludes file" "0" "$hash_rc"

    assert_eq "sync-state: both consumers agree (non-reviewable)" "$skip_rc" "$hash_rc"
}

# ============================================================
# Pattern group 3: .checkpoint-needs-review
# NOTE: skip-review-check has a special override that makes
# .checkpoint-needs-review REQUIRE review (exit 1), while
# compute-diff-hash excludes it from the hash. This is by design:
# the checkpoint sentinel triggers review but doesn't affect the hash.
# We test that compute-diff-hash excludes it (the allowlist behavior).
# ============================================================
test_checkpoint_sentinel_non_reviewable_both_consumers() {
    local file=".checkpoint-needs-review"

    # compute-diff-hash should exclude this file (per allowlist)
    local hash_rc=0
    compute_diff_hash_excludes_file "$file" || hash_rc=$?
    assert_eq "checkpoint-sentinel: compute-diff-hash excludes file" "0" "$hash_rc"

    # skip-review-check has a special override: .checkpoint-needs-review always requires review
    # This is intentional behavior (see skip-review-check.sh line 87-89).
    # We verify the override exists and works as expected.
    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "checkpoint-sentinel: skip-review-check forces review (special override)" "1" "$skip_rc"
}

# ============================================================
# Pattern group 4: Images (*.png, *.jpg, *.jpeg, *.gif, *.svg, *.ico, *.webp)
# ============================================================
test_images_non_reviewable_both_consumers() {
    local -a image_files=("test-image.png" "photo.jpg" "icon.svg")

    for file in "${image_files[@]}"; do
        local skip_rc=0
        skip_review_classifies_non_reviewable "$file" || skip_rc=$?
        assert_eq "images($file): skip-review-check classifies as non-reviewable" "0" "$skip_rc"

        local hash_rc=0
        compute_diff_hash_excludes_file "$file" || hash_rc=$?
        assert_eq "images($file): compute-diff-hash excludes file" "0" "$hash_rc"

        assert_eq "images($file): both consumers agree (non-reviewable)" "$skip_rc" "$hash_rc"
    done
}

# ============================================================
# Pattern group 5: Binary documents (*.pdf, *.docx)
# ============================================================
test_binary_docs_non_reviewable_both_consumers() {
    local -a doc_files=("document.pdf" "report.docx")

    for file in "${doc_files[@]}"; do
        local skip_rc=0
        skip_review_classifies_non_reviewable "$file" || skip_rc=$?
        assert_eq "binary-docs($file): skip-review-check classifies as non-reviewable" "0" "$skip_rc"

        local hash_rc=0
        compute_diff_hash_excludes_file "$file" || hash_rc=$?
        assert_eq "binary-docs($file): compute-diff-hash excludes file" "0" "$hash_rc"

        assert_eq "binary-docs($file): both consumers agree (non-reviewable)" "$skip_rc" "$hash_rc"
    done
}

# ============================================================
# Pattern group 6: Non-agent documentation (docs/**)
# ============================================================
test_docs_non_reviewable_both_consumers() {
    local file="docs/architecture.md"

    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "docs: skip-review-check classifies as non-reviewable" "0" "$skip_rc"

    local hash_rc=0
    compute_diff_hash_excludes_file "$file" || hash_rc=$?
    assert_eq "docs: compute-diff-hash excludes file" "0" "$hash_rc"

    assert_eq "docs: both consumers agree (non-reviewable)" "$skip_rc" "$hash_rc"
}

# ============================================================
# Pattern group 7: .claude/docs/**
# ============================================================
test_claude_docs_non_reviewable_both_consumers() {
    local file=".claude/docs/KNOWN-ISSUES.md"

    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "claude-docs: skip-review-check classifies as non-reviewable" "0" "$skip_rc"

    local hash_rc=0
    compute_diff_hash_excludes_file "$file" || hash_rc=$?
    assert_eq "claude-docs: compute-diff-hash excludes file" "0" "$hash_rc"

    assert_eq "claude-docs: both consumers agree (non-reviewable)" "$skip_rc" "$hash_rc"
}

# ============================================================
# Pattern group 8: .claude/session-logs/**
# ============================================================
test_claude_session_logs_non_reviewable_both_consumers() {
    local file=".claude/session-logs/2026-03-15.log"

    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "session-logs: skip-review-check classifies as non-reviewable" "0" "$skip_rc"

    local hash_rc=0
    compute_diff_hash_excludes_file "$file" || hash_rc=$?
    assert_eq "session-logs: compute-diff-hash excludes file" "0" "$hash_rc"

    assert_eq "session-logs: both consumers agree (non-reviewable)" "$skip_rc" "$hash_rc"
}

# ============================================================
# Reviewable file 1: Python source code
# ============================================================
test_python_file_reviewable_both_consumers() {
    local file="src/main.py"

    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "python: skip-review-check classifies as reviewable" "1" "$skip_rc"

    local hash_rc=0
    compute_diff_hash_excludes_file "$file" "print('hello')" || hash_rc=$?
    assert_eq "python: compute-diff-hash includes file" "1" "$hash_rc"

    assert_eq "python: both consumers agree (reviewable)" "$skip_rc" "$hash_rc"
}

# ============================================================
# Reviewable file 2: Shell script
# ============================================================
test_shell_script_reviewable_both_consumers() {
    local file="scripts/deploy.sh"

    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "shell: skip-review-check classifies as reviewable" "1" "$skip_rc"

    local hash_rc=0
    compute_diff_hash_excludes_file "$file" "#!/bin/bash" || hash_rc=$?
    assert_eq "shell: compute-diff-hash includes file" "1" "$hash_rc"

    assert_eq "shell: both consumers agree (reviewable)" "$skip_rc" "$hash_rc"
}

# ============================================================
# Reviewable file 3: JavaScript source
# ============================================================
test_javascript_file_reviewable_both_consumers() {
    local file="app/frontend/index.js"

    local skip_rc=0
    skip_review_classifies_non_reviewable "$file" || skip_rc=$?
    assert_eq "javascript: skip-review-check classifies as reviewable" "1" "$skip_rc"

    local hash_rc=0
    compute_diff_hash_excludes_file "$file" "console.log('hello')" || hash_rc=$?
    assert_eq "javascript: compute-diff-hash includes file" "1" "$hash_rc"

    assert_eq "javascript: both consumers agree (reviewable)" "$skip_rc" "$hash_rc"
}

# --- Run all tests ---
test_tickets_non_reviewable_both_consumers
test_sync_state_non_reviewable_both_consumers
test_checkpoint_sentinel_non_reviewable_both_consumers
test_images_non_reviewable_both_consumers
test_binary_docs_non_reviewable_both_consumers
test_docs_non_reviewable_both_consumers
test_claude_docs_non_reviewable_both_consumers
test_claude_session_logs_non_reviewable_both_consumers
test_python_file_reviewable_both_consumers
test_shell_script_reviewable_both_consumers
test_javascript_file_reviewable_both_consumers

print_summary
