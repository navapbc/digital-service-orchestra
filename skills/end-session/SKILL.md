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
4. **Skip if no in-progress issues** — this is common when called after `/debug-everything` or `/sprint`, which close their own issues. Report: "No in-progress issues to close (already handled)."

### 2.5. Release debug-everything Session Lock (if held by this worktree)

Check for an active `/debug-everything` lock belonging to this worktree and release it:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

# Check for an active lock using the canonical lock-status subcommand
# (locks live in the tk ticket store, not beads)
LOCK_STATUS=$("$REPO_ROOT/scripts/agent-batch-lifecycle.sh" lock-status "debug-everything")

if echo "$LOCK_STATUS" | grep -q "^LOCKED:"; then
    LOCK_ID=$(echo "$LOCK_STATUS" | sed 's/^LOCKED: *//')

    # Verify the lock belongs to this worktree session
    LOCK_WORKTREE=$(tk show "$LOCK_ID" 2>/dev/null | grep -oE 'Worktree: [^ ]+' | sed 's/Worktree: //' || true)

    if [ "$LOCK_WORKTREE" = "$REPO_ROOT" ]; then
        "$REPO_ROOT/scripts/agent-batch-lifecycle.sh" lock-release "$LOCK_ID" "Session complete"
        echo "Released lock: $LOCK_ID"
    else
        echo "Lock $LOCK_ID belongs to a different worktree ($LOCK_WORKTREE) — skipping."
    fi
else
    echo "No active debug-everything lock — skipping."
fi
```

**If released**: note it in the session summary.
**If not found or belongs to another worktree**: skip silently (one-line report is fine).

### 3. Commit Local Changes
1. Run `git status`. If changes exist: stage specific files, commit with descriptive message.
2. **If clean: skip.** Report: "Working tree clean — nothing to commit."

### 3.5. Visual Baseline Comparison

1. `git diff main -- app/tests/e2e/snapshots/ --stat` — if empty, skip this step.
2. Run `$REPO_ROOT/scripts/verify-baseline-intent.sh`
3. **Exit 0** → proceed, report the intended baseline changes in the session summary.
4. **Exit 2** → baseline changes with no design manifests. Debug using `/playwright-debug` (Playwright MCP authorized). If regression confirmed: `tk create "Visual regression: <details>" -t bug -p 1`, run `validate-beads.sh --quick`, STOP, ask user. If changes are expected (manifest was forgotten), ask user to run `/design-wireframe` or create manifest retroactively.

### 4. Sync Beads and Merge to Main

First, check if the branch has already been merged:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)
git log main..$BRANCH --oneline
```

**If no unmerged commits** (output is empty): the branch was already merged to main by a prior phase (e.g., `/debug-everything` Phase 10). Skip the merge script. Report: "Branch already merged to main — skipping merge."

**If unmerged commits exist**: run the merge script. It handles beads sync, merge, and push internally. Do NOT prompt for confirmation — proceed directly.

```bash
"$REPO_ROOT/scripts/merge-to-main.sh"
```

If the script reports ERROR with `CONFLICT_DATA:` prefix (merge conflicts in non-`.tickets/` files): invoke `/resolve-conflicts` to attempt agent-assisted resolution. If resolution succeeds, continue to Step 5. If the script reports a non-conflict ERROR: relay the error message to the user and stop.

### 4.5. Sync Tickets to Jira

After the merge lands on main, run `tk sync` to push local ticket changes to Jira and pull any incoming Jira changes back.

```bash
tk sync 2>&1 && SYNC_OK=true || SYNC_OK=false
```

**If sync succeeds**: check whether `tk sync` staged or created any new ticket files (it may write incoming Jira updates to `.tickets/`). If it did, commit them to main as a follow-up commit:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard .tickets/)" ]; then
    git add .tickets/
    git commit -m "chore: sync incoming Jira changes from tk sync"
    git push
fi
```

**If sync fails** (e.g., `acli` not installed, Jira unreachable, credentials missing): print a warning and continue — sync failure is non-blocking:

```
⚠ tk sync failed — Jira sync skipped. Session will close normally.
   To retry: run `tk sync` manually after the session ends.
```

Note the outcome (success, follow-up commit made, or warning) in the session summary under Step 6.

### 5. Verify Clean Worktree State

**This step is mandatory — do not skip it.**

After the merge script completes, verify the **worktree** has no leftover changes (do NOT check main — main may have pre-existing unrelated dirty files):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
git status --porcelain
```

**All four conditions must be true** before proceeding:
- No unstaged changes (`git diff --quiet`)
- No uncommitted staged changes (`git diff --cached --quiet`)
- No unmerged paths (`git diff --name-only --diff-filter=U` is empty)
- No untracked files (`git ls-files --others --exclude-standard` is empty)

If any condition fails:
1. Report the dirty files and which condition(s) failed.
2. Attempt to resolve if the fix is obvious (e.g., stage and commit forgotten files, complete a trivial merge, delete generated artifacts like `.png` or `.log` files).
3. If you cannot determine how to resolve the situation, **ask the user** what they would like to do before proceeding.
4. **Do not report completion** until all four conditions pass. Re-run the checks after any resolution attempt.

### 6. Report: Task Summary and Completion

Display a comprehensive session summary:

**Task Summary** (gathered from git log and beads):
- Epic ID and title (if a `/sprint` or `/debug-everything` was running)
- Tasks completed this session. Check both:
  - `git log main..HEAD --oneline` (unmerged commits on this branch)
  - If empty (already merged): `git log --oneline -20 main` and identify commits from this worktree branch by their merge commit messages
- Tasks remaining (if context is available: IDs, titles, blocked status)
- Resume command (if work remains): `/sprint <epic-id> --resume` or "Run `/debug-everything` again"

**Session Summary**:
- Issues closed (count, with IDs)
- Commits made (count and final SHA on main)
- Branch merged/pushed (or "already merged by prior phase")
- Worktree cleanup status

**Technical Learnings** (scan git diff and conversation for signal — omit if nothing substantive):
- **Discoveries**: Non-obvious findings about how the system behaves (e.g., "The pipeline skips gap_analysis when document has no tables")
- **Design decisions**: Choices made and why (e.g., "Used sentinel value max_tokens=0 instead of None to distinguish 'unset' from 'default'")
- **Gotchas**: Edge cases, footguns, or surprising behavior that future sessions should know (e.g., "SQLAlchemy flushes on query, so tests must commit before asserting DB state")

Focus on reusable knowledge. Exclude: workflow phases run, git operations performed, tool usage counts, issue IDs closed.
