#!/usr/bin/env bash
# tests/scripts/test-example-doc-templates.sh
# Verifies that example documentation templates exist under
# templates/ with expected section headers and
# contain no lockpick-specific terms.
#
# Usage:
#   bash tests/scripts/test-example-doc-templates.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

TEMPLATES="$PLUGIN_ROOT/plugins/dso/templates"

# --- KNOWN-ISSUES.example.md has been removed (superseded by plugins/dso/docs/templates/KNOWN-ISSUES.md) ---

old_ki_file="$TEMPLATES/KNOWN-ISSUES.example.md"

if [[ ! -f "$old_ki_file" ]]; then
    assert_eq "old_known_issues_example_removed" "removed" "removed"
else
    assert_eq "old_known_issues_example_removed" "removed" "still_exists"
fi

# --- New canonical template exists at plugins/dso/docs/templates/KNOWN-ISSUES.md ---

new_ki_file="$PLUGIN_ROOT/plugins/dso/docs/templates/KNOWN-ISSUES.md"

if [[ -f "$new_ki_file" ]]; then
    assert_eq "new_known_issues_template_exists" "exists" "exists"
else
    assert_eq "new_known_issues_template_exists" "exists" "missing"
fi

# --- dso-setup.sh references new template path ---

setup_script="$PLUGIN_ROOT/plugins/dso/scripts/onboarding/dso-setup.sh"

if grep -q 'docs/templates/KNOWN-ISSUES.md' "$setup_script" 2>/dev/null; then
    assert_eq "dso_setup_references_new_template" "found" "found"
else
    assert_eq "dso_setup_references_new_template" "found" "missing"
fi

# --- CLAUDE.md contains pointer to KNOWN-ISSUES.md ---

claude_md="$REPO_ROOT/CLAUDE.md"

if grep -q 'See .claude/docs/KNOWN-ISSUES.md' "$claude_md" 2>/dev/null; then
    assert_eq "claude_md_has_known_issues_pointer" "found" "found"
else
    assert_eq "claude_md_has_known_issues_pointer" "found" "missing"
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

for file in "$new_ki_file" "$dg_file"; do
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
