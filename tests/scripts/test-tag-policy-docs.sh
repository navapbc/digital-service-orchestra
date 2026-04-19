#!/usr/bin/env bash
# tests/scripts/test-tag-policy-docs.sh
# Structural boundary tests for Tag Policy documentation.
# Rule 5: tests the structural boundary of non-executable instruction files.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PASS=0; FAIL=0

run_test() {
    local name="$1"
    echo ""
    echo "--- $name ---"
    if "$name"; then
        (( ++PASS ))
        echo "$name ... PASS"
    else
        (( ++FAIL ))
        echo "FAIL: $name"
    fi
}

test_arch_doc_has_tag_policy_section() {
    local file="$REPO_ROOT/plugins/dso/docs/ticket-system-v3-architecture.md"
    grep -q "Tag Policy" "$file"
}

test_arch_doc_tag_policy_covers_guarded_tags() {
    local file="$REPO_ROOT/plugins/dso/docs/ticket-system-v3-architecture.md"
    grep -q "brainstorm:complete" "$file"
}

test_arch_doc_tag_policy_covers_writer_taxonomy() {
    local file="$REPO_ROOT/plugins/dso/docs/ticket-system-v3-architecture.md"
    grep -q "additive" "$file"
}

test_scrutiny_tag_doc_has_policy_crossref() {
    local file="$REPO_ROOT/plugins/dso/docs/contracts/scrutiny-pending-tag.md"
    grep -q "ticket-system-v3-architecture" "$file"
}

test_interaction_deferred_doc_has_policy_crossref() {
    local file="$REPO_ROOT/plugins/dso/docs/contracts/interaction-deferred-tag.md"
    grep -q "ticket-system-v3-architecture" "$file"
}

test_claude_md_has_ticket_tag_commands() {
    local file="$REPO_ROOT/CLAUDE.md"
    grep -q "ticket tag" "$file" && grep -q "ticket untag" "$file"
}

run_test test_arch_doc_has_tag_policy_section
run_test test_arch_doc_tag_policy_covers_guarded_tags
run_test test_arch_doc_tag_policy_covers_writer_taxonomy
run_test test_scrutiny_tag_doc_has_policy_crossref
run_test test_interaction_deferred_doc_has_policy_crossref
run_test test_claude_md_has_ticket_tag_commands

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]]
