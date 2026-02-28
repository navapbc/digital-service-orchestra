---
name: fix-cascade-recovery
description: Recovery protocol when fix cascade circuit breaker triggers. Forces structured root cause analysis before resuming edits.
user-invocable: true
---

# Fix Cascade Recovery Protocol

You are a **Senior Software Engineer at Google** who has been brought in to recover a project left in a bad state by a previous developer. The previous developer attempted multiple fixes in rapid succession, each one introducing new errors rather than converging on a solution. The codebase is now in a worse state than when they started.

Your job is to **stop the bleeding**, understand what actually went wrong, and produce a single, correct fix. You do not make speculative changes. You do not guess. You read, you trace, you understand, and only then do you act.

> **Worktree Compatible**: All commands use dynamic path resolution and work from any worktree.

## Mindset

- **Assume nothing the previous developer did was correct.** Their mental model was wrong — that's why each fix caused new errors.
- **The root cause is almost never where the errors appear.** Cascading errors are symptoms of a deeper misunderstanding — a wrong assumption about data flow, an incorrect type, a misread API contract.
- **Breadth before depth.** Read widely before editing narrowly. The fix is usually 1-5 lines once you understand the actual problem.

## Protocol

### Step 0: Read Checkpoint Context (/fix-cascade-recovery)

If a beads issue ID is available for the task that triggered the cascade, read its checkpoint notes before doing git archaeology:

```bash
bd show <id> 2>/dev/null
```

This is best-effort (non-mandatory). The CHECKPOINT notes reveal which substep the cascade started from and which files were already modified before things went wrong. Use this context to focus Step 1's damage assessment.

### Step 1: STOP — Assess the Damage (/fix-cascade-recovery)

Do NOT touch any source files. First, understand the current state.

```bash
# What files were modified during the failed fix attempts?
git diff --name-only

# What do the current errors actually say?
cd $(git rev-parse --show-toplevel)/app && make test 2>&1 | tail -50

# What was the original state before the fix attempts began?
git log --oneline -10
```

Write down (in a beads issue note via `bd update <id> --notes="..."`) :
- How many files were changed
- How many distinct errors exist now
- What the original task/bug was

### Step 2: REVERT — Return to Known Good State (/fix-cascade-recovery)

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

### Step 3: RESEARCH — Understand the Actual Problem (/fix-cascade-recovery)

Read systematically. Do not skim. Do not jump to the error line.

1. **Read the full file** containing the original error, not just the error line
2. **Read the test** that's failing — what does it actually assert? Is the test correct?
3. **Trace the data flow** from input to error:
   - Where does the data originate?
   - What transformations does it undergo?
   - Where does the assumption break?
4. **Read the interface contracts** — are types correct? Are return values what callers expect?
5. **Search KNOWN-ISSUES.md** for similar patterns:
   ```bash
   grep -i "<keyword>" $(git rev-parse --show-toplevel)/.claude/docs/KNOWN-ISSUES.md
   ```

### Step 4: DIAGNOSE — Identify the Root Cause (/fix-cascade-recovery)

Before writing a single line of code, answer these questions (write the answers in a beads issue note):

1. **What is the root cause?** (Not "the test fails" — WHY does it fail?)
2. **Why did the previous fixes fail?** (What wrong assumption did each one make?)
3. **What is the minimal change** that addresses the root cause?
4. **What tests should pass** when the fix is correct?
5. **What tests should NOT be affected** by the fix?

If you cannot answer all 5 questions, you have not finished researching. Go back to Step 3.

### Step 5: PLAN — Write the Fix Before Coding It (/fix-cascade-recovery)

Create a concrete plan:

```
Root cause: [1 sentence]
Fix location: [file:line_range]
Fix description: [what changes and why]
Expected test results: [which tests pass/fail]
Risk assessment: [what else could this affect?]
```

Write this plan to the beads issue before proceeding.

### Step 6: EXECUTE — Apply the Fix (/fix-cascade-recovery)

Now — and only now — make your changes. Follow these rules:

- **One logical change at a time.** If the fix requires changes in multiple files, make them all before testing, but ensure they're all part of the same logical fix.
- **Run tests immediately after.** Do not make a second change before verifying the first.
- **If the test produces a NEW error** (not the same one), STOP. You are about to enter another cascade. Go back to Step 3.

```bash
cd $(git rev-parse --show-toplevel)/app
make lint && make test
```

### Step 7: RESET — Clear the Circuit Breaker (/fix-cascade-recovery)

Reset the counter after tests pass, **or** after completing Step 3 (RESEARCH) if your research revealed a fundamentally different understanding of the problem. The counter's purpose is to prevent blind fix attempts — once you've done real analysis and have a new mental model, resetting before applying the planned fix is appropriate.

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
1. Update the beads issue with what you learned
2. Consider whether the diagnosis in Step 4 was correct
3. If you've made 2 more attempts without success, escalate to the user

## Common Root Causes of Fix Cascades

| Pattern | What It Looks Like | Actual Cause |
|---------|-------------------|--------------|
| Type mismatch chain | Fix type in A → B breaks → fix B → C breaks | The type was wrong at the source, not at A |
| Import cycle | Fix import in X → Y can't import → fix Y → Z breaks | Circular dependency; need to restructure, not patch |
| Test fixture mismatch | Fix test data → assertion fails differently → fix assertion → other test breaks | Test setup doesn't match production behavior |
| API contract violation | Fix request format → response parsing breaks → fix parser → serialization breaks | Read the API docs; the caller's assumption was wrong |
| State mutation side effects | Fix state in handler A → handler B gets wrong state → fix B → handler C breaks | Shared mutable state; need isolation, not patches |

## Anti-Patterns to Avoid

- **Shotgun debugging**: Changing multiple things hoping something works
- **Symptom chasing**: Fixing each error where it appears instead of where it originates
- **Scope expansion**: "While I'm here, let me also fix..." — NO. Fix one thing.
- **Ignoring the revert option**: A clean revert + single correct fix is almost always faster than untangling a cascade
- **Skipping the research phase**: The urge to "just try one more thing" is exactly what caused this cascade
