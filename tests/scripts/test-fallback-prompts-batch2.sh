#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-fallback-prompts-batch2.sh
# Verify fallback prompt templates: test_fix_e_to_e, test_write, complex_debug.
#
# Usage: bash lockpick-workflow/tests/scripts/test-fallback-prompts-batch2.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FALLBACK_DIR="$REPO_ROOT/lockpick-workflow/prompts/fallback"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-fallback-prompts-batch2.sh ==="

PROMPTS=(test_fix_e_to_e test_write complex_debug)

# ── test_files_exist ─────────────────────────────────────────────────────────
echo ""
echo "--- file existence ---"
for prompt in "${PROMPTS[@]}"; do
    target="$FALLBACK_DIR/$prompt.md"
    if [ -f "$target" ]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "file_exists: $prompt.md" "exists" "$actual"
done

# ── test_universal_context_placeholder ────────────────────────────────────────
echo ""
echo "--- universal {context} placeholder ---"
for prompt in "${PROMPTS[@]}"; do
    target="$FALLBACK_DIR/$prompt.md"
    if [ -f "$target" ] && grep -q '{context}' "$target"; then
        actual="has_context"
    else
        actual="missing_context"
    fi
    assert_eq "universal_context: $prompt.md" "has_context" "$actual"
done

# ── test_test_fix_e_to_e_placeholders ─────────────────────────────────────────
echo ""
echo "--- test_fix_e_to_e category placeholders ---"
target="$FALLBACK_DIR/test_fix_e_to_e.md"
for placeholder in '{test_command}' '{exit_code}' '{stderr_tail}' '{changed_files}'; do
    if [ -f "$target" ] && grep -q "$placeholder" "$target"; then
        actual="found"
    else
        actual="missing"
    fi
    assert_eq "test_fix_e_to_e: $placeholder" "found" "$actual"
done

# ── test_test_write_placeholders ──────────────────────────────────────────────
echo ""
echo "--- test_write category placeholders ---"
target="$FALLBACK_DIR/test_write.md"
for placeholder in '{test_target}' '{test_type}' '{source_files}'; do
    if [ -f "$target" ] && grep -q "$placeholder" "$target"; then
        actual="found"
    else
        actual="missing"
    fi
    assert_eq "test_write: $placeholder" "found" "$actual"
done

# ── test_complex_debug_placeholders ───────────────────────────────────────────
echo ""
echo "--- complex_debug category placeholders ---"
target="$FALLBACK_DIR/complex_debug.md"
for placeholder in '{error_output}' '{stack_trace}' '{affected_files}' '{related_errors}' '{recent_changes}'; do
    if [ -f "$target" ] && grep -q "$placeholder" "$target"; then
        actual="found"
    else
        actual="missing"
    fi
    assert_eq "complex_debug: $placeholder" "found" "$actual"
done

# ── test_verify_section ───────────────────────────────────────────────────────
echo ""
echo "--- Verify: section ---"
for prompt in "${PROMPTS[@]}"; do
    target="$FALLBACK_DIR/$prompt.md"
    if [ -f "$target" ] && grep -q 'Verify:' "$target"; then
        actual="has_verify"
    else
        actual="missing_verify"
    fi
    assert_eq "verify_section: $prompt.md" "has_verify" "$actual"
done

# ── test_minimum_line_count ───────────────────────────────────────────────────
echo ""
echo "--- minimum 10 lines ---"
for prompt in "${PROMPTS[@]}"; do
    target="$FALLBACK_DIR/$prompt.md"
    if [ -f "$target" ]; then
        line_count=$(wc -l < "$target" | tr -d ' ')
        if [ "$line_count" -ge 10 ]; then
            actual="sufficient"
        else
            actual="too_short ($line_count lines)"
        fi
    else
        actual="file_missing"
    fi
    assert_eq "min_lines: $prompt.md >= 10" "sufficient" "$actual"
done

print_summary
