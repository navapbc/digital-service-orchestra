#!/usr/bin/env bash
# tests/scripts/test-tag-policy-docs.sh
# Tests: assert Tag Policy section exists in architecture doc, cross-references
# are present in contract docs, and CLAUDE.md Quick Reference has tag/untag entries.
#
# Usage: bash tests/scripts/test-tag-policy-docs.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
ARCH_DOC="$REPO_ROOT/plugins/dso/docs/ticket-system-v3-architecture.md"
SCRUTINY_CONTRACT="$REPO_ROOT/plugins/dso/docs/contracts/scrutiny-pending-tag.md"
INTERACTION_CONTRACT="$REPO_ROOT/plugins/dso/docs/contracts/interaction-deferred-tag.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-tag-policy-docs.sh ==="
echo ""

arch_content="$(cat "$ARCH_DOC")"
scrutiny_content="$(cat "$SCRUTINY_CONTRACT")"
interaction_content="$(cat "$INTERACTION_CONTRACT")"
claude_content="$(cat "$CLAUDE_MD")"

# ── test_architecture_doc_has_tag_policy_section ─────────────────────────────
# ticket-system-v3-architecture.md must contain a "## Tag Policy" heading so
# agents and practitioners have a single authoritative reference for tag rules.
assert_contains \
    "test_architecture_doc_has_tag_policy_section: architecture doc has Tag Policy heading" \
    "## Tag Policy" \
    "$arch_content"
echo ""

# ── test_architecture_doc_tag_policy_has_guarded_tags_table ──────────────────
# The Tag Policy section must include a Guarded Tags subsection with a table.
assert_contains \
    "test_architecture_doc_tag_policy_has_guarded_tags_table: Tag Policy section has Guarded Tags subsection" \
    "### Guarded Tags" \
    "$arch_content"
echo ""

# ── test_architecture_doc_tag_policy_writer_taxonomy ─────────────────────────
# The Tag Policy section must document additive vs full-replacement write taxonomy.
assert_contains \
    "test_architecture_doc_tag_policy_writer_taxonomy: Tag Policy section has Writer Taxonomy" \
    "### Writer Taxonomy" \
    "$arch_content"
echo ""

# ── test_scrutiny_contract_has_tag_policy_crossref ───────────────────────────
# scrutiny-pending-tag.md must cross-reference the Tag Policy section so
# readers can navigate from individual contract docs to the meta-policy.
assert_contains \
    "test_scrutiny_contract_has_tag_policy_crossref: scrutiny-pending-tag.md links to Tag Policy" \
    "ticket-system-v3-architecture.md#tag-policy" \
    "$scrutiny_content"
echo ""

# ── test_interaction_contract_has_tag_policy_crossref ────────────────────────
# interaction-deferred-tag.md must cross-reference the Tag Policy section.
assert_contains \
    "test_interaction_contract_has_tag_policy_crossref: interaction-deferred-tag.md links to Tag Policy" \
    "ticket-system-v3-architecture.md#tag-policy" \
    "$interaction_content"
echo ""

# ── test_claude_md_quick_ref_has_tag_and_untag ───────────────────────────────
# CLAUDE.md Quick Reference table must include entries for ticket tag and untag
# commands so agents and practitioners can discover them without reading the
# full CLI reference.
assert_contains \
    "test_claude_md_quick_ref_has_tag_and_untag: CLAUDE.md Quick Reference has ticket tag entry" \
    "ticket tag" \
    "$claude_content"
assert_contains \
    "test_claude_md_quick_ref_has_tag_and_untag: CLAUDE.md Quick Reference has ticket untag entry" \
    "ticket untag" \
    "$claude_content"
echo ""

print_summary
