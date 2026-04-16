#!/usr/bin/env bash
# tests/scripts/test-check-skill-refs.sh
# TDD tests for check-skill-refs.sh — detects unqualified DSO skill references.
#
# Tests:
#  (a) test_exit_nonzero_on_unqualified_ref  — temp file with /sprint → exit != 0
#  (b) test_exit_zero_on_clean              — temp file with no skill refs → exit 0
#  (c) test_url_not_flagged                 — https://example.com/sprint → exit 0
#  (d) test_already_qualified_not_flagged   — /dso:sprint → exit 0
#  (e) test_hyphenated_not_flagged          — /review-gate → exit 0
#
# Usage: bash tests/scripts/test-check-skill-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/check-skill-refs.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-skill-refs.sh ==="

# ── test_exit_nonzero_on_unqualified_ref ──────────────────────────────────────
# (a) A file containing /sprint (unqualified) should cause exit != 0
test_exit_nonzero_on_unqualified_ref() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/test-doc.md" << 'EOF'
# Test document

Use /sprint to run the sprint workflow.
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/test-doc.md" 2>&1 || _exit=$?
    assert_ne "test_exit_nonzero_on_unqualified_ref: exit != 0 for /sprint" "0" "$_exit"
    assert_pass_if_clean "test_exit_nonzero_on_unqualified_ref"
}

# ── test_exit_zero_on_clean ───────────────────────────────────────────────────
# (b) A file with no skill references should exit 0
test_exit_zero_on_clean() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/clean-doc.md" << 'EOF'
# Clean document

This document has no skill references at all.
Just some normal content here.
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/clean-doc.md" 2>&1 || _exit=$?
    assert_eq "test_exit_zero_on_clean: exit 0 for clean file" "0" "$_exit"
    assert_pass_if_clean "test_exit_zero_on_clean"
}

# ── test_url_not_flagged ──────────────────────────────────────────────────────
# (c) A URL containing a skill name (https://example.com/sprint) should NOT be flagged
test_url_not_flagged() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/url-doc.md" << 'EOF'
# URL document

See https://example.com/sprint for more info.
Also http://docs.example.com/commit for commit docs.
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/url-doc.md" 2>&1 || _exit=$?
    assert_eq "test_url_not_flagged: exit 0 for URL references" "0" "$_exit"
    assert_pass_if_clean "test_url_not_flagged"
}

# ── test_already_qualified_not_flagged ────────────────────────────────────────
# (d) Already-qualified /dso:sprint should NOT be flagged
test_already_qualified_not_flagged() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/qualified-doc.md" << 'EOF'
# Qualified references document

Use /dso:sprint to run epics end-to-end.
Use /dso:commit to commit changes.
Use /dso:review for code review.
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/qualified-doc.md" 2>&1 || _exit=$?
    assert_eq "test_already_qualified_not_flagged: exit 0 for /dso:sprint" "0" "$_exit"
    assert_pass_if_clean "test_already_qualified_not_flagged"
}

# ── test_hyphenated_not_flagged ───────────────────────────────────────────────
# (e) /review-gate (not a DSO skill name) should NOT be flagged
test_hyphenated_not_flagged() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/hyphenated-doc.md" << 'EOF'
# Hyphenated references document

The /review-gate is a pre-commit hook that enforces review.
The /pre-commit-hook runs automatically.
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/hyphenated-doc.md" 2>&1 || _exit=$?
    assert_eq "test_hyphenated_not_flagged: exit 0 for /review-gate" "0" "$_exit"
    assert_pass_if_clean "test_hyphenated_not_flagged"
}

# ── test_code_span_not_flagged ────────────────────────────────────────────────
# (f) A skill name wrapped in backtick code spans should NOT be flagged.
#     e.g. "like `/sprint` are invalid" — the /sprint is illustrative, not a real invocation.
#     Bug 0377-deee: perl scanner did not strip backtick spans before matching.
test_code_span_not_flagged() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/code-span-doc.md" << 'EOF'
Short-form references like `/sprint` are invalid — use `/dso:sprint` instead.
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/code-span-doc.md" 2>&1 || _exit=$?
    assert_eq "test_code_span_not_flagged: exit 0 for backtick-wrapped /sprint" "0" "$_exit"
    assert_pass_if_clean "test_code_span_not_flagged"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_exit_nonzero_on_unqualified_ref
test_exit_zero_on_clean
test_url_not_flagged
test_already_qualified_not_flagged
test_hyphenated_not_flagged
test_code_span_not_flagged

print_summary
