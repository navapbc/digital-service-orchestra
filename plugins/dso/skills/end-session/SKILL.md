---
name: end-session
description: End Session - Worktree Cleanup and Task Summary
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires direct user interaction (prompts, confirmations, interactive choices). If you are running as a sub-agent dispatched via the Task tool, STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:end-session cannot run in sub-agent context — it requires direct user interaction. Invoke this skill directly from the main session instead."

Do NOT proceed with any skill logic if you are running as a sub-agent.
</SUB-AGENT-GUARD>

# End Session: Worktree Cleanup and Task Summary

Close out an ephemeral worktree session: close issues, commit, merge to main, push, and report a task summary.

All steps run from the worktree directory — no `cd` needed.

## Arguments

| Argument | Description |
|----------|-------------|
| `--bump <type>` | Forward version bump type (`minor`, `patch`, `major`) to `merge-to-main.sh --bump <type>`. When provided by the caller (e.g., `/dso:sprint` passes `--bump minor`), forward it to the merge script in Step 4. |

Parse arguments at skill activation. If `--bump <type>` is present, store `BUMP_ARG="--bump <type>"` for use in Step 4. If absent, `BUMP_ARG=""`.

## Steps

### 1. Verify Worktree Context

Run `test -f .git`. If `.git` is a directory (not a file), abort: "This command is only for ephemeral worktree sessions."

### 2. Close Completed Issues
1. Run `.claude/scripts/dso ticket list` (lists open/in_progress tasks with resolved deps) and `git log main..HEAD --oneline`
2. Cross-reference: which issues were completed based on commits?
3. Ask user which to close. Close confirmed: `.claude/scripts/dso ticket transition <id> open closed` for each. **Bug tickets require** `--reason="Fixed: <summary>"` — omitting it causes a silent failure.
4. **Skip if no in-progress issues** — this is common when called after `/dso:debug-everything` or `/dso:sprint`, which close their own issues. Report: "No in-progress issues to close (already handled)."

### 2.5. Close Orphaned Epics (safety net)

When `/dso:sprint` is interrupted by context compaction or a control-flow issue, the epic may remain `in_progress` even though all children are closed. This step catches that case.

1. List in-progress epics:
   ```bash
   .claude/scripts/dso ticket list --type epic --status in_progress
   ```
   If none, skip this step.

2. For each in-progress epic, check whether all children are closed (3a6a-b291: enumerate children via parent_id, NOT `ticket deps` which shows dependency relations):
   ```bash
   .claude/scripts/dso ticket list 2>/dev/null | python3 -c "
   import json, sys
   tickets = json.loads(sys.stdin.read())
   epic_id = '<epic-id>'  # Replace with actual epic ID from step 1
   children = [t for t in tickets if t.get('parent_id') == epic_id]
   open_children = [t for t in children if t.get('status') != 'closed']
   if not children:
       print('NO_CHILDREN')
   elif open_children:
       print(f'OPEN_CHILDREN:{len(open_children)}')
       for c in open_children:
           print(f'  {c[\"ticket_id\"]} [{c.get(\"status\")}] {c.get(\"title\",\"\")[:60]}')
   else:
       print('ALL_CLOSED')
   "
   ```
   - `ALL_CLOSED` (and at least one child): the epic is a candidate.
   - `OPEN_CHILDREN`: the epic is NOT a candidate — do NOT close it.
   - `NO_CHILDREN`: skip (no children to verify).

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
   .claude/scripts/dso ticket transition <epic-id> in_progress closed --reason="Epic complete: all children closed (safety-net close by /dso:end-session)"
   ```
   Report: `"Closed orphaned epic <epic-id>: <title> (all children were already closed)."`

5. If any candidate has all children closed but is **not** session-related, report it as informational without closing:
   ```
   Note: Epic <epic-id> (<title>) has all children closed but was not worked on in this session. Consider closing it manually.
   ```

### 2.75. Release debug-everything Session Lock (if held by this worktree)

```bash
.claude/scripts/dso release-debug-lock.sh "Session complete"
```

**If released**: note it in the session summary.
**If not found or belongs to another worktree**: skip silently (one-line report is fine).

### 2.77. Rationalized Failures Accountability (pre-commit)

Silently scan the conversation context for failures that were observed but not fixed during this session. Store results as `RATIONALIZED_FAILURES_FROM_2_77` for display in Step 6.

**Conversation Context Scan**: Review the full conversation for any error output, test failures noted but not fixed, validation issues acknowledged, or rationalization phrases such as "pre-existing", "infrastructure issue", "known issue", "not related to this session". Collect each distinct failure into a numbered list.

**If no failures found**: skip display entirely — store an empty list in `RATIONALIZED_FAILURES_FROM_2_77` and proceed silently to Step 2.8.

For each failure found, ask the following accountability questions:

**(a) "Was this failure observed before or after changes were made on this worktree?"**

Determine by running a `git stash` baseline check:

```bash
# stash current changes, run the test command, then always restore regardless of exit code
git stash
<test-command>; stash_exit=$?
git stash pop
exit $stash_exit
```

Where `<test-command>` is obtained from `commands.test` via `read-config.sh`. If the failure reproduces on main (i.e., the stash baseline shows the same failure), it is pre-existing. If it only appears after the stash is popped, it was introduced in this session.

**(b) "Does a bug ticket already exist for this failure?"**

Search existing bug tickets to avoid duplicates:

```bash
.claude/scripts/dso ticket list --type=bug
```

Scan titles for a match to the failure. A ticket already exists **only if a specific ticket ID can be cited**. Do NOT rationalize that a ticket "likely exists" — if you cannot name a ticket ID, no match was found and a new ticket must be created.

**Auto-Create Bug Tickets**: For each failure that does **not** have an existing bug ticket, create one. Follow `plugins/dso/skills/create-bug/SKILL.md` for title and description format:

```bash
# Title format: [Component]: [Condition] -> [Observed Result]
.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" -p <priority> -d "## Incident Overview ..."
```

Where `<priority>` is assigned based on actual severity:
- Session-introduced failures: use priority 1 for blocking failures (tests fail, CI would fail, functionality broken), priority 2 for degraded-but-functional issues
- Pre-existing failures: use priority 2 as default; lower to priority 3 for clearly minor issues (cosmetic, flaky tests, non-blocking warnings)

**Store results**: Collect all rationalized failures (with their accountability answers and ticket IDs) into `RATIONALIZED_FAILURES_FROM_2_77` for Step 6. If no failures were found, store an empty list.

**This step runs silently** — do not print findings here. Step 6 will display them.

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

Review the `LEARNINGS_FROM_2_8` list stored in Step 2.8. For each learning, ask: "Should this be a bug ticket?" Follow `plugins/dso/skills/create-bug/SKILL.md` for the required format:

```bash
# Title format: [Component]: [Condition] -> [Observed Result]
.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" -p <priority> -d "## Incident Overview ..."
```

Create a bug ticket for any learning that describes:
- A defect, regression, or broken behavior that hasn't been fixed yet
- A footgun or edge case that will bite users/developers again if not addressed
- A workaround that was applied instead of a proper fix

**Calibration anchor**: If the conversation log shows that the agent (or user) spent non-trivial time debugging, hit an unexpected error, or applied a workaround, that learning qualifies under criterion 2 or 3 above — do NOT evaluate it as a neutral observation. Do NOT skip a learning that caused real debugging cost just because it has since been understood.

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
2. Run `.claude/scripts/dso verify-baseline-intent.sh`
3. **Exit 0** → proceed, report the intended baseline changes in the session summary.
4. **Exit 2** → baseline changes with no design manifests. Debug using `/dso:playwright-debug` (Playwright MCP authorized). If regression confirmed: `.claude/scripts/dso ticket create bug "Visual regression: <details>" -p 1`, run `validate-issues.sh --quick`, STOP, ask user. If changes are expected (manifest was forgotten), ask user to run `/dso:preplanning` on the story (which dispatches `dso:ui-designer` to generate design artifacts) or create the manifest retroactively.

### 4. Sync Tickets and Merge to Main

First, check if the branch has already been merged:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)
git log main..$BRANCH --oneline
```

**If no unmerged commits** (output is empty): the branch was already merged to main by a prior phase (e.g., `/dso:debug-everything` Phase 10). Skip the merge script. Report: "Branch already merged to main — skipping merge." **Still push the tickets branch** — ticket-only sessions (brainstorming, bug creation, description enrichment) make no code changes but do modify the tickets orphan branch. Without an explicit push here, those changes are lost when the ephemeral session environment is destroyed:

```bash
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
if [ -d "$TRACKER_DIR" ] && git -C "$TRACKER_DIR" rev-parse --verify origin/tickets &>/dev/null; then
    git -C "$TRACKER_DIR" push origin tickets --quiet 2>&1 || echo "WARNING: tickets branch push failed — ticket changes may be lost"
fi
```

**If unmerged commits exist**: run the merge script. It handles .claude/scripts/dso ticket sync, merge, and push internally. Do NOT prompt for confirmation — proceed directly.

```bash
.claude/scripts/dso merge-to-main.sh ${BUMP_ARG:-}
```

If the script reports ERROR with `CONFLICT_DATA:` prefix (merge conflicts in non-ticket files):
1. Before invoking resolution, capture the current working tree state: run `git status --short` and report to the user: "Merge conflict detected. Current working tree state captured — do not stop the session until Step 4.75 confirms is_clean."
2. Invoke `/dso:resolve-conflicts` to attempt agent-assisted resolution.
3. If resolution succeeds: continue to Step 5.
4. If resolution is abandoned (merge aborted): run `git status --short` immediately and report ALL dirty files to the user before proceeding. Do NOT continue to Step 4.75 silently — the user must confirm their work is intact.

If the script reports a non-conflict ERROR:
1. **Before giving up, diagnose the main repo state.** Run:
   ```bash
   MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir)")
   git -C "$MAIN_REPO" status --short
   ```
2. If the output shows staged or modified files (lines beginning with `M`, `A`, `D`, `R`, `C`, or `??` for non-`.tickets-tracker/` paths):
   - Run `git -C "$MAIN_REPO" reset HEAD` to unstage all staged files.
   - Run `git -C "$MAIN_REPO" checkout .` to discard tracked modifications.
   - Run `git -C "$MAIN_REPO" clean -fd` to remove untracked files.
   - Report to the user: "Cleared stale main repo git state (staged/dirty index). Retrying merge."
   - Retry: `.claude/scripts/dso merge-to-main.sh ${BUMP_ARG:-}`
   - If the retry succeeds: continue to Step 5.
   - If the retry fails: relay the new error message to the user and stop.
3. If the main repo is clean and the error persists: relay the original error message to the user and stop.

> **CRITICAL**: When resolving merge conflicts that involve `.tickets-tracker/` event files, do NOT use `git merge -X ours` — this would silently discard incoming ticket events from main and corrupt the event log. Instead, resolve `.tickets-tracker/` conflicts per-file using `git checkout --ours` on each conflicted JSON event file individually (they are append-only and safe to accept ours per-file). `/dso:resolve-conflicts` handles this automatically.

### 4.5. Sync Tickets to Jira

<!-- Jira sync temporarily disabled — run `.claude/scripts/dso ticket sync` manually when ticket system is stabilized. -->

> **Jira sync temporarily disabled.** Automatic `.claude/scripts/dso ticket sync` invocation has been removed from
> this step to prevent exit-144 timeouts caused by the growing ticket ledger. To sync
> tickets to Jira, run `.claude/scripts/dso ticket sync` manually after the session ends.

Skip this step entirely.

### 4.75. Final Worktree Verification (is_merged + is_clean)

<!-- Mirrors the exact can_remove logic in claude-safe's _offer_worktree_cleanup function.
     Keep these two in sync when either is changed. -->

Verify the worktree satisfies both conditions that `claude-safe`'s `_offer_worktree_cleanup` requires for auto-removal:

```bash
BRANCH=$(git branch --show-current)

# is_merged: exit 0 means the branch is a full ancestor of main.
# Fallback: if merge-base fails (e.g., branch tip was amended after merge),
# check if main has a merge commit referencing this branch name.
if git merge-base --is-ancestor "$BRANCH" main 2>/dev/null; then
    echo "MERGED"
elif git log main --oneline --grep="(merge $BRANCH)" -1 2>/dev/null | grep -q .; then
    echo "MERGED (via merge commit message fallback)"
else
    echo "NOT MERGED"
fi

# is_clean: empty output means no uncommitted changes
git status --porcelain
```

**If both pass** (merge-base exits 0 AND `status --porcelain` is empty):

Report: "Worktree verified clean and merged — claude-safe can auto-remove."

**If either fails**, report the specific failure:

- `merge-base --is-ancestor` returned non-zero → branch has unmerged commits. Show `git log main..HEAD --oneline`. Attempt to merge if the fix is obvious; otherwise ask the user.
- `status --porcelain` is non-empty → uncommitted changes exist. Show the dirty files with `git status --short`. Resolution depends on merge state:
  - **If `is_merged` passed** (branch already merged to main): the dirty files are either already in main or are debug artifacts. Offer to discard them: show the diff summary, then ask the user to confirm discard. If confirmed, run `git checkout .` to restore tracked files and `git clean -fd` to remove untracked files. Do NOT discard without user confirmation.
  - **If `is_merged` failed**: attempt to commit forgotten files if the fix is obvious; otherwise ask the user.

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

### 5.5. Clean Up Artifacts Directory

Remove stale config-cache files from the workflow artifacts directory. These accumulate over sessions (one per unique config path hash) and cause I/O overhead in hooks that scan the directory.

Also remove the `.playwright-cli/` state directory and kill any orphaned Chrome/Chromium browser processes spawned by `@playwright/cli` during this session:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

# Clean up Playwright CLI state directory
if [ -d "$REPO_ROOT/.playwright-cli" ]; then
    rm -rf "$REPO_ROOT/.playwright-cli"
    echo "Removed .playwright-cli/ state directory"
fi

# Kill orphaned Playwright-launched Chrome/Chromium processes
# Uses ERE alternation (bare |, not \|) — macOS pgrep requires ERE syntax
ORPHAN_CHROME=$(pgrep -u "$(id -u)" -f "playwright.*cli.*chromium|chromium.*playwright.*cli|\.playwright-cli.*chrome|ms-playwright.*chromium|chrom.*remote-debugging-pipe|remote-debugging-pipe.*chrom" 2>/dev/null || true)
if [ -n "$ORPHAN_CHROME" ]; then
    CHROME_COUNT=$(echo "$ORPHAN_CHROME" | wc -l | tr -d ' ')
    echo "$ORPHAN_CHROME" | xargs kill 2>/dev/null || true
    echo "Killed $CHROME_COUNT orphaned Playwright browser process(es)"
fi

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

**Rationalized Failures** — display the stored failures from `RATIONALIZED_FAILURES_FROM_2_77` (omit if empty). For each failure, show: the failure description, whether it was pre-existing or session-introduced, and the bug ticket ID created or referenced. If `RATIONALIZED_FAILURES_FROM_2_77` is empty, omit this section entirely.

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
- Resume command (if work remains): `/dso:sprint <epic-id>` or "Run `/dso:debug-everything` again"

**Session Summary**:
- Issues closed (count, with IDs)
- Commits made (count and final SHA on main)
- Branch merged/pushed (or "already merged by prior phase")
- Worktree cleanup status

### 7. Session Complete
