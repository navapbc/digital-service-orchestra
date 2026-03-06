---
name: resolve-conflicts
description: Agent-assisted git merge/rebase conflict resolution with confidence-gated automation
user-invocable: true
---

# Resolve Conflicts: Agent-Assisted Conflict Resolution

Analyzes git merge or rebase conflicts, classifies them by complexity, auto-resolves trivial cases, and presents non-trivial resolutions for human approval.

## Invocation

**Automatic** (called by other skills):
- `/end-session` Step 4: when `merge-to-main.sh` exits with `CONFLICT_DATA:` output
- `/debug-everything` Phase 10 Step 1: same trigger

**Manual** (user-invoked):
- `/resolve-conflicts` — resolve conflicts in the current merge/rebase state
- `/resolve-conflicts <branch>` — attempt merge of `<branch>` into current branch, then resolve

## Prerequisites

Before this skill can act, one of these must be true:
- A merge is in progress with unresolved conflicts (`git diff --name-only --diff-filter=U` returns files)
- A branch name was provided as argument (skill will attempt the merge)

## Steps

### 1. Detect Conflicts

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
```

**If a branch argument was provided** and no merge is in progress:
```bash
git merge --no-ff <branch> -m "Merge <branch>" --quiet 2>&1
```

Check for conflicted files:
```bash
CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null)
```

If `$CONFLICTED` is empty: report "No conflicts detected — merge is clean." and exit.

Separate `.tickets/` conflicts from code conflicts:
```bash
TICKET_CONFLICTS=$(echo "$CONFLICTED" | grep '^\.tickets/' || true)
CODE_CONFLICTS=$(echo "$CONFLICTED" | grep -v '^\.tickets/' || true)
```

Auto-resolve `.tickets/` conflicts immediately (ours strategy — matches existing `merge-to-main.sh` behavior):
```bash
if [ -n "$TICKET_CONFLICTS" ]; then
    git checkout --ours -- .tickets/
    git add .tickets/
fi
```

If only `.tickets/` conflicts existed and no code conflicts remain: complete the merge and exit.

If code conflicts exist: proceed to Step 2.

### 2. Analyze Conflicts

Dispatch a **sonnet-tier sub-agent** (via Task tool, `subagent_type: "general-purpose"`, `model: "sonnet"`) with this prompt structure:

```
You are analyzing git merge conflicts to propose resolutions.

For each conflicted file, I will provide:
- The file path
- The conflict markers (full content with <<<<<<< / ======= / >>>>>>>)
- Recent commits on each side that touched this file

Your job: classify each conflict and propose a resolution.

CONFLICT CLASSIFICATIONS:

TRIVIAL — Auto-resolvable with high confidence:
- Import ordering differences (both sides added different imports)
- Non-overlapping additions (both sides added code in the same region but the additions don't interact)
- Whitespace or formatting differences
- Both sides made the identical change (duplicate work)
- One side added code, the other only moved/reformatted nearby code

SEMANTIC — Resolvable but needs human review:
- Both sides modified the same function with compatible intent (e.g., one added a parameter, the other changed the body)
- Both sides changed the same config/constant to different values
- One side refactored code that the other side extended

AMBIGUOUS — Cannot resolve without human decision:
- Both sides changed the same logic with conflicting intent
- Architectural disagreements (e.g., one side deleted a function the other side modified)
- Changes where the correct merge depends on product requirements, not code logic

For each file, output:
1. File path
2. Classification: TRIVIAL | SEMANTIC | AMBIGUOUS
3. Proposed resolution (the merged code)
4. Explanation: what each side intended and how you merged them
5. Confidence: HIGH | MEDIUM | LOW
```

Include in the sub-agent prompt:
- The content of each conflicted file (with markers)
- `git log main..<branch> --oneline -- <file>` for each file (branch-side intent)
- `git log <merge-base>..main --oneline -- <file>` for each file (main-side intent)
- Any ticket issue context from the branch name or commit messages

### 3. Resolve

Based on sub-agent classifications:

**TRIVIAL conflicts (auto-resolve)**:
- Apply the proposed resolution directly
- Stage the resolved file: `git add <file>`

**SEMANTIC and AMBIGUOUS conflicts (human approval required)**:
- Hold for presentation in Step 4

### 4. Present and Apply

**If ALL conflicts were TRIVIAL**:
1. All resolutions are already staged from Step 3
2. Complete the merge:
   ```bash
   git -c core.editor=true merge --continue 2>/dev/null || \
       git commit --no-edit 2>/dev/null || true
   ```
3. Run validation:
   ```bash
   cd "$REPO_ROOT/app" && make format-check && make lint && make test-unit-only
   ```
4. **If validation passes**: report summary and exit successfully. The merge is complete.
   ```
   Auto-resolved N TRIVIAL conflict(s):
   - path/to/file1.py: import ordering (both sides added imports)
   - path/to/file2.py: non-overlapping additions
   Validation: PASSED (format, lint, unit tests)
   ```
5. **If validation fails**: roll back the merge, report the failures, and fall through to the human approval flow below (treat all conflicts as needing review).
   ```bash
   git merge --abort 2>/dev/null || git reset --merge 2>/dev/null || true
   ```
   Then re-run the merge to restore conflict state and present all resolutions for human review.

**If ANY conflict is SEMANTIC or AMBIGUOUS** (or trivial auto-resolve failed validation):
1. Present a summary table:
   ```
   Conflict Resolution Proposal:

   | File | Type | Confidence | Strategy |
   |------|------|------------|----------|
   | path/to/file1.py | TRIVIAL | HIGH | Import ordering — merged both |
   | path/to/file2.py | SEMANTIC | MEDIUM | Both sides extended Config — combined |
   | path/to/file3.py | AMBIGUOUS | LOW | Conflicting logic — needs your decision |
   ```
2. For each non-TRIVIAL file, show:
   - What the branch side intended (from commits/tickets)
   - What the main side intended (from commits)
   - The proposed merged resolution as a diff
3. For AMBIGUOUS files, show both options and ask the user to choose
4. **Wait for user approval** before applying any changes
5. After approval, apply resolutions, stage files, and complete the merge
6. Run validation. If it fails, report and let the user decide.

### 5. Cleanup

After successful resolution:
- Report the final merge commit SHA
- If called from `/end-session` or `/debug-everything`, return control to the calling skill

If resolution was abandoned (user chose to resolve manually):
- Ensure merge state is clean (`git merge --abort` if merge is still in progress)
- Report: "Conflict resolution abandoned. Merge aborted. Resolve manually with `git merge <branch>`."

## Error Recovery

| Situation | Action |
|-----------|--------|
| Sub-agent fails to parse conflicts | Fall back to presenting raw conflict markers to user |
| Sub-agent proposes invalid code | Validation catches it; escalate to human |
| User rejects all proposals | Abort merge, report manual resolution needed |
| Merge --continue fails after staging | `git reset --merge`, report error, escalate to user |

## Constraints

- `.tickets/` conflicts always use ours strategy (auto-resolve, no sub-agent needed)
- Sub-agent model: **sonnet** — conflict resolution needs code understanding but not architectural reasoning
- This skill does NOT commit or push — it only completes the merge. The calling skill handles commit/push.
- Maximum 10 conflicted files. Above that, report to user: "Too many conflicts for agent-assisted resolution. Consider rebasing incrementally."
