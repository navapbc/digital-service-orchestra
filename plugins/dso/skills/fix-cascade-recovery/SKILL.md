---
name: fix-cascade-recovery
description: Emergency brake for runaway cascades. Stops edits, assesses damage, decides revert, then hands off to /dso:fix-bug for investigation.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Fix Cascade Recovery Protocol

The root cause is rarely where errors appear. Read widely, edit narrowly — the fix is usually 1-5 lines once you understand the actual problem.

## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)  # shim-exempt: internal orchestration script
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — used in Step 1 (damage assessment) to see current test failures

## Protocol

### Step 0: Read Checkpoint Context (/dso:fix-cascade-recovery)

If a ticket issue ID is available for the task that triggered the cascade, read its checkpoint notes before doing git archaeology:

```bash
.claude/scripts/dso ticket show <id> 2>/dev/null
```

This is best-effort (non-mandatory). The CHECKPOINT notes reveal which substep the cascade started from and which files were already modified before things went wrong. Use this context to focus Step 1's damage assessment.

### Step 1: STOP — Assess the Damage (/dso:fix-cascade-recovery)

Do NOT touch any source files. First, understand the current state.

```bash
# What files were modified during the failed fix attempts?
git diff --name-only

# What do the current errors actually say?
cd $(git rev-parse --show-toplevel) && $TEST_CMD 2>&1 | tail -50

# What was the original state before the fix attempts began?
git log --oneline -10
```

Write down (in a ticket note via `.claude/scripts/dso ticket comment <id> "..."`) :
- How many files were changed
- How many distinct errors exist now
- What the original task/bug was

### Step 2: REVERT — Return to Known Good State (/dso:fix-cascade-recovery)

Seriously consider whether a revert is the fastest path:

```bash
# See what a revert would look like
git diff HEAD

# If changes are extensive and tangled, revert is often faster
# than trying to untangle a cascade
git stash  # Preserve changes in case you need to reference them
```

**Decision framework:**
- If > 5 files changed during the cascade → strongly consider reverting
- If the original error was a 1-2 line fix → definitely revert and start fresh
- If some changes are correct but others aren't → use selective revert (`git checkout HEAD -- <file>`)

### Step 3: HAND-OFF — Invoke dso:fix-bug (/dso:fix-cascade-recovery)

After reverting (or deciding not to revert), hand off to `/dso:fix-bug` with cascade context. This is a cascading failure — the bug must be scored with the +2 modifier in `/dso:fix-bug`'s scoring rubric for cascading failures.

Before invoking, add a cascade context note to the ticket:

```bash
.claude/scripts/dso ticket comment <id> "Cascading failure: <N> failed fix attempts caused new failures. Files changed during cascade: <list>. Original error before cascade: <description>"
```

Then invoke:

```
/dso:fix-bug <ticket-id>
```

`/dso:fix-bug` will pick up the cascading failure note and apply the +2 modifier in its scoring rubric to account for the complexity of cascading failures when prioritising and investigating.

### Step 4: RESET — Clear the Circuit Breaker (/dso:fix-cascade-recovery)

Reset the counter after tests pass, **or** after completing the hand-off to `/dso:fix-bug` if your research revealed a fundamentally different understanding of the problem. The counter's purpose is to prevent blind fix attempts — once you've done real analysis and have a new mental model, resetting before applying the planned fix is appropriate.

```bash
# Get worktree hash for state directory
WORKTREE_ROOT=$(git rev-parse --show-toplevel)
if command -v md5 &>/dev/null; then
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5)
elif command -v md5sum &>/dev/null; then
    WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5sum | cut -d' ' -f1)
fi
echo 0 > "/tmp/claude-cascade-${WT_HASH}/counter"
```

If tests do NOT pass after your planned fix, do not reset the counter. Instead:
1. Update the ticket with what you learned
2. Consider whether the diagnosis from `/dso:fix-bug` was correct
3. If you've made 2 more attempts without success, escalate to the user
