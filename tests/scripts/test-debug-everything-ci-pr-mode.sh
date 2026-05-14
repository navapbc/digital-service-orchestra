#!/usr/bin/env bash
# tests/scripts/test-debug-everything-ci-pr-mode.sh
# Structural metadata validation of debug-everything SKILL.md ci-pr mode behaviors.
#
# Verifies that the debug-everything skill includes ci-pr mode initialization:
#   1. Phase A stale .debug-active cleanup
#   2. Phase B Step 1 reads merge.strategy config
#   3. Phase B Step 1 opens draft PR with DRAFT_PR_TITLE_PREFIX=Debug:
#   4. Phase B Step 1 creates .debug-active marker
#   5. Phase B Step 1 emits local mode log when merge.strategy is not pr
#   6. Phase K removes .debug-active marker
#   7. Schema doc exists at plugins/dso/skills/debug-everything/docs/debug-active-marker-schema.md
#   8. Schema doc contains debug-session-id field
#   9. Schema doc contains schema_version field
#
# Test status:
#   All 9 tests are RED — SKILL.md and schema doc not yet updated.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-ci-pr-mode.sh

set -euo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"
SCHEMA_DOC="$DSO_PLUGIN_DIR/skills/debug-everything/docs/debug-active-marker-schema.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-ci-pr-mode.sh ==="

# ============================================================
# test_phase_a_stale_debug_active_cleanup
# SKILL.md Phase A must reference removing a stale .debug-active marker.
# Contract identifier: 'debug-active' near 'stale' or cleanup context
# ============================================================
test_phase_a_stale_debug_active_cleanup() {
    local result="missing"
    if grep -qE '(stale.*debug.active|debug.active.*stale|remove.*debug.active|debug.active.*cleanup)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_a_stale_debug_active_cleanup: SKILL.md Phase A references stale .debug-active cleanup" "found" "$result"
}

# ============================================================
# test_phase_b_step1_reads_merge_strategy
# SKILL.md Phase B Step 1 must reference reading merge.strategy config.
# Contract identifier: 'merge.strategy'
# ============================================================
test_phase_b_step1_reads_merge_strategy() {
    local result="missing"
    if grep -qE 'merge\.strategy' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_b_step1_reads_merge_strategy: SKILL.md references merge.strategy config key" "found" "$result"
}

# ============================================================
# test_phase_b_step1_opens_draft_pr_with_debug_prefix
# SKILL.md Phase B Step 1 must reference create-sprint-draft-pr.sh with DRAFT_PR_TITLE_PREFIX=Debug:
# Contract identifier: 'DRAFT_PR_TITLE_PREFIX=Debug:'
# ============================================================
test_phase_b_step1_opens_draft_pr_with_debug_prefix() {
    local result="missing"
    if grep -qE 'DRAFT_PR_TITLE_PREFIX=Debug:' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_b_step1_opens_draft_pr_with_debug_prefix: SKILL.md references DRAFT_PR_TITLE_PREFIX=Debug:" "found" "$result"
}

# ============================================================
# test_phase_b_step1_creates_debug_active_marker
# SKILL.md Phase B Step 1 must reference creating .debug-active marker.
# Contract identifier: '.debug-active' near creation context
# ============================================================
test_phase_b_step1_creates_debug_active_marker() {
    local result="missing"
    if grep -qE '(touch.*debug.active|debug.active.*create|create.*debug.active|\.debug-active.*marker)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_b_step1_creates_debug_active_marker: SKILL.md references .debug-active marker creation" "found" "$result"
}

# ============================================================
# test_phase_b_step1_local_mode_emits_log
# SKILL.md Phase B Step 1 must reference merge.strategy=direct or local mode log.
# Contract identifier: 'local mode' or 'merge.strategy=direct'
# ============================================================
test_phase_b_step1_local_mode_emits_log() {
    local result="missing"
    if grep -qE '(local mode|merge\.strategy=direct|merge\.strategy.*direct)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_b_step1_local_mode_emits_log: SKILL.md references local mode or merge.strategy=direct" "found" "$result"
}

# ============================================================
# test_phase_k_removes_debug_active_marker
# SKILL.md Phase K must reference removing .debug-active marker.
# Contract identifier: '.debug-active' near 'rm' or removal context in Phase K
# ============================================================
test_phase_k_removes_debug_active_marker() {
    local result="missing"
    if grep -qE '(rm.*debug.active|debug.active.*rm|remove.*debug.active|debug.active.*remove|debug.active.*Phase K|Phase K.*debug.active)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_k_removes_debug_active_marker: SKILL.md Phase K references .debug-active removal" "found" "$result"
}

# ============================================================
# test_debug_active_marker_schema_doc_exists
# Schema doc must exist at debug-everything/docs/debug-active-marker-schema.md
# ============================================================
test_debug_active_marker_schema_doc_exists() {
    local result="missing"
    if [[ -f "$SCHEMA_DOC" && -s "$SCHEMA_DOC" ]]; then
        result="found"
    fi
    assert_eq "test_debug_active_marker_schema_doc_exists: schema doc exists and is non-empty" "found" "$result"
}

# ============================================================
# test_debug_active_marker_schema_has_session_id_field
# Schema doc must contain 'debug-session-id' field definition.
# Contract identifier: 'debug-session-id'
# ============================================================
test_debug_active_marker_schema_has_session_id_field() {
    local result="missing"
    if grep -q 'debug-session-id' "$SCHEMA_DOC" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_debug_active_marker_schema_has_session_id_field: schema doc contains debug-session-id field" "found" "$result"
}

# ============================================================
# test_debug_active_marker_schema_has_schema_version_field
# Schema doc must contain 'schema_version' field definition.
# Contract identifier: 'schema_version'
# ============================================================
test_debug_active_marker_schema_has_schema_version_field() {
    local result="missing"
    if grep -q 'schema_version' "$SCHEMA_DOC" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_debug_active_marker_schema_has_schema_version_field: schema doc contains schema_version field" "found" "$result"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

echo ""
echo "--- test_phase_a_stale_debug_active_cleanup ---"
test_phase_a_stale_debug_active_cleanup

echo ""
echo "--- test_phase_b_step1_reads_merge_strategy ---"
test_phase_b_step1_reads_merge_strategy

echo ""
echo "--- test_phase_b_step1_opens_draft_pr_with_debug_prefix ---"
test_phase_b_step1_opens_draft_pr_with_debug_prefix

echo ""
echo "--- test_phase_b_step1_creates_debug_active_marker ---"
test_phase_b_step1_creates_debug_active_marker

echo ""
echo "--- test_phase_b_step1_local_mode_emits_log ---"
test_phase_b_step1_local_mode_emits_log

echo ""
echo "--- test_phase_k_removes_debug_active_marker ---"
test_phase_k_removes_debug_active_marker

echo ""
echo "--- test_debug_active_marker_schema_doc_exists ---"
test_debug_active_marker_schema_doc_exists

echo ""
echo "--- test_debug_active_marker_schema_has_session_id_field ---"
test_debug_active_marker_schema_has_session_id_field

echo ""
echo "--- test_debug_active_marker_schema_has_schema_version_field ---"
test_debug_active_marker_schema_has_schema_version_field

echo ""
print_summary
