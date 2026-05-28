#!/usr/bin/env bash
# tests/scripts/test-migrate-design-notes.sh
# Behavioral tests for scripts/migrate-design-notes-to-design-md.sh
#
# Tests covered:
#   1. test_happy_path_migration         — migrates design-notes.md to DESIGN.md with YAML front-matter
#   2. test_greenfield_guard             — exits 0 without writing DESIGN.md when design-notes.md absent
#   3. test_idempotency                  — re-run is safe; no double-migration
#   4. test_tombstone_content            — design-notes.md becomes deprecation tombstone with marker
#   5. test_yaml_front_matter_structure  — DESIGN.md has --- name: ... --- front-matter
#   6. test_section_mapping              — Vision/User Archetypes/Visual Language → Overview; Anti-Patterns → Dos and Donts
#
# Usage: bash tests/scripts/test-migrate-design-notes.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions return non-zero on skip.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}"
MIGRATE_SCRIPT="$_PLUGIN_ROOT/scripts/migrate-design-notes-to-design-md.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-migrate-design-notes.sh ==="

# ── Suite-runner guard: skip when script does not exist ──────────────────────
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "SKIP: migrate-design-notes-to-design-md.sh not yet implemented — tests deferred"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Cleanup registry ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for _d in "${_CLEANUP_DIRS[@]}"; do
        rm -rf "$_d"
    done
}
trap _cleanup EXIT

# ── Helper: create a temp project dir with .claude/ structure ─────────────────
_make_target() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-migrate-design-notes.XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    mkdir -p "$tmp/.claude"
    echo "$tmp"
}

# ── Helper: write a sample design-notes.md ────────────────────────────────────
_write_design_notes() {
    local target="$1"
    cat > "$target/.claude/design-notes.md" <<'EOF'
# Acme Design System

## Vision

Create a modern, accessible design system for government services.

## User Archetypes

- The First-Time Applicant: needs clear guidance
- The Power User: needs efficiency

## Visual Language

Clean, high-contrast, USWDS-aligned.

## Anti-Patterns

- Never use red for decorative purposes
- Avoid nested modals
- Do not rely on color alone to convey meaning

## Color Palette

Primary: #005ea2
Secondary: #d83933

## Typography

Font: Public Sans, system-ui
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: migrate-design-notes-to-design-md.sh exists and is executable
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Test 1: script exists and is executable"
_snapshot_fail
if [ -f "$MIGRATE_SCRIPT" ]; then
    assert_eq "migrate-design-notes-to-design-md.sh exists" "exists" "exists"
    if [ -x "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate-design-notes-to-design-md.sh is executable" "executable" "executable"
    else
        assert_eq "migrate-design-notes-to-design-md.sh is executable" "executable" "not-executable"
    fi
else
    assert_eq "migrate-design-notes-to-design-md.sh exists" "exists" "missing"
fi
assert_pass_if_clean "test_script_exists_and_executable"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: greenfield guard — exits 0 without creating DESIGN.md when no design-notes.md
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Test 2: greenfield guard"
_snapshot_fail
if [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "test_greenfield_guard ... SKIP (script missing)"
else
    _target=$(_make_target)
    # No design-notes.md in this target
    exit_code=0
    bash "$MIGRATE_SCRIPT" --target "$_target" 2>&1 || exit_code=$?
    assert_eq "greenfield guard: exits 0" "0" "$exit_code"
    design_md_exists="no"
    [ -f "$_target/DESIGN.md" ] && design_md_exists="yes"
    assert_eq "greenfield guard: DESIGN.md not created" "no" "$design_md_exists"
fi
assert_pass_if_clean "test_greenfield_guard"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: happy path — DESIGN.md is created from design-notes.md
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Test 3: happy path migration"
_snapshot_fail
if [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "test_happy_path_migration ... SKIP (script missing)"
else
    _target=$(_make_target)
    _write_design_notes "$_target"
    exit_code=0
    bash "$MIGRATE_SCRIPT" --target "$_target" 2>&1 || exit_code=$?
    assert_eq "happy path: exits 0" "0" "$exit_code"
    design_md_exists="no"
    [ -f "$_target/DESIGN.md" ] && design_md_exists="yes"
    assert_eq "happy path: DESIGN.md created" "yes" "$design_md_exists"
fi
assert_pass_if_clean "test_happy_path_migration"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: tombstone content — design-notes.md contains migration marker after migration
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Test 4: tombstone content"
_snapshot_fail
if [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "test_tombstone_content ... SKIP (script missing)"
else
    _target=$(_make_target)
    _write_design_notes "$_target"
    bash "$MIGRATE_SCRIPT" --target "$_target" >/dev/null 2>&1 || true
    marker_count=0
    marker_count=$(grep -c "dso-migrate-design-notes-to-design-md:v1" "$_target/.claude/design-notes.md" 2>/dev/null || true)
    assert_eq "tombstone: migration marker present in design-notes.md" "1" "$marker_count"
    deprecated_count=0
    deprecated_count=$(grep -c "DEPRECATED\|migrated\|DESIGN.md" "$_target/.claude/design-notes.md" 2>/dev/null || true)
    assert_ne "tombstone: deprecation notice present" "0" "$deprecated_count"
fi
assert_pass_if_clean "test_tombstone_content"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: idempotency — re-running does not alter tombstone or DESIGN.md
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Test 5: idempotency"
_snapshot_fail
if [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "test_idempotency ... SKIP (script missing)"
else
    _target=$(_make_target)
    _write_design_notes "$_target"
    # First run
    bash "$MIGRATE_SCRIPT" --target "$_target" >/dev/null 2>&1 || true
    _design_md_after_first="$(cat "$_target/DESIGN.md" 2>/dev/null || echo "")"
    _tombstone_after_first="$(cat "$_target/.claude/design-notes.md" 2>/dev/null || echo "")"
    # Second run
    exit_code2=0
    bash "$MIGRATE_SCRIPT" --target "$_target" 2>&1 || exit_code2=$?
    assert_eq "idempotency: second run exits 0" "0" "$exit_code2"
    _design_md_after_second="$(cat "$_target/DESIGN.md" 2>/dev/null || echo "")"
    _tombstone_after_second="$(cat "$_target/.claude/design-notes.md" 2>/dev/null || echo "")"
    assert_eq "idempotency: DESIGN.md unchanged on re-run" "$_design_md_after_first" "$_design_md_after_second"
    assert_eq "idempotency: tombstone unchanged on re-run" "$_tombstone_after_first" "$_tombstone_after_second"
fi
assert_pass_if_clean "test_idempotency"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: YAML front-matter structure — DESIGN.md starts with ---\nname: ...\n---
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Test 6: YAML front-matter structure"
_snapshot_fail
if [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "test_yaml_front_matter_structure ... SKIP (script missing)"
else
    _target=$(_make_target)
    _write_design_notes "$_target"
    bash "$MIGRATE_SCRIPT" --target "$_target" >/dev/null 2>&1 || true
    # Check first line is ---
    _first_line="$(head -1 "$_target/DESIGN.md" 2>/dev/null || echo "")"
    assert_eq "yaml front-matter: first line is ---" "---" "$_first_line"
    # Check name: field is present
    _name_count=0
    _name_count=$(grep -c "^name:" "$_target/DESIGN.md" 2>/dev/null || true)
    assert_ne "yaml front-matter: name: field present" "0" "$_name_count"
    # Check closing --- is present on line 3
    _third_line="$(sed -n '3p' "$_target/DESIGN.md" 2>/dev/null || echo "")"
    assert_eq "yaml front-matter: third line is ---" "---" "$_third_line"
fi
assert_pass_if_clean "test_yaml_front_matter_structure"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: section mapping — Vision/User Archetypes/Visual Language → Overview;
#         Anti-Patterns → Dos and Donts
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Test 7: section mapping"
_snapshot_fail
if [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "test_section_mapping ... SKIP (script missing)"
else
    _target=$(_make_target)
    _write_design_notes "$_target"
    bash "$MIGRATE_SCRIPT" --target "$_target" >/dev/null 2>&1 || true
    _design_content="$(cat "$_target/DESIGN.md" 2>/dev/null || echo "")"
    # Overview section should be present (mapped from Vision/User Archetypes/Visual Language)
    _overview_count=0
    _overview_count=$(echo "$_design_content" | grep -c "^## Overview" 2>/dev/null || true)
    assert_ne "section mapping: ## Overview present" "0" "$_overview_count"
    # Dos and Donts section should be present (mapped from Anti-Patterns)
    _dos_donts_count=0
    _dos_donts_count=$(echo "$_design_content" | grep -c "^## Dos and Donts" 2>/dev/null || true)
    assert_ne "section mapping: ## Dos and Donts present" "0" "$_dos_donts_count"
    # Vision heading should NOT appear as its own ## section in DESIGN.md
    _vision_as_section=0
    _vision_as_section=$(echo "$_design_content" | grep -c "^## Vision" 2>/dev/null || true)
    assert_eq "section mapping: ## Vision not a standalone section" "0" "$_vision_as_section"
    # Anti-Patterns heading should NOT appear as its own ## section in DESIGN.md
    _anti_patterns_as_section=0
    _anti_patterns_as_section=$(echo "$_design_content" | grep -c "^## Anti-Patterns" 2>/dev/null || true)
    assert_eq "section mapping: ## Anti-Patterns not a standalone section" "0" "$_anti_patterns_as_section"
    # Other sections (Color Palette, Typography) should still be present
    _color_count=0
    _color_count=$(echo "$_design_content" | grep -c "^## Color Palette" 2>/dev/null || true)
    assert_ne "section mapping: ## Color Palette passthrough present" "0" "$_color_count"
fi
assert_pass_if_clean "test_section_mapping"

print_summary
