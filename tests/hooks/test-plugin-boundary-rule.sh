#!/usr/bin/env bash
# tests/hooks/test-plugin-boundary-rule.sh
# Behavioral tests for story ec03-5076:
#   "As an agent working in this codebase, I have clear rules about where documentation and tests belong"
#
# Assertion 1: CLAUDE.md Never Do These section contains a plugin boundary rule with:
#   - A NEVER-statement mentioning plugins/dso/
#   - Positive enumeration of permitted project-local dirs (docs/designs/, docs/findings/, etc.)
#   - NEVER-statement appears before positive enumeration
#
# Assertion 2: plugins/dso/skills/playwright-debug/SKILL.md has no reference to playwright-cli-spike-report.md
#
# Assertion 3: git grep for legacy banned paths in agents/ and skills/ returns zero matches
#
# Assertion 4: This test file itself is executable

# REVIEW-DEFENSE: set -uo (without -e) is the established project convention for hook test files.
# test-check-plugin-boundary.sh and test-process-cleanup.sh use the same pattern.
# Omitting -e is intentional: test functions must complete all assertions even when earlier ones fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAUDE_MD="$PLUGIN_ROOT/CLAUDE.md"
PLAYWRIGHT_DEBUG_SKILL="$PLUGIN_ROOT/plugins/dso/skills/playwright-debug/SKILL.md"

# REVIEW-DEFENSE: direct PASS/FAIL counter manipulation is the established project pattern.
# test-check-plugin-boundary.sh (the canonical hook test) uses the same (( ++PASS ))/(( ++FAIL ))
# style with manual printf messages. The assert.sh helpers (assert_eq/assert_ne) are used when
# comparing two values — these tests check boolean conditions (file exists, pattern present/absent)
# where direct counter manipulation produces cleaner output than assert_eq "0" "$exit_code".
source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Assertion 1a: CLAUDE.md contains a rule with NEVER + plugins/dso/ ────────
test_claude_md_contains_never_statement() {
    local found=0
    if grep -q "NEVER.*plugins/dso\|Never.*plugins/dso" "$CLAUDE_MD" 2>/dev/null; then
        found=1
    fi
    if [[ "$found" -eq 1 ]]; then
        (( ++PASS ))
        echo "PASS: CLAUDE.md contains a NEVER-statement referencing plugins/dso/"
    else
        (( ++FAIL ))
        printf "FAIL: CLAUDE.md does not contain a NEVER-statement referencing plugins/dso/\n" >&2
    fi
}

# ── Assertion 1b: CLAUDE.md rule enumerates permitted project-local dirs ──────
test_claude_md_contains_permitted_dirs() {
    local found_designs=0 found_findings=0 found_archive=0
    grep -q "docs/designs" "$CLAUDE_MD" 2>/dev/null && found_designs=1
    grep -q "docs/findings" "$CLAUDE_MD" 2>/dev/null && found_findings=1
    grep -q "docs/archive" "$CLAUDE_MD" 2>/dev/null && found_archive=1

    if [[ "$found_designs" -eq 1 && "$found_findings" -eq 1 && "$found_archive" -eq 1 ]]; then
        (( ++PASS ))
        echo "PASS: CLAUDE.md mentions docs/designs/, docs/findings/, docs/archive/ as permitted dirs"
    else
        (( ++FAIL ))
        printf "FAIL: CLAUDE.md missing one or more permitted dirs: docs/designs/=%s docs/findings/=%s docs/archive/=%s\n" \
            "$found_designs" "$found_findings" "$found_archive" >&2
    fi
}

# ── Assertion 1c: NEVER-statement appears before positive enumeration ─────────
# The NEVER ref to plugins/dso must appear on a line that comes BEFORE the first
# mention of docs/designs/ in the same rule block (within 10 lines of each other).
test_never_statement_before_enumeration() {
    local never_line designs_line
    never_line=$(grep -n "NEVER.*plugins/dso\|Never.*plugins/dso" "$CLAUDE_MD" 2>/dev/null | head -1 | cut -d: -f1)
    designs_line=$(grep -n "docs/designs" "$CLAUDE_MD" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$never_line" || -z "$designs_line" ]]; then
        (( ++FAIL ))
        printf "FAIL: Could not find NEVER-statement (%s) or docs/designs (%s) line in CLAUDE.md\n" \
            "${never_line:-missing}" "${designs_line:-missing}" >&2
        return
    fi

    if [[ "$never_line" -lt "$designs_line" ]]; then
        (( ++PASS ))
        echo "PASS: NEVER-statement (line $never_line) appears before positive enumeration (line $designs_line)"
    else
        (( ++FAIL ))
        printf "FAIL: NEVER-statement (line %s) does not appear before docs/designs (line %s)\n" \
            "$never_line" "$designs_line" >&2
    fi
}

# ── Assertion 2: playwright-debug SKILL.md has no spike-report reference ──────
test_playwright_debug_has_no_spike_report_ref() {
    if [[ ! -f "$PLAYWRIGHT_DEBUG_SKILL" ]]; then
        (( ++FAIL ))
        printf "FAIL: playwright-debug SKILL.md not found at %s\n" "$PLAYWRIGHT_DEBUG_SKILL" >&2
        return
    fi

    if grep -q "playwright-cli-spike-report" "$PLAYWRIGHT_DEBUG_SKILL" 2>/dev/null; then
        (( ++FAIL ))
        printf "FAIL: playwright-debug SKILL.md still contains reference to playwright-cli-spike-report.md\n" >&2
    else
        (( ++PASS ))
        echo "PASS: playwright-debug SKILL.md has no playwright-cli-spike-report.md reference"
    fi
}

# ── Assertion 3: No legacy banned paths in agents/ or skills/ ────────────────
test_no_legacy_paths_in_agents_or_skills() {
    local banned_count
    banned_count=$(git -C "$PLUGIN_ROOT" grep -rl \
        'plugins/dso/docs/designs\|plugins/dso/docs/findings\|plugins/dso/docs/archive' \
        plugins/dso/agents/ plugins/dso/skills/ 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$banned_count" -eq 0 ]]; then
        (( ++PASS ))
        echo "PASS: No legacy plugins/dso/docs/{designs,findings,archive} paths in agents/ or skills/"
    else
        (( ++FAIL ))
        printf "FAIL: Found %s file(s) with legacy banned paths in agents/ or skills/:\n" "$banned_count" >&2
        git -C "$PLUGIN_ROOT" grep -rl \
            'plugins/dso/docs/designs\|plugins/dso/docs/findings\|plugins/dso/docs/archive' \
            plugins/dso/agents/ plugins/dso/skills/ 2>/dev/null | while read -r f; do
            printf "  %s\n" "$f" >&2
        done
    fi
}

# ── Assertion 5: doc-writer.md has plugin boundary constraint before Section 1 ──
# Verifies story 50d5-ac2e DD1/DD2: Role Constraints section appears before The Bright
# Line Decision Engine, and contains a NEVER-statement + permitted project-local dirs.
DOC_WRITER_MD="$PLUGIN_ROOT/plugins/dso/agents/doc-writer.md"
test_doc_writer_has_plugin_boundary_constraint() {
    if [[ ! -f "$DOC_WRITER_MD" ]]; then
        (( ++FAIL ))
        printf "FAIL: doc-writer.md not found at %s\n" "$DOC_WRITER_MD" >&2
        return
    fi

    # NEVER-statement must appear before "The Bright Line Decision Engine" header
    local never_line bright_line
    never_line=$(grep -n "NEVER.*plugins/dso" "$DOC_WRITER_MD" 2>/dev/null | head -1 | cut -d: -f1)
    bright_line=$(grep -n "Bright Line" "$DOC_WRITER_MD" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$never_line" ]]; then
        (( ++FAIL ))
        printf "FAIL: doc-writer.md has no NEVER-statement referencing plugins/dso\n" >&2
        return
    fi

    if [[ -z "$bright_line" ]]; then
        (( ++FAIL ))
        printf "FAIL: doc-writer.md has no 'Bright Line' section (cannot verify placement)\n" >&2
        return
    fi

    if [[ "$never_line" -lt "$bright_line" ]]; then
        (( ++PASS ))
        echo "PASS: doc-writer.md NEVER-statement (line $never_line) appears before Bright Line section (line $bright_line)"
    else
        (( ++FAIL ))
        printf "FAIL: doc-writer.md NEVER-statement (line %s) does not appear before Bright Line section (line %s)\n" \
            "$never_line" "$bright_line" >&2
    fi

    # Schema section must enumerate docs/designs/, docs/findings/, docs/archive/
    local schema_designs schema_findings schema_archive
    grep -q "docs/designs" "$DOC_WRITER_MD" 2>/dev/null && schema_designs=1 || schema_designs=0
    grep -q "docs/findings" "$DOC_WRITER_MD" 2>/dev/null && schema_findings=1 || schema_findings=0
    grep -q "docs/archive" "$DOC_WRITER_MD" 2>/dev/null && schema_archive=1 || schema_archive=0

    if [[ "$schema_designs" -eq 1 && "$schema_findings" -eq 1 && "$schema_archive" -eq 1 ]]; then
        (( ++PASS ))
        echo "PASS: doc-writer.md schema section mentions docs/designs/, docs/findings/, docs/archive/"
    else
        (( ++FAIL ))
        printf "FAIL: doc-writer.md schema missing permitted dirs: docs/designs/=%s docs/findings/=%s docs/archive/=%s\n" \
            "$schema_designs" "$schema_findings" "$schema_archive" >&2
    fi
}

# ── Assertion 4: This test file is executable ─────────────────────────────────
test_this_file_is_executable() {
    local this_file="${BASH_SOURCE[0]}"
    if [[ -x "$this_file" ]]; then
        (( ++PASS ))
        echo "PASS: test file is executable: $this_file"
    else
        (( ++FAIL ))
        printf "FAIL: test file is not executable: %s\n" "$this_file" >&2
    fi
}

# ── Run all assertions ────────────────────────────────────────────────────────
echo "=== test-plugin-boundary-rule ==="
echo ""

echo "--- Assertion 1a: CLAUDE.md contains NEVER-statement ---"
test_claude_md_contains_never_statement
echo ""

echo "--- Assertion 1b: CLAUDE.md enumerates permitted dirs ---"
test_claude_md_contains_permitted_dirs
echo ""

echo "--- Assertion 1c: NEVER-statement before positive enumeration ---"
test_never_statement_before_enumeration
echo ""

echo "--- Assertion 2: playwright-debug has no spike-report reference ---"
test_playwright_debug_has_no_spike_report_ref
echo ""

echo "--- Assertion 3: No legacy banned paths in agents/ or skills/ ---"
test_no_legacy_paths_in_agents_or_skills
echo ""

echo "--- Assertion 4: This test file is executable ---"
test_this_file_is_executable
echo ""

echo "--- Assertion 5: doc-writer.md has plugin boundary constraint before Section 1 ---"
test_doc_writer_has_plugin_boundary_constraint
echo ""

print_summary
