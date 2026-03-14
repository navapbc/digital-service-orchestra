#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-example-doc-templates.sh
# Verifies that example documentation templates exist under
# lockpick-workflow/templates/ with expected section headers and
# contain no lockpick-specific terms.
#
# Usage:
#   bash lockpick-workflow/tests/scripts/test-example-doc-templates.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

TEMPLATES="$REPO_ROOT/lockpick-workflow/templates"

# --- KNOWN-ISSUES.example.md ---

ki_file="$TEMPLATES/KNOWN-ISSUES.example.md"

if [[ -f "$ki_file" ]]; then
    assert_eq "known_issues_exists" "exists" "exists"
else
    assert_eq "known_issues_exists" "exists" "missing"
fi

if grep -q 'Index by Category' "$ki_file" 2>/dev/null; then
    assert_eq "known_issues_has_index_by_category" "found" "found"
else
    assert_eq "known_issues_has_index_by_category" "found" "missing"
fi

if grep -q 'Quick Reference' "$ki_file" 2>/dev/null; then
    assert_eq "known_issues_has_quick_reference" "found" "found"
else
    assert_eq "known_issues_has_quick_reference" "found" "missing"
fi

if grep -qi 'adapt\|customize\|your project\|placeholder' "$ki_file" 2>/dev/null; then
    assert_eq "known_issues_has_adaptation_guidance" "found" "found"
else
    assert_eq "known_issues_has_adaptation_guidance" "found" "missing"
fi

# --- DOCUMENTATION-GUIDE.example.md ---

dg_file="$TEMPLATES/DOCUMENTATION-GUIDE.example.md"

if [[ -f "$dg_file" ]]; then
    assert_eq "doc_guide_exists" "exists" "exists"
else
    assert_eq "doc_guide_exists" "exists" "missing"
fi

if grep -q 'Documentation Target Priority' "$dg_file" 2>/dev/null; then
    assert_eq "doc_guide_has_target_priority" "found" "found"
else
    assert_eq "doc_guide_has_target_priority" "found" "missing"
fi

if grep -q 'Decision Test' "$dg_file" 2>/dev/null; then
    assert_eq "doc_guide_has_decision_test" "found" "found"
else
    assert_eq "doc_guide_has_decision_test" "found" "missing"
fi

if grep -qi 'adapt\|customize\|your project\|placeholder' "$dg_file" 2>/dev/null; then
    assert_eq "doc_guide_has_adaptation_guidance" "found" "found"
else
    assert_eq "doc_guide_has_adaptation_guidance" "found" "missing"
fi

# --- No lockpick-specific terms ---

lockpick_terms='PipelineLLMClientFactory\|PostPipelineProcessor\|RegoGenerationAgent\|lockpick\|Lockpick'

for file in "$ki_file" "$dg_file"; do
    basename_file="$(basename "$file")"
    if [[ ! -f "$file" ]]; then
        assert_eq "no_lockpick_terms_${basename_file}" "clean" "file_missing"
    elif grep -n "$lockpick_terms" "$file" >/dev/null 2>&1; then
        assert_eq "no_lockpick_terms_${basename_file}" "clean" "contains_lockpick_terms"
    else
        assert_eq "no_lockpick_terms_${basename_file}" "clean" "clean"
    fi
done

print_summary
