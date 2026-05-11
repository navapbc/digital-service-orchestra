---
name: end-session
description: Use when wrapping up a worktree session — closing tasks, finishing work, or merging the branch back to main. Closes completed tickets, sweeps orphaned epics, extracts technical learnings, files bug tickets for unfixed failures, commits remaining changes, syncs the tickets branch, merges to main via merge-to-main.sh, verifies the worktree is merged and clean for claude-safe auto-removal, and prints a task summary. Trigger phrases include 'end session', 'wrap up', 'finish', 'done for now', 'close out', 'merge to main and clean up', 'session complete', 'wrap up this branch'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires interactive user session. If running as a sub-agent (dispatched via Task), STOP and return: "ERROR: /dso:end-session requires main session; invoke directly."
</SUB-AGENT-GUARD>

# End Session: Worktree Cleanup and Task Summary

Close out an ephemeral worktree session: close issues, commit, merge to main, push, and report a task summary.

All steps run from the worktree directory — no `cd` needed.

## Arguments

| Argument | Description |
|----------|-------------|
| `--bump <type>` | Forward version bump type (`minor`, `patch`, `major`) to `merge-to-main.sh --bump <type>`. When provided by the caller (e.g., `/dso:sprint` passes `--bump minor`), forward it to the merge script in Step 11. |

Parse arguments at skill activation. If `--bump <type>` is present, store `BUMP_ARG="--bump <type>"` for use in Step 11. If absent, `BUMP_ARG=""`.

## Steps

### 1. Verify Worktree Context

Run `test -f .git`. If `.git` is a directory (not a file), abort: "This command is only for ephemeral worktree sessions."

### 2. Close Completed Issues
1. Run `.claude/scripts/dso ticket list --status=open,in_progress` and `git log main..HEAD --oneline`
2. Cross-reference: which issues were completed based on commits?
3. Ask user which to close. Close confirmed: `.claude/scripts/dso ticket transition <id> open closed` for each. **Bug tickets require** `--reason="Fixed: <summary>"` — omitting it causes a silent failure.
4. **Skip if no in-progress issues** — this is common when called after `/dso:debug-everything` or `/dso:sprint`, which close their own issues. Report: "No in-progress issues to close (already handled)."

### 3. Close Orphaned Epics (safety net)

Catches epics left `in_progress` after `/dso:sprint` is interrupted (context compaction or control-flow issue) even though all children are closed. Enumeration + session-relatedness lives in `check-orphan-epics.sh`; closure decisions stay here.

```bash
.claude/scripts/dso end-session/check-orphan-epics.sh
```

Output is a JSON array `[{epic_id, title, child_status, session_related, match_reason}]`. For each entry:

- `child_status: "no_children"` — skip silently.
- `child_status: "open_children"` — do NOT close. Report it as still in progress.
- `child_status: "all_closed"` AND `session_related: true` — closeable candidate. Confirm with the user that completion criteria are met and the completion verifier was run this session. Close ONLY if the user confirms OR the sprint context passed to end-session includes `overall_verdict: PASS` from a prior completion-verifier dispatch:
  ```bash
  .claude/scripts/dso ticket transition <epic-id> in_progress closed --reason="Epic complete: all children closed (safety-net close by /dso:end-session, verifier confirmed by user)"
  ```
  If the user cannot confirm and no verifier result is available, do NOT close — ask them to run `/dso:sprint` Phase G to complete verification first.
- `child_status: "all_closed"` AND `session_related: false` — report informationally, do not close: `"Note: Epic <epic-id> (<title>) has all children closed but was not worked on in this session. Consider closing it manually."`

### 4. Release debug-everything Session Lock (if held by this worktree)

```bash
.claude/scripts/dso release-debug-lock.sh "Session complete"
```

**If released**: note it in the session summary.
**If not found or belongs to another worktree**: skip silently (one-line report is fine).

### 5. Rationalized Failures Accountability (pre-commit)

Silently scan the conversation context for failures that were observed but not fixed during this session. Store results as `RATIONALIZED_FAILURES_FROM_STEP_5` for display in Step 14.

**Conversation Context Scan**: Review the full conversation for any error output, test failures noted but not fixed, validation issues acknowledged, or rationalization phrases such as "pre-existing", "infrastructure issue", "known issue", "not related to this session". Collect each distinct failure into a numbered list.

**If no failures found**: skip display entirely — store an empty list in `RATIONALIZED_FAILURES_FROM_STEP_5` and proceed silently to Step 6.

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

**Auto-Create Bug Tickets**: For each failure that does **not** have an existing bug ticket, create one. Follow `skills/create-bug/SKILL.md` for title and description format:

```bash
# Title format: [Component]: [Condition] -> [Observed Result]
.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" --priority <priority> -d "## Incident Overview ..."
```

Where `<priority>` is assigned based on actual severity:
- Session-introduced failures: use priority 1 for blocking failures (tests fail, CI would fail, functionality broken), priority 2 for degraded-but-functional issues
- Pre-existing failures: use priority 2 as default; lower to priority 3 for clearly minor issues (cosmetic, flaky tests, non-blocking warnings)

**Store results**: Collect all rationalized failures (with their accountability answers and ticket IDs) into `RATIONALIZED_FAILURES_FROM_STEP_5` for Step 14. If no failures were found, store an empty list.

**This step runs silently** — do not print findings here. Step 14 will display them.

### 6. Extract Technical Learnings (pre-commit)

Silently scan the git diff and conversation context to extract technical learnings before committing. Store the results for display in Step 14.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Gather diff context (unmerged commits + staged/unstaged changes)
GIT_DIFF=$(git diff main..HEAD --stat 2>/dev/null; git diff --stat 2>/dev/null)
```

Review the diff output and conversation history for signal. Identify:
- **Discoveries**: non-obvious findings about how the system behaves.
- **Design decisions**: choices made and why.
- **Gotchas**: edge cases, footguns, or surprising behavior future sessions should know.

**Store the results in a named section** called `LEARNINGS_FROM_STEP_6` for use in Step 14. If nothing substantive is found, store an empty list.

Focus on reusable knowledge. Exclude: workflow phases run, git operations performed, tool usage counts, issue IDs closed.

**This step runs silently** — do not print the learnings here. Step 14 will display them.

### 7. Create Bug Tickets from Learnings (pre-commit)

Review the `LEARNINGS_FROM_STEP_6` list stored in Step 6. For each learning, ask: "Should this be a bug ticket?" Follow `skills/create-bug/SKILL.md` for the required format:

```bash
# Title format: [Component]: [Condition] -> [Observed Result]
.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" --priority <priority> -d "## Incident Overview ..."
```

Create a bug ticket for any learning that describes:
- A defect, regression, or broken behavior that hasn't been fixed yet
- A footgun or edge case that will bite users/developers again if not addressed
- A workaround that was applied instead of a proper fix

**Calibration anchor**: If the conversation log shows that the agent (or user) spent non-trivial time debugging, hit an unexpected error, or applied a workaround, that learning qualifies under criterion 2 or 3 above — do NOT evaluate it as a neutral observation. Do NOT skip a learning that caused real debugging cost just because it has since been understood.

Do NOT create tickets for neutral observations, design decisions, or already-fixed issues.

If no learnings qualify, skip silently. Any tickets created here will be committed and merged as part of the normal `/dso:end-session` flow in Steps 9–11.

### 8. Sweep Error Counters and Validation Failures (pre-commit)

Run both error sweeps before committing so that any tickets created are included in the same commit.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
source "$PLUGIN_SCRIPTS/end-session/error-sweep.sh"  # shim-exempt: source-as-library; shim dispatches subprocesses, not in-shell sources
sweep_tool_errors
sweep_validation_failures
```

`sweep_tool_errors` checks `~/.claude/tool-error-counter.json` for tool-error categories that have accumulated 50 or more occurrences and creates deduplicated bug tickets for them. If the counter file is absent or malformed the step exits 0 silently.

`sweep_validation_failures` reads `$ARTIFACTS_DIR/untracked-validation-failures.log`, extracts unique failure categories, deduplicates against existing open bug tickets, and creates a bug ticket for each untracked category. If the log file is absent or empty the step exits 0 silently.

### 9. Commit Local Changes
1. Run `git status`. If changes exist: read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline (do NOT invoke `/dso:commit` via Skill tool — orchestrators execute the workflow directly).
2. **If clean: skip.** Report: "Working tree clean — nothing to commit."

### 10. Visual Baseline Comparison

1. Read baseline dir from config: `BASELINE_DIR=$(".claude/scripts/dso read-config.sh" visual.baseline_directory 2>/dev/null || true)` — if empty, skip this step (no visual config). Otherwise run `git diff main -- "$BASELINE_DIR" --stat` — if empty, skip this step.
2. Run `.claude/scripts/dso verify-baseline-intent.sh`
3. **Exit 0** → proceed, report the intended baseline changes in the session summary.
4. **Exit 2** → baseline changes with no design manifests. Debug using `/dso:playwright-debug` (Playwright MCP authorized). If regression confirmed: `.claude/scripts/dso ticket create bug "Visual regression: <details>" --priority 1`, run `validate-issues.sh --quick`, STOP, ask user. If changes are expected (manifest was forgotten), ask user to run `/dso:preplanning` on the story (which dispatches `dso:ui-designer` to generate design artifacts) or create the manifest retroactively.

### 11. Sync Tickets and Merge to Main

First, check if the branch has already been merged:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)
git log main..$BRANCH --oneline
```

**If no unmerged commits** (output is empty): the branch was already merged to main by a prior phase (e.g., `/dso:debug-everything` Phase L). Skip the merge script. Report: "Branch already merged to main — skipping merge." **Still push the tickets branch** — ticket-only sessions (brainstorming, bug creation, description enrichment) make no code changes but do modify the tickets orphan branch. Without an explicit push here, those changes are lost when the ephemeral session environment is destroyed:

```bash
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"  # tickets-boundary-ok: load-bearing — push tickets branch when merge script is skipped
if [ -d "$TRACKER_DIR" ] && git -C "$TRACKER_DIR" rev-parse --verify origin/tickets &>/dev/null; then
    PRE_COMMIT_ALLOW_NO_CONFIG=1 git -C "$TRACKER_DIR" push origin tickets --quiet 2>&1 || echo "WARNING: tickets branch push failed — ticket changes may be lost"
fi
```

**If unmerged commits exist**: run the merge script. It handles .claude/scripts/dso ticket sync, merge, and push internally. Do NOT prompt for confirmation — proceed directly.

**Before running**: verify the shim can dispatch merge-to-main.sh by checking it exists:
```bash
ls .claude/scripts/dso 2>/dev/null && .claude/scripts/dso merge-to-main.sh --help 2>&1 | head -2 || true
```
If the shim is missing or the dispatch fails with "command not found" (b068-94b4): do NOT perform a manual merge. Stop and report: "Error: .claude/scripts/dso shim not found or merge-to-main.sh not available. Run: bash scripts/update-shim.sh to update the shim, then retry." Never manually merge as a fallback — the DSO merge workflow ensures proper state management (ticket sync, version bump, CI trigger). # shim-exempt: update-shim.sh must be called directly when the shim itself is missing

```bash
.claude/scripts/dso merge-to-main.sh ${BUMP_ARG:-}
```

After merge-to-main.sh completes successfully, write a WORKTREE_TRACKING:landed signal:
```
.claude/scripts/dso ticket comment $TICKET_ID "WORKTREE_TRACKING:landed branch=<session_branch> timestamp=<ts>"
```
(Only when TICKET_ID context is available. Skip silently if not set.)

**On error from `merge-to-main.sh`** — load `${CLAUDE_PLUGIN_ROOT}/skills/end-session/prompts/merge-error-handling.md` and follow it. It covers `ESCALATE:` (retry budget exhausted — STOP and surface to user), `CONFLICT_DATA:` (merge conflicts — invoke `/dso:resolve-conflicts`, with critical guidance about ticket-tracker conflict resolution), and non-conflict `ERROR` (diagnose main repo dirty state, clean, retry once).

### 12. Final Worktree Verification (is_merged + is_clean)

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
elif git fetch origin main:main 2>/dev/null && git merge-base --is-ancestor "$BRANCH" main 2>/dev/null; then
    echo "MERGED (local main ref synced from origin — was out of sync after direct push)"
    # If fetch fails (no network), this elif is skipped — conservative fail-safe; worktree stays until next session with network.
elif gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null | grep -q "^MERGED$"; then
    echo "MERGED (via GitHub PR state — squash merge detected; branch tip is not a Git ancestor)"
    # Squash merges create a new commit on main that does not include original branch commits as ancestors.
    # git merge-base --is-ancestor is strictly correct to return false; gh pr view is the authoritative check.
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

Re-run both checks after any resolution attempt. Do not proceed to Step 13 until both pass.

### 13. Clean Up Artifacts Directory

Removes the `.playwright-cli/` state directory, kills orphaned `@playwright/cli`-spawned browser processes, and deletes hash-suffixed `config-cache-*` files from the artifacts directory. The primary `config-cache` file (no suffix) is preserved.

```bash
.claude/scripts/dso end-session/end-session-cleanup.sh
```

### 14. Report: Task Summary and Completion

Display a session summary using the stored lists from Steps 5 and 6 — do NOT re-scan the diff or conversation.

**Rationalized Failures** (omit if `RATIONALIZED_FAILURES_FROM_STEP_5` is empty): per failure, show the description, pre-existing vs session-introduced, and the bug ticket ID created or referenced.

**Technical Learnings** (omit if `LEARNINGS_FROM_STEP_6` is empty): show **Discoveries** (non-obvious system behavior), **Design decisions** (choices and why), **Gotchas** (edge cases / footguns).

**Task Summary**:
- Epic ID and title (if `/dso:sprint` or `/dso:debug-everything` was running).
- Tasks completed this session: `git log main..HEAD --oneline`; if empty (already merged), inspect `git log --oneline -20 main` and identify commits from this worktree by their merge commit messages.
- Tasks remaining (IDs, titles, blocked status if known).
- Resume command if work remains: `/dso:sprint <epic-id>` or "Run `/dso:debug-everything` again".

**Session Summary**: issues closed (count + IDs), commits made (count + final SHA on main), branch merged/pushed (or "already merged by prior phase"), worktree cleanup status.
