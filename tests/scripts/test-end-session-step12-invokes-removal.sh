#!/usr/bin/env bash
# test-end-session-step12-invokes-removal.sh — Axis 4 structural check (bug e9cb)
#
# end-session/SKILL.md Step 12 must INVOKE worktree removal once it verifies the
# worktree is merged + clean — not merely print "claude-safe can auto-remove"
# (verify-only left merged worktrees to accumulate, since claude-safe's hook is
# TTY-gated and never fires in agent sessions).
#
# Per behavioral-testing-standard Rule 5, this is a STRUCTURAL contract check on
# an instruction file: the grepped token `worktree-cleanup.sh --worktree` is a
# tooling-parsed flag (the script literally parses `--worktree`), i.e. a
# non-human consumer reads it — so grep is the appropriate referential-integrity
# assertion. We do NOT grep for prose wording.

set -uo pipefail

PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SKILL="$REPO_ROOT/plugins/dso/skills/end-session/SKILL.md"
CLEANUP="$REPO_ROOT/plugins/dso/scripts/worktree-cleanup.sh"

echo "=== test-end-session-step12-invokes-removal.sh ==="

# ── Test 1: Step 12 references the targeted removal invocation ─────────────────
# Contract: the skill must call worktree-cleanup.sh with the --worktree flag.
echo "Test 1: Step 12 invokes worktree-cleanup.sh --worktree"
if grep -qE "worktree-cleanup\.sh[^\n]*--worktree" "$SKILL"; then
    echo "  PASS: SKILL.md references the targeted removal command"
    PASS=$((PASS+1))
else
    echo "  FAIL: SKILL.md Step 12 does not invoke worktree-cleanup.sh --worktree" >&2
    FAIL=$((FAIL+1))
fi

# ── Test 2: the --worktree flag the skill references is actually parsed ────────
# Referential integrity: the contract token referenced by the skill must be a
# real, parsed option in the script (so the invocation is not a dangling ref).
echo "Test 2: worktree-cleanup.sh actually parses --worktree"
if grep -qE -- "--worktree\)" "$CLEANUP"; then
    echo "  PASS: --worktree is a parsed option in worktree-cleanup.sh"
    PASS=$((PASS+1))
else
    echo "  FAIL: --worktree is not parsed by worktree-cleanup.sh (dangling reference)" >&2
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
