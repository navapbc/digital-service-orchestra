---
name: fix-cascade-recovery
description: Use when 5+ fix attempts have cascaded into new failures, when the cascade circuit-breaker fires (CLAUDE.md rule 6), or when repeated edits are propagating errors instead of resolving them. Stops further edits, assesses blast radius via git diff, decides whether to fully revert / selectively revert / keep changes, attaches cascade context to the active ticket, hands off to /dso:fix-bug for informed investigation, and resets the circuit-breaker counter. Trigger phrases include 'cascade circuit-breaker fired', 'too many failed attempts', 'rollback cascading changes', 'revert this mess', 'stop the edits', 'recover from a cascade', 'undo cascading edits'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Fix Cascade Recovery Protocol

Emergency brake fired by the cascade circuit-breaker after 5 cascading failures (CLAUDE.md rule 6). The root cause is rarely where errors appear — read widely, edit narrowly. The fix is usually 1–5 lines once the actual problem is understood.

## Prerequisites

Resolve a ticket ID for cascade context, in this order:
1. The single open `in_progress` ticket: `.claude/scripts/dso ticket list --status=in_progress --format=llm` (most cascades fire mid-task with one in-progress ticket).
2. None — proceed without ticket comments. The hand-off to `/dso:fix-bug` still works; recovery is not blocked on ticket presence.

Set `TICKET_ID` for the steps below; if unset or ambiguous (multiple in-progress tickets), skip the `ticket comment` lines.

## Phase A — Recover

### Step 1: Assess Damage

Do NOT touch source files. Establish current state:

```bash
git diff --stat                                       # blast radius
git diff --name-only                                  # exact files
git log --oneline -10                                 # last known good
[[ -n "${TICKET_ID:-}" ]] && .claude/scripts/dso ticket show "$TICKET_ID" 2>/dev/null  # checkpoint notes
```

Do NOT re-run the project test suite here — it is known-broken (that's why the breaker fired) and exceeds the 73s tool timeout (CLAUDE.md rule 19, INC-001). The file count from `git diff --stat` is the load-bearing signal.

If `TICKET_ID` is set, record file count and original task:

```bash
.claude/scripts/dso ticket comment "$TICKET_ID" "Cascade assessment: <N> files changed, original task: <description>"
```

### Step 2: Decide Revert

Decision framework:
- **>5 files changed during the cascade** → full revert: `git stash --keep-index` (preserves for reference; drop after Step 3 confirms a fresh fix is on the way).
- **Original error was a 1–2 line fix** → full revert: `git stash --keep-index` and start fresh.
- **Some changes correct, others not** → selective revert: `git checkout HEAD -- <bad-file>` per bad file. Do NOT stash — keep the correct changes in the working tree for the hand-off.
- **Changes are small and likely all correct** → no revert. Do NOT stash. Proceed to Step 3 with the working tree intact.

`git stash` is conditional on the revert decision — only stash when reverting. Always use `--keep-index` (INC-016): bare `git stash` destroys staged-file state, so if a cascade fired mid-commit-workflow with files already staged, those files come back unstaged after pop. Stashing on the keep-changes path strands the in-progress fix and the hand-off to `/dso:fix-bug` will see a clean working tree.

When in doubt, revert. Untangling a cascade is almost always slower than re-fixing from clean state.

### Step 3: Hand-off + Reset

If `TICKET_ID` is set, attach cascade context (this triggers the `+2 modifier` in `/dso:fix-bug`'s scoring rubric — cross-skill contract):

```bash
.claude/scripts/dso ticket comment "$TICKET_ID" "Cascading failure: <N> failed fix attempts caused new failures. Files changed during cascade: <list>. Original error before cascade: <description>"
```

Invoke `/dso:fix-bug` via the **Skill tool** (not bash) with `TICKET_ID` as argument. If no ticket ID is available, invoke without arguments and pass cascade context inline.

Then reset the circuit breaker. The counter path `/tmp/claude-cascade-<worktree-hash>/counter` is the gate consumed by `cascade-circuit-breaker.sh` and `track-cascade-failures.sh`:

```bash
.claude/scripts/dso fix-cascade-recovery/reset-cascade-counter.sh
```

The reset fires immediately after hand-off, not after the planned fix completes. Rationale: the counter exists to stop *blind* fix attempts; once analysis has produced a new mental model via `/dso:fix-bug`, the next fix attempt is informed, not blind.

**Negative rule (gate)**: If the planned fix fails, do NOT reset again. After 2 more attempts without success, escalate to the user. Repeated resets defeat the breaker's purpose.
