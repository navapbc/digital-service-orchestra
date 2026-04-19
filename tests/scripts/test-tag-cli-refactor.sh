#!/usr/bin/env bash
# tests/scripts/test-tag-cli-refactor.sh
# Structural boundary tests verifying instruction files use ticket tag/untag CLI
# instead of open-coded tag-merge logic.
#
# RED tests (5): FAIL until task 7cdb-e8df refactors instruction files
# GREEN test (1): PASS immediately — dispatcher routing added in task 386e-c363
#
# Usage: bash tests/scripts/test-tag-cli-refactor.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-tag-cli-refactor.sh ==="
echo ""

# ── test_brainstorm_skill_no_ticket_edit_tags ────────────────────────────────
# After refactor, brainstorm/SKILL.md must call `ticket tag` instead of
# open-coding read-merge-write tag logic.
# RED: `ticket tag` not yet present in brainstorm/SKILL.md (added by 7cdb-e8df)
_snapshot_fail
_brainstorm_skill="$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"
if grep -q "ticket tag" "$_brainstorm_skill" 2>/dev/null; then
    _brainstorm_has_tag="yes"
else
    _brainstorm_has_tag="no"
fi
assert_eq \
    "test_brainstorm_skill_no_ticket_edit_tags: brainstorm/SKILL.md calls ticket tag" \
    "yes" \
    "$_brainstorm_has_tag"
assert_pass_if_clean "test_brainstorm_skill_no_ticket_edit_tags"
echo ""

# ── test_roadmap_skill_no_ticket_edit_tags ───────────────────────────────────
# After refactor, roadmap/SKILL.md must call `ticket tag` for SCRUTINY_OPT_IN=false
# path instead of open-coding full-replacement tag writes.
# RED: `ticket tag` not yet present in roadmap/SKILL.md (added by 7cdb-e8df)
_snapshot_fail
_roadmap_skill="$REPO_ROOT/plugins/dso/skills/roadmap/SKILL.md"
if grep -q "ticket tag" "$_roadmap_skill" 2>/dev/null; then
    _roadmap_has_tag="yes"
else
    _roadmap_has_tag="no"
fi
assert_eq \
    "test_roadmap_skill_no_ticket_edit_tags: roadmap/SKILL.md calls ticket tag" \
    "yes" \
    "$_roadmap_has_tag"
assert_pass_if_clean "test_roadmap_skill_no_ticket_edit_tags"
echo ""

# ── test_ui_designer_dispatch_no_ticket_edit_tags ────────────────────────────
# After refactor, ui-designer-dispatch-protocol.md must call `ticket tag` instead
# of open-coding tag-merge logic.
# RED: `ticket tag` not yet present in ui-designer-dispatch-protocol.md (added by 7cdb-e8df)
_snapshot_fail
_ui_dispatch="$REPO_ROOT/plugins/dso/skills/preplanning/prompts/ui-designer-dispatch-protocol.md"
if grep -q "ticket tag" "$_ui_dispatch" 2>/dev/null; then
    _ui_has_tag="yes"
else
    _ui_has_tag="no"
fi
assert_eq \
    "test_ui_designer_dispatch_no_ticket_edit_tags: ui-designer-dispatch-protocol.md calls ticket tag" \
    "yes" \
    "$_ui_has_tag"
assert_pass_if_clean "test_ui_designer_dispatch_no_ticket_edit_tags"
echo ""

# ── test_interaction_deferred_contract_updated ───────────────────────────────
# After refactor, interaction-deferred-tag.md must reference `ticket untag`
# in its contract example (step 2.27 brainstorm path).
# RED: `ticket untag` not yet present in interaction-deferred-tag.md (added by 7cdb-e8df)
_snapshot_fail
_deferred_contract="$REPO_ROOT/plugins/dso/docs/contracts/interaction-deferred-tag.md"
if grep -q "ticket untag" "$_deferred_contract" 2>/dev/null; then
    _contract_has_untag="yes"
else
    _contract_has_untag="no"
fi
assert_eq \
    "test_interaction_deferred_contract_updated: interaction-deferred-tag.md references ticket untag" \
    "yes" \
    "$_contract_has_untag"
assert_pass_if_clean "test_interaction_deferred_contract_updated"
echo ""

# ── test_preplanning_skill_table_updated ─────────────────────────────────────
# After refactor, preplanning/SKILL.md must call `ticket tag` instead of
# open-coding read-merge-write tag logic.
# RED: `ticket tag` not yet present in preplanning/SKILL.md (added by 7cdb-e8df)
_snapshot_fail
_preplanning_skill="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"
if grep -q "ticket tag" "$_preplanning_skill" 2>/dev/null; then
    _preplanning_has_tag="yes"
else
    _preplanning_has_tag="no"
fi
assert_eq \
    "test_preplanning_skill_table_updated: preplanning/SKILL.md calls ticket tag" \
    "yes" \
    "$_preplanning_has_tag"
assert_pass_if_clean "test_preplanning_skill_table_updated"
echo ""

# ── test_ticket_tag_dispatcher_smoke ─────────────────────────────────────────
# Smoke test: ticket dispatcher routes `tag` and `untag` subcommands.
# GREEN: dispatcher entries added by task 386e-c363.
_snapshot_fail
_ticket_script="$REPO_ROOT/plugins/dso/scripts/ticket"
if grep -q "tag)" "$_ticket_script" 2>/dev/null && grep -q "untag)" "$_ticket_script" 2>/dev/null; then
    _dispatcher_has_routes="yes"
else
    _dispatcher_has_routes="no"
fi
assert_eq \
    "test_ticket_tag_dispatcher_smoke: ticket dispatcher routes tag and untag subcommands" \
    "yes" \
    "$_dispatcher_has_routes"
assert_pass_if_clean "test_ticket_tag_dispatcher_smoke"
echo ""

print_summary
