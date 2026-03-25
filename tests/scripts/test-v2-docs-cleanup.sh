#!/usr/bin/env bash
# tests/scripts/test-v2-docs-cleanup.sh
# RED tests: verify no v2 tk/tickets refs remain in docs and skills.
#
# TDD RED phase (bbfb-ce09): all tests FAIL until the GREEN story removes v2
# references (bare 'tk ' invocations, .tickets/ paths, TICKETS_DIR env var
# documentation) from plugins/dso/docs/ and plugins/dso/skills/.
#
# These tests assert that v2 references are ABSENT. They currently FAIL because
# v2 references ARE present. After the GREEN story removes them, they will pass.
#
# Excluded from scanning:
#   - plugins/dso/docs/designs/           (historical ADR records)
#   - plugins/dso/docs/ticket-migraiton-v3/ (migration research notes, typo intentional)
#   - workflow-config-schema.json          (schema documents existing config keys)
#   - end-session/SKILL.md gitpathspec uses (':!.tickets/') — legitimate v3 exclusion pattern
#   - resolve-conflicts/SKILL.md — legitimately describes how to handle .tickets/ conflicts
# Note: ROLLBACK-PROCEDURE.md has been deleted as part of v2 cleanup.
#
# Usage: bash tests/scripts/test-v2-docs-cleanup.sh
# Returns: exit 1 in RED state (v2 refs present), exit 0 in GREEN state (v2 removed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

PASS=0
FAIL=0

echo "=== test-v2-docs-cleanup.sh ==="
echo ""

# ── test_no_tk_command_refs_in_skills ────────────────────────────────────────
# Skills must not contain bare 'tk ' command invocations (v2 pattern).
# v3 uses '.claude/scripts/dso ticket ...' or the 'ticket' CLI directly.
# RED: FAIL because skills still contain 'tk create', 'tk list', etc.
#
# Allow list (legitimate uses of 'tk' that are NOT v2 command invocations):
#   - "the tk wrapper"      — prose referring to the wrapper binary by name
#   - "tk script"           — prose referring to the tk binary script
#   - "tk command"          — prose referring to the tk command
#   - "tk binary"           — prose referring to the tk binary
#   - "tk write"            — prose (e.g. "tk write commands")
#   - "tk read"             — prose
#   - lines starting with # — comments
#   - "v2 tk"               — historical mention of v2 artifact

echo "Test: test_no_tk_command_refs_in_skills"
tk_refs_in_skills=""
while IFS= read -r line; do
    file="${line%%:*}"
    content="${line#*:}"

    # Skip prose/explanatory references
    echo "$content" | grep -qE "the tk wrapper|tk script|tk command|tk binary|tk write|tk read|v2 tk|\btk\b.*wrapper" && continue
    # Skip comment lines
    echo "$content" | grep -qE '^\s*#' && continue
    # Skip end-session/SKILL.md which uses ':!.tickets/' in gitpathspec — not a tk command
    [[ "$file" == *"end-session/SKILL.md"* ]] && echo "$content" | grep -q "':!\." && continue
    # Skip resolve-conflicts/SKILL.md which legitimately documents .tickets/ conflict handling
    [[ "$file" == *"resolve-conflicts/SKILL.md"* ]] && continue

    tk_refs_in_skills="$tk_refs_in_skills
$line"
done < <(grep -rn '\btk\b' "$DSO_PLUGIN_DIR/skills/" 2>/dev/null || true)

if [[ -z "$(echo "$tk_refs_in_skills" | tr -d '[:space:]')" ]]; then
    echo "  PASS: no bare 'tk' command invocations found in plugins/dso/skills/"
    (( PASS++ ))
else
    echo "  FAIL: bare 'tk' command invocations found in plugins/dso/skills/ (v2 pattern)" >&2
    echo "        Expected all tk calls to be replaced with 'ticket' or '.claude/scripts/dso ticket'" >&2
    echo "$tk_refs_in_skills" | grep -v '^\s*$' | head -20 >&2
    (( FAIL++ ))
fi
echo ""

# ── test_no_tickets_dir_in_docs ───────────────────────────────────────────────
# docs/ must not reference '.tickets/' (v2 path) except in excluded historical files.
# v3 uses the orphan branch mounted at '.tickets-tracker/'.
# RED: FAIL because several docs files still reference .tickets/ paths.
#
# Excluded paths (intentional historical content):
#   - plugins/dso/docs/designs/                 — ADR historical records
#   - plugins/dso/docs/ticket-migraiton-v3/     — migration research notes
#   - plugins/dso/docs/workflow-config-schema.json — schema (documents existing keys)
# Note: ROLLBACK-PROCEDURE.md has been deleted; exclusion removed.

echo "Test: test_no_tickets_dir_in_docs"
tickets_dir_refs=""
while IFS= read -r line; do
    file="${line%%:*}"

    # Skip excluded historical/schema paths
    [[ "$file" == *"/docs/designs/"* ]] && continue
    [[ "$file" == *"/docs/ticket-migraiton-v3/"* ]] && continue
    [[ "$file" == *"workflow-config-schema.json"* ]] && continue

    tickets_dir_refs="$tickets_dir_refs
$line"
done < <(grep -rn '\.tickets/' "$DSO_PLUGIN_DIR/docs/" 2>/dev/null | grep -v 'tickets-tracker' || true)

if [[ -z "$(echo "$tickets_dir_refs" | tr -d '[:space:]')" ]]; then
    echo "  PASS: no '.tickets/' references found in plugins/dso/docs/ (outside excluded paths)"
    (( PASS++ ))
else
    echo "  FAIL: '.tickets/' references found in plugins/dso/docs/ (v2 path pattern)" >&2
    echo "        Expected all .tickets/ references to be updated to .tickets-tracker/ or removed" >&2
    echo "$tickets_dir_refs" | grep -v '^\s*$' | head -20 >&2
    (( FAIL++ ))
fi
echo ""

# ── test_no_tickets_dir_in_skills ─────────────────────────────────────────────
# skills/ must not reference '.tickets/' (v2 path) for operational ticket storage.
# Allowed: ':!.tickets/' gitpathspec exclusion syntax in end-session/SKILL.md and
# resolve-conflicts/SKILL.md which legitimately document git operations on the
# .tickets orphan branch.
# RED: FAIL if actionable .tickets/ paths remain outside allowed files.
#
# Note: end-session/SKILL.md and resolve-conflicts/SKILL.md use '.tickets/' in
# git pathspec exclusion patterns (':!.tickets/') — these describe git behavior
# and are legitimate v3 references, not v2 storage paths. They are excluded.

echo "Test: test_no_tickets_dir_in_skills"
skills_tickets_refs=""
while IFS= read -r line; do
    file="${line%%:*}"
    content="${line#*:}"

    # Allow end-session and resolve-conflicts — they document git pathspec behavior
    [[ "$file" == *"end-session/SKILL.md"* ]] && continue
    [[ "$file" == *"resolve-conflicts/SKILL.md"* ]] && continue

    skills_tickets_refs="$skills_tickets_refs
$line"
done < <(grep -rn '\.tickets/' "$DSO_PLUGIN_DIR/skills/" 2>/dev/null | grep -v 'tickets-tracker' || true)

if [[ -z "$(echo "$skills_tickets_refs" | tr -d '[:space:]')" ]]; then
    echo "  PASS: no disallowed '.tickets/' references found in plugins/dso/skills/"
    (( PASS++ ))
else
    echo "  FAIL: '.tickets/' references found in plugins/dso/skills/ (v2 path pattern)" >&2
    echo "        Expected .tickets/ storage references to be replaced with ticket CLI calls" >&2
    echo "$skills_tickets_refs" | grep -v '^\s*$' | head -20 >&2
    (( FAIL++ ))
fi
echo ""

# ── test_no_tickets_dir_env_var_in_docs ──────────────────────────────────────
# CONFIGURATION-REFERENCE.md must not document TICKETS_DIR / TICKETS_DIR_OVERRIDE
# as operational env vars (v2 pattern). v3 uses the orphan branch; these env
# vars are v2 artifacts.
# RED: FAIL because CONFIGURATION-REFERENCE.md still has TICKETS_DIR sections.

echo "Test: test_no_tickets_dir_env_var_in_docs"
CONFIG_REF="$DSO_PLUGIN_DIR/docs/CONFIGURATION-REFERENCE.md"
if [[ ! -f "$CONFIG_REF" ]]; then
    echo "  PASS: CONFIGURATION-REFERENCE.md not found (already removed)"
    (( PASS++ ))
elif grep -qE '^\s*###?\s+`TICKETS_DIR`' "$CONFIG_REF"; then
    echo "  FAIL: CONFIGURATION-REFERENCE.md still documents TICKETS_DIR (v2 env var)" >&2
    echo "        Expected TICKETS_DIR section to be removed (v2 artifact; v3 uses orphan branch)" >&2
    grep -n 'TICKETS_DIR' "$CONFIG_REF" >&2
    (( FAIL++ ))
else
    echo "  PASS: CONFIGURATION-REFERENCE.md does not document TICKETS_DIR"
    (( PASS++ ))
fi
echo ""

# ── test_no_v2_references_in_worktree_guide ──────────────────────────────────
# WORKTREE-GUIDE.md must not describe .tickets/ as the ticket database.
# v3 uses an orphan branch mounted at .tickets-tracker/.
# RED: FAIL because WORKTREE-GUIDE.md still says ".tickets/ database" and
#      references .tickets/ in the shared-state table and troubleshooting section.

echo "Test: test_no_v2_references_in_worktree_guide"
WORKTREE_GUIDE="$DSO_PLUGIN_DIR/docs/WORKTREE-GUIDE.md"
if [[ ! -f "$WORKTREE_GUIDE" ]]; then
    echo "  PASS: WORKTREE-GUIDE.md not found"
    (( PASS++ ))
elif grep -qn '\.tickets/' "$WORKTREE_GUIDE"; then
    echo "  FAIL: WORKTREE-GUIDE.md still contains '.tickets/' references (v2 path)" >&2
    echo "        Expected all .tickets/ references to be updated to .tickets-tracker/" >&2
    grep -n '\.tickets/' "$WORKTREE_GUIDE" >&2
    (( FAIL++ ))
else
    echo "  PASS: WORKTREE-GUIDE.md does not reference .tickets/"
    (( PASS++ ))
fi
echo ""

# ── test_no_v2_references_in_rollback_procedure ──────────────────────────────
# ROLLBACK-PROCEDURE.md is a v2-era document that should either be removed or
# updated to remove forward-facing v2 instructions (keeping only archival notes).
# A clean v3 codebase should not have operational rollback docs referencing
# the tk binary and .tickets/ directory as live system state.
# RED: FAIL if the file still exists with actionable tk/v2 references.

echo "Test: test_no_v2_references_in_rollback_procedure"
ROLLBACK_DOC="$DSO_PLUGIN_DIR/docs/ROLLBACK-PROCEDURE.md"
if [[ ! -f "$ROLLBACK_DOC" ]]; then
    echo "  PASS: ROLLBACK-PROCEDURE.md does not exist (removed as part of v2 cleanup)"
    (( PASS++ ))
else
    # File may legitimately exist as an archival runbook; check for actionable v2
    # references (forward-facing instructions referencing .tickets/ directory or
    # the tk binary as live system state).
    _V2_REFS=$(grep -E '(^|\s)(\.tickets/|`tk |tk\b)' "$ROLLBACK_DOC" || true)
    if [[ -z "$_V2_REFS" ]]; then
        echo "  PASS: ROLLBACK-PROCEDURE.md exists but contains no actionable v2 references"
        (( PASS++ ))
    else
        echo "  FAIL: ROLLBACK-PROCEDURE.md contains actionable v2 references (.tickets/ or tk)" >&2
        echo "        These forward-facing v2 instructions should be removed or updated" >&2
        echo "        Found references:" >&2
        echo "$_V2_REFS" | head -5 | sed 's/^/        /' >&2
        (( FAIL++ ))
    fi
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "RESULT: FAIL ($FAIL test(s) failed — expected in RED phase; GREEN after v2 docs cleanup story)"
    exit 1
else
    echo "RESULT: PASS (all tests passed — v2 docs/skills references successfully removed)"
    exit 0
fi
