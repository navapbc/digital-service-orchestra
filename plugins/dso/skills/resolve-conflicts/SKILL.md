---
name: resolve-conflicts
description: Agent-assisted git merge/rebase conflict resolution with confidence-gated automation
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:resolve-conflicts requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Resolve Conflicts: Agent-Assisted Conflict Resolution

Analyzes git merge or rebase conflicts, classifies them by complexity, auto-resolves trivial cases, and presents non-trivial resolutions for human approval.

## Invocation

**Automatic** (called by other skills):
- `/dso:end-session` Step 4: when `merge-to-main.sh` exits with `CONFLICT_DATA:` output
- `/dso:debug-everything` Phase 10 Step 1: same trigger

**Manual** (user-invoked):
- `/dso:resolve-conflicts` — resolve conflicts in the current merge/rebase state
- `/dso:resolve-conflicts <branch>` — attempt merge of `<branch>` into current branch, then resolve

## Prerequisites

Before this skill can act, one of these must be true:
- A merge is in progress with unresolved conflicts (`ms_get_conflicted_files` returns files)
- A branch name was provided as argument (skill will attempt the merge)

## Steps

### 1. Detect Conflicts

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-state.sh"
```

**If a branch argument was provided** and no merge is in progress:
```bash
git merge --no-ff <branch> -m "Merge <branch>" --quiet 2>&1
```

Check for conflicted files using the shared library:
```bash
CONFLICTED=$(ms_get_conflicted_files)
```

If `$CONFLICTED` is empty, check whether a merge is still in progress with all conflicts pre-resolved:

```bash
# Uses ms_is_merge_in_progress from ${CLAUDE_PLUGIN_ROOT}/hooks/lib/merge-state.sh
# Returns 0 (true) when MERGE_HEAD exists and != HEAD
if ms_is_merge_in_progress; then MERGE_IN_PROGRESS="yes"; else MERGE_IN_PROGRESS="no"; fi
```

- If `$MERGE_IN_PROGRESS` is `yes` and no unresolved conflicts remain: report "Merge in progress with all conflicts pre-resolved — run `git commit` to finalize the merge." and exit. Do NOT report "no conflicts detected" — the merge needs committing, not aborting.
- If `$MERGE_IN_PROGRESS` is `no`: report "No conflicts detected — merge is clean." and exit.

Separate `.tickets-tracker/` conflicts from code conflicts:
```bash
TICKET_CONFLICTS=$(echo "$CONFLICTED" | grep '^\.tickets-tracker/' || true)
CODE_CONFLICTS=$(echo "$CONFLICTED" | grep -v '^\.tickets-tracker/' || true)
```

If only `.tickets-tracker/` conflicts exist (JSON event files): auto-resolve by accepting ours (`git checkout --ours` + `git add` for each), complete the merge, and exit. Ticket event files are append-only and safe to auto-resolve.

If code conflicts exist: proceed to Step 2.

### 2. Analyze Conflicts

Dispatch the **`dso:conflict-analyzer`** dedicated agent via the Agent tool. Read `agents/conflict-analyzer.md` inline and use `subagent_type: "general-purpose"` with `model: "sonnet"`. (`dso:conflict-analyzer` is an agent file identifier, NOT a valid `subagent_type` value — the Agent tool only accepts built-in types.) Pass the following context:

Include in the sub-agent prompt:
- The content of each conflicted file (with markers)
- `git log main..<branch> --oneline -- <file>` for each file (branch-side intent)
- `git log <merge-base>..main --oneline -- <file>` for each file (main-side intent)
- Any ticket issue context from the branch name or commit messages

**Fallback**: If the `dso:conflict-analyzer` agent file is missing (e.g., plugin not installed), fall back to `subagent_type: "general-purpose"` with model `sonnet` and include the full conflict classification procedure inline. Log a warning: "Fallback: dso:conflict-analyzer agent not found; using general-purpose with inline prompt."

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
   .claude/scripts/dso validate.sh --ci
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
- If called from `/dso:end-session` or `/dso:debug-everything`, return control to the calling skill

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

- `.tickets-tracker/` JSON event files are auto-resolved (accept ours) — they are append-only and safe to resolve without user input.
- Individual ticket `.md` files are NOT auto-resolved — show a diff to the user and ask for confirmation before choosing a version, as each side may contain important state changes.
- Sub-agent model: **sonnet** — conflict resolution needs code understanding but not architectural reasoning
- This skill does NOT commit or push — it only completes the merge. The calling skill handles commit/push.
- Maximum 10 conflicted files. Above that, report to user: "Too many conflicts for agent-assisted resolution. Consider rebasing incrementally."
