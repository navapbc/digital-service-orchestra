---
name: end-session
description: End Session - Worktree Cleanup and Task Summary
user-invocable: true
---

# End Session: Worktree Cleanup and Task Summary

Close out an ephemeral worktree session: close issues, commit, merge to main, push, and report a task summary.

All steps run from the worktree directory — no `cd` needed.

## Steps

### 1. Verify Worktree Context

Run `test -f .git`. If `.git` is a directory (not a file), abort: "This command is only for ephemeral worktree sessions."

### 2. Close Completed Issues
1. Run `tk ready` (lists open/in_progress tasks with resolved deps) and `git log main..HEAD --oneline`
2. Cross-reference: which issues were completed based on commits?
3. Ask user which to close. Close confirmed: `tk close <id>` for each
4. **Skip if no in-progress issues** — this is common when called after `/dso:debug-everything` or `/dso:sprint`, which close their own issues. Report: "No in-progress issues to close (already handled)."

### 2.5. Close Orphaned Epics (safety net)

When `/dso:sprint` is interrupted by context compaction or a control-flow issue, the epic may remain `in_progress` even though all children are closed. This step catches that case.

1. List in-progress epics:
   ```bash
   tk list --type epic --status in_progress
   ```
   If none, skip this step.

2. For each in-progress epic, check whether all children are closed:
   ```bash
   tk dep tree <epic-id>
   ```
   Parse the output: if **every** child line shows `[closed]` (and at least one child exists), the epic is a candidate.

3. For each candidate, verify the work is related to this session by checking whether any commit on this worktree branch references the epic or its children:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   # Collect child IDs from the dep tree output (all lines except the first/root)
   # Check worktree commits (unmerged) first, then recent main commits from this worktree
   COMMITS=$(git log main..HEAD --oneline 2>/dev/null)
   [ -z "$COMMITS" ] && COMMITS=$(git log --oneline -30 main)
   ```
   An epic is **session-related** if any of these match:
   - A commit message contains the epic ID or any child task ID
   - A commit message contains keywords from the epic title (match 2+ non-trivial words)
   - The sprint context passed to `/dso:end-session` names this epic

   If no commits match, the epic is **not** related to this session — skip it.

4. For each session-related candidate, close it:
   ```bash
   tk close <epic-id> --reason="Epic complete: all children closed (safety-net close by /dso:end-session)"
   ```
   Report: `"Closed orphaned epic <epic-id>: <title> (all children were already closed)."`

5. If any candidate has all children closed but is **not** session-related, report it as informational without closing:
   ```
   Note: Epic <epic-id> (<title>) has all children closed but was not worked on in this session. Consider closing it manually.
   ```

### 2.75. Release debug-everything Session Lock (if held by this worktree)

```bash
"$(git rev-parse --show-toplevel)/scripts/release-debug-lock.sh" "Session complete"
```

**If released**: note it in the session summary.
**If not found or belongs to another worktree**: skip silently (one-line report is fine).

### 2.8. Extract Technical Learnings (pre-commit)

Silently scan the git diff and conversation context to extract technical learnings before committing. Store the results for display in Step 6.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Gather diff context (unmerged commits + staged/unstaged changes)
GIT_DIFF=$(git diff main..HEAD --stat 2>/dev/null; git diff --stat 2>/dev/null)
```

Review the diff output and conversation history for signal. Identify:
- **Discoveries**: Non-obvious findings about how the system behaves (e.g., "The pipeline skips gap_analysis when document has no tables")
- **Design decisions**: Choices made and why (e.g., "Used sentinel value max_tokens=0 instead of None to distinguish 'unset' from 'default'")
- **Gotchas**: Edge cases, footguns, or surprising behavior that future sessions should know (e.g., "SQLAlchemy flushes on query, so tests must commit before asserting DB state")

**Store the results in a named section** called `LEARNINGS_FROM_2_8` for use in Step 6. If nothing substantive is found, store an empty list.

Focus on reusable knowledge. Exclude: workflow phases run, git operations performed, tool usage counts, issue IDs closed.

**This step runs silently** — do not print the learnings here. Step 6 will display them.

### 2.85. Create Bug Tickets from Learnings (pre-commit)

Review the `LEARNINGS_FROM_2_8` list stored in Step 2.8. For each learning, ask: "Should this be a bug ticket?" Create a bug ticket (`tk create "<title>" -t bug -p <priority>`) for any learning that describes:
- A defect, regression, or broken behavior that hasn't been fixed yet
- A footgun or edge case that will bite users/developers again if not addressed
- A workaround that was applied instead of a proper fix

Do NOT create tickets for neutral observations, design decisions, or already-fixed issues.

If no learnings qualify, skip silently. Any tickets created here will be committed and merged as part of the normal `/dso:end` flow in Steps 3–4.

### 2.9. Sweep Error Counters and Validation Failures (pre-commit)

Run both error sweeps before committing so that any tickets created are included in the same commit.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/skills/end-session/error-sweep.sh"
sweep_tool_errors
sweep_validation_failures
```

`sweep_tool_errors` checks `~/.claude/tool-error-counter.json` for tool-error categories that have accumulated 50 or more occurrences and creates deduplicated bug tickets for them. If the counter file is absent or malformed the step exits 0 silently.

`sweep_validation_failures` reads `$ARTIFACTS_DIR/untracked-validation-failures.log`, extracts unique failure categories, deduplicates against existing open bug tickets, and creates a bug ticket for each untracked category. If the log file is absent or empty the step exits 0 silently.

### 3. Commit Local Changes
1. Run `git status`. If changes exist: read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline (do NOT invoke `/dso:commit` via Skill tool — orchestrators execute the workflow directly).
2. **If clean: skip.** Report: "Working tree clean — nothing to commit."

### 3.5. Visual Baseline Comparison

1. Read baseline dir from config: `BASELINE_DIR=$(".claude/scripts/dso read-config.sh" visual.baseline_directory 2>/dev/null || true)` — if empty, skip this step (no visual config). Otherwise run `git diff main -- "$BASELINE_DIR" --stat` — if empty, skip this step.
2. Run `$REPO_ROOT/plugins/dso/scripts/verify-baseline-intent.sh`
3. **Exit 0** → proceed, report the intended baseline changes in the session summary.
4. **Exit 2** → baseline changes with no design manifests. Debug using `/dso:playwright-debug` (Playwright MCP authorized). If regression confirmed: `tk create "Visual regression: <details>" -t bug -p 1`, run `validate-issues.sh --quick`, STOP, ask user. If changes are expected (manifest was forgotten), ask user to run `/dso:design-wireframe` or create manifest retroactively.

### 4. Sync Tickets and Merge to Main

First, check if the branch has already been merged:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)
git log main..$BRANCH --oneline
```

**If no unmerged commits** (output is empty): the branch was already merged to main by a prior phase (e.g., `/dso:debug-everything` Phase 10). Skip the merge script. Report: "Branch already merged to main — skipping merge."

**If unmerged commits exist**: run the merge script. It handles ticket sync, merge, and push internally. Do NOT prompt for confirmation — proceed directly.

```bash
"$REPO_ROOT/plugins/dso/scripts/merge-to-main.sh"
```

If the script reports ERROR with `CONFLICT_DATA:` prefix (merge conflicts in non-`.tickets/` files): invoke `/dso:resolve-conflicts` to attempt agent-assisted resolution. If resolution succeeds, continue to Step 5. If the script reports a non-conflict ERROR: relay the error message to the user and stop.

### 4.5. Sync Tickets to Jira

<!-- Jira sync temporarily disabled — run `tk sync` manually when ticket system is stabilized. -->

> **Jira sync temporarily disabled.** Automatic `tk sync` invocation has been removed from
> this step to prevent exit-144 timeouts caused by the growing ticket ledger. To sync
> tickets to Jira, run `tk sync` manually after the session ends.

Skip this step entirely.

### 4.75. Final Worktree Verification (is_merged + is_clean)

<!-- Mirrors the exact can_remove logic in claude-safe's _offer_worktree_cleanup function.
     Keep these two in sync when either is changed. -->

Verify the worktree satisfies both conditions that `claude-safe`'s `_offer_worktree_cleanup` requires for auto-removal:

```bash
BRANCH=$(git branch --show-current)

# is_merged: exit 0 means the branch is a full ancestor of main
git merge-base --is-ancestor "$BRANCH" main && echo "MERGED" || echo "NOT MERGED"

# is_clean: empty output means no uncommitted changes
git status --porcelain
```

**If both pass** (merge-base exits 0 AND `status --porcelain` is empty):

Report: "Worktree verified clean and merged — claude-safe can auto-remove."

**If either fails**, report the specific failure:

- `merge-base --is-ancestor` returned non-zero → branch has unmerged commits. Show `git log main..HEAD --oneline`. Attempt to merge if the fix is obvious; otherwise ask the user.
- `status --porcelain` is non-empty → uncommitted changes exist. Show the dirty files. Attempt to commit forgotten files if the fix is obvious; otherwise ask the user.

Re-run both checks after any resolution attempt. Do not proceed to Step 5 until both pass.

### 5. Verify Clean Worktree State

**Note**: The is_merged and is_clean checks in Step 4.75 subsume the core safety requirements of this step. Step 5's four-condition check provides additional granularity (distinguishing staged vs. unstaged vs. untracked changes) but is secondary to the Step 4.75 gate.

**This step is mandatory — do not skip it.**

After the merge script completes, verify the **worktree** has no leftover changes (do NOT check main — main may have pre-existing unrelated dirty files):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
git status --porcelain
```

**All four conditions must be true** before proceeding (exclude `.tickets/` — ticket files sync independently and may appear dirty in worktrees):
- No unstaged changes (`git diff --quiet -- ':!.tickets/'`)
- No uncommitted staged changes (`git diff --cached --quiet -- ':!.tickets/'`)
- No unmerged paths (`git diff --name-only --diff-filter=U -- ':!.tickets/'` is empty)
- No untracked files (`git ls-files --others --exclude-standard -- ':!.tickets/'` is empty)

If any condition fails:
1. Report the dirty files and which condition(s) failed.
2. Attempt to resolve if the fix is obvious (e.g., stage and commit forgotten files, complete a trivial merge, delete generated artifacts like `.png` or `.log` files).
3. If you cannot determine how to resolve the situation, **ask the user** what they would like to do before proceeding.
4. **Do not report completion** until all four conditions pass. Re-run the checks after any resolution attempt.

### 5.5. Clean Up Artifacts Directory

Remove stale config-cache files from the workflow artifacts directory. These accumulate over sessions (one per unique config path hash) and cause I/O overhead in hooks that scan the directory.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
CACHE_COUNT=$(find "$ARTIFACTS_DIR" -name 'config-cache-*' -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$CACHE_COUNT" -gt 0 ]; then
    find "$ARTIFACTS_DIR" -name 'config-cache-*' -type f -delete
    echo "Cleaned up $CACHE_COUNT stale config-cache files from $ARTIFACTS_DIR"
fi
```

Keep the primary `config-cache` file (no suffix) — only delete the hash-suffixed variants.

### 6. Report: Task Summary and Completion

Display a comprehensive session summary using stored learnings from Step 2.8.

**Technical Learnings** — display the stored learnings generated in Step 2.8 (omit if empty). Do not re-scan the git diff or conversation — show what was captured before the commit.

Display each category from `LEARNINGS_FROM_2_8`:
- **Discoveries**: Non-obvious findings about how the system behaves
- **Design decisions**: Choices made and why
- **Gotchas**: Edge cases, footguns, or surprising behavior future sessions should know

**Task Summary** (gathered from git log and tickets):
- Epic ID and title (if a `/dso:sprint` or `/dso:debug-everything` was running)
- Tasks completed this session. Check both:
  - `git log main..HEAD --oneline` (unmerged commits on this branch)
  - If empty (already merged): `git log --oneline -20 main` and identify commits from this worktree branch by their merge commit messages
- Tasks remaining (if context is available: IDs, titles, blocked status)
- Resume command (if work remains): `/dso:sprint <epic-id> --resume` or "Run `/dso:debug-everything` again"

**Session Summary**:
- Issues closed (count, with IDs)
- Commits made (count and final SHA on main)
- Branch merged/pushed (or "already merged by prior phase")
- Worktree cleanup status

### 7. Session Complete
