---
name: oscillation-check
description: Detect feedback oscillation in iterative review loops using structural diff comparison. Invoke before implementing review feedback.
user-invocable: false
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Oscillation Check

Detects when iterative review feedback would revert changes made by a previous
iteration -- preventing infinite fix-revert-fix loops.

## When to Use

Invoke as a sub-agent from:
- **CLAUDE.md review loop**: Before implementing `/dso:review` feedback on iteration 2+
- **`/dso:sprint` Phase 8**: Before creating remediation tasks from re-validation
- **`/dso:debug-everything` Phase H Step 5**: Before retrying a fix after critic CONCERN

## Input

The orchestrator provides:
- `files_targeted`: List of files the current feedback wants to modify
- `iteration`: Current iteration number (1-indexed)
- `context`: One of `review`, `remediation`, `critic`
- `commit_before_previous_fix`: Git commit SHA from before the previous iteration's changes (optional -- if not provided, use `HEAD~1`)
- `epic_id`: (for `remediation` context only) The epic whose children to check

## Protocol

### For `review` and `critic` context:

1. Check if this is iteration 1 -> output `CLEAR` (no previous iteration to compare)
2. For iteration 2+:
   a. Get the diff of what the previous iteration changed:
      ```bash
      git diff {commit_before_previous_fix}..HEAD -- {files_targeted}
      ```
   b. If the diff is empty (previous iteration didn't touch these files) -> `CLEAR`
   c. If the diff is non-empty: the current feedback targets files that were already
      modified. Analyze the feedback direction:
      - Read the current feedback items for these files
      - Compare against the previous iteration's changes shown in the diff
      - If the feedback would **undo** previous changes (revert direction) -> `OSCILLATION`
      - If the feedback would **build on** previous changes (same direction) -> `CLEAR`

### For `remediation` context:

1. Get closed remediation tasks from the epic:
   ```bash
   .claude/scripts/dso ticket deps {epic_id}
   ```
   Filter for tasks with "Fix:" prefix and status=closed.
2. For each closed remediation task, read its notes (`.claude/scripts/dso ticket show <id>`) to find
   modified files.
3. Compare `files_targeted` against the closed tasks' modified files.
4. If overlap exists -> `OSCILLATION` (same files being re-remediated)
5. If no overlap -> `CLEAR`

## Output Format

```
OSCILLATION CHECK
=================
Context: {review|remediation|critic}
Iteration: {N}
Files checked: {file1}, {file2}, ...

Result: CLEAR | OSCILLATION

(If OSCILLATION):
Conflicting iterations:
  Previous (iteration {N-1}): Changed {files} -- {summary of changes}
  Current (iteration {N}): Wants to {summary of proposed changes}
  Direction: REVERSAL -- current feedback undoes previous fix

Recommendation: Stop loop. Present both positions to user.
```

## Safety Bounds (enforced by callers, reported here)

| Context | Max Iterations | On Limit |
|---------|---------------|----------|
| `/dso:review` autonomous loop | `review.max_resolution_attempts` (default: 5) | Escalate to user (findings + actions taken) |
| `/dso:review` total (with user) | `review.max_resolution_attempts` + 3 (user-driven buffer) | Stop, report to user |
| `/dso:debug-everything` critic | 2 revert cycles per issue | Escalate to user |
| `/dso:sprint` remediation | 2 loops | Flag to user |

### Rules
- Do NOT modify any code files
- Do NOT `git commit`, `git push`, `.claude/scripts/dso ticket transition`, edit `.tickets-tracker/` files
- You CAN run `git diff`, `git log`, `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket deps`
- This is a read-only analysis -- report findings only
