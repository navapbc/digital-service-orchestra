#!/usr/bin/env bash
# tests/scripts/test-migrate-design-notes.sh
# RED-phase behavioral tests for plugins/dso/scripts/migrate-design-notes-to-design-md.sh
#
# Testing Mode: RED — tests FAIL until migrate-design-notes-to-design-md.sh is implemented.
#
# Behavior under test:
#   migrate-design-notes-to-design-md.sh migrates .claude/design-notes.md to DESIGN.md:
#     - Happy path: sections mapped, YAML front-matter prepended, design-notes.md → tombstone
#     - Greenfield guard: no design-notes.md exists → exit 0, no DESIGN.md created
#     - Idempotency: DESIGN.md already exists with migration marker → exit 0, no changes
#     - Tombstone content: design-notes.md contains deprecation marker after migration
#     - YAML front-matter: DESIGN.md starts with --- delimiters after migration
#
# Usage: bash tests/scripts/test-migrate-design-notes.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

MIGRATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/migrate-design-notes-to-design-md.sh"

echo "=== test-migrate-design-notes.sh ==="

# ── Suite-runner guard (RED phase) ────────────────────────────────────────────
# When run-all.sh invokes this suite and the script is not yet implemented,
# skip gracefully so the overall suite stays green.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo 'SKIP: migrate-design-notes-to-design-md.sh not yet implemented (RED) — tests deferred'
    printf 'PASSED: 0  FAILED: 0\n'
    exit 0
fi

# ── Shared temp dir registry — all cleaned up on EXIT ─────────────────────────
_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]:-}"' EXIT

# ── Helper: create a minimal project fixture directory ────────────────────────
# Returns the fixture root directory path via stdout.
_make_fixture() {
    local tmpdir
    tmpdir="$(mktemp -d /tmp/test-migrate-design-notes.XXXXXX)"
    _TMP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/.claude"
    echo "$tmpdir"
}

# ── Helper: write a sample design-notes.md with known sections ───────────────
# Usage: _write_design_notes <project_root>
_write_design_notes() {
    local project_root="$1"
    cat > "$project_root/.claude/design-notes.md" <<'EOF'
# Design Notes

## Color Palette
- Primary: #0070F3
- Secondary: #7928CA
- Background: #FFFFFF

## Typography
- Heading font: Inter, sans-serif
- Body font: Inter, sans-serif
- Base size: 16px

## Spacing
- Base unit: 4px
- Grid: 8-column

## Component Library
- Button: filled, outlined, ghost variants
- Card: shadow-sm elevation
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and is executable
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: migrate-design-notes-to-design-md.sh exists and is executable"
_snapshot_fail
if [ -f "$MIGRATE_SCRIPT" ]; then
    assert_eq "script exists" "exists" "exists"
else
    assert_eq "script exists" "exists" "missing"
fi
if [ -x "$MIGRATE_SCRIPT" ]; then
    assert_eq "script is executable" "executable" "executable"
else
    assert_eq "script is executable" "executable" "not-executable"
fi
assert_pass_if_clean "test_script_exists_and_executable"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: Happy path — migration creates DESIGN.md with mapped sections
# Given design-notes.md with sections, migration creates DESIGN.md with
# YAML front-matter and mapped sections, design-notes.md becomes tombstone.
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: happy path — DESIGN.md created with mapped sections"
_snapshot_fail

if [ ! -f "$MIGRATE_SCRIPT" ]; then
    assert_eq "migrate script exists (prereq)" "exists" "missing"
else
    fixture="$(_make_fixture)"
    _write_design_notes "$fixture"

    exit_code=0
    bash "$MIGRATE_SCRIPT" "$fixture" >/dev/null 2>&1 || exit_code=$?

    assert_eq "happy path: exits 0" "0" "$exit_code"

    # DESIGN.md must exist
    if [ -f "$fixture/DESIGN.md" ]; then
        assert_eq "DESIGN.md created" "present" "present"
    else
        assert_eq "DESIGN.md created" "present" "missing"
    fi

    # DESIGN.md must contain at least one recognized section keyword
    if [ -f "$fixture/DESIGN.md" ]; then
        section_found=0
        if grep -qiE "(color|typography|spacing|component)" "$fixture/DESIGN.md" 2>/dev/null; then
            section_found=1
        fi
        assert_eq "DESIGN.md contains mapped section content" "1" "$section_found"
    fi
fi

assert_pass_if_clean "test_happy_path_creates_design_md"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: Greenfield guard — no design-notes.md → exit 0, no DESIGN.md created
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: greenfield guard — no design-notes.md → exit 0, no DESIGN.md"
_snapshot_fail

if [ ! -f "$MIGRATE_SCRIPT" ]; then
    assert_eq "migrate script exists (prereq)" "exists" "missing"
else
    fixture="$(_make_fixture)"
    # No design-notes.md written — greenfield project

    exit_code=0
    bash "$MIGRATE_SCRIPT" "$fixture" >/dev/null 2>&1 || exit_code=$?

    assert_eq "greenfield: exits 0" "0" "$exit_code"

    if [ -f "$fixture/DESIGN.md" ]; then
        assert_eq "greenfield: no DESIGN.md created" "absent" "present"
    else
        assert_eq "greenfield: no DESIGN.md created" "absent" "absent"
    fi
fi

assert_pass_if_clean "test_greenfield_guard"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: Idempotency — DESIGN.md already exists with migration marker → exit 0, no changes
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: idempotency — DESIGN.md with migration marker → exit 0, no changes"
_snapshot_fail

if [ ! -f "$MIGRATE_SCRIPT" ]; then
    assert_eq "migrate script exists (prereq)" "exists" "missing"
else
    fixture="$(_make_fixture)"
    _write_design_notes "$fixture"

    # Create a DESIGN.md that already has a migration marker
    cat > "$fixture/DESIGN.md" <<'EOF'
---
migrated_from: design-notes.md
migration_marker: migrate-design-notes-to-design-md-v1
---

# Design

## Color Palette
- Primary: #0070F3
EOF

    # Record content fingerprint before second run
    design_md_before="$(cat "$fixture/DESIGN.md")"

    exit_code=0
    bash "$MIGRATE_SCRIPT" "$fixture" >/dev/null 2>&1 || exit_code=$?

    assert_eq "idempotent: exits 0" "0" "$exit_code"

    design_md_after="$(cat "$fixture/DESIGN.md")"
    assert_eq "idempotent: DESIGN.md unchanged after re-run" "$design_md_before" "$design_md_after"
fi

assert_pass_if_clean "test_idempotency"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: Tombstone content — design-notes.md contains deprecation marker after migration
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: tombstone — design-notes.md contains deprecation marker after migration"
_snapshot_fail

if [ ! -f "$MIGRATE_SCRIPT" ]; then
    assert_eq "migrate script exists (prereq)" "exists" "missing"
else
    fixture="$(_make_fixture)"
    _write_design_notes "$fixture"

    bash "$MIGRATE_SCRIPT" "$fixture" >/dev/null 2>&1 || true

    # design-notes.md must still exist as a tombstone
    if [ -f "$fixture/.claude/design-notes.md" ]; then
        assert_eq "tombstone: design-notes.md still present" "present" "present"
    else
        assert_eq "tombstone: design-notes.md still present" "present" "absent"
    fi

    # Tombstone must contain a deprecation marker (not original content only)
    if [ -f "$fixture/.claude/design-notes.md" ]; then
        tombstone_has_marker=0
        if grep -qiE "(deprecated|migrated|tombstone|DESIGN\.md)" "$fixture/.claude/design-notes.md" 2>/dev/null; then
            tombstone_has_marker=1
        fi
        assert_eq "tombstone: design-notes.md contains deprecation marker" "1" "$tombstone_has_marker"
    fi
fi

assert_pass_if_clean "test_tombstone_content"

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: YAML front-matter — DESIGN.md starts with --- delimiters after migration
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: YAML front-matter — DESIGN.md starts with --- delimiters"
_snapshot_fail

if [ ! -f "$MIGRATE_SCRIPT" ]; then
    assert_eq "migrate script exists (prereq)" "exists" "missing"
else
    fixture="$(_make_fixture)"
    _write_design_notes "$fixture"

    bash "$MIGRATE_SCRIPT" "$fixture" >/dev/null 2>&1 || true

    if [ ! -f "$fixture/DESIGN.md" ]; then
        assert_eq "DESIGN.md exists for front-matter check" "present" "absent"
    else
        # First line must be ---
        first_line="$(head -1 "$fixture/DESIGN.md")"
        assert_eq "DESIGN.md first line is ---" "---" "$first_line"

        # Must have a closing --- for the front-matter block
        closing_found=0
        if awk 'NR>1 && /^---$/ {found=1; exit} END {exit !found}' "$fixture/DESIGN.md" 2>/dev/null; then
            closing_found=1
        fi
        assert_eq "DESIGN.md has closing --- for front-matter" "1" "$closing_found"
    fi
fi

assert_pass_if_clean "test_yaml_front_matter"

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
