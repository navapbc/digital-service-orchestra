# PR Finalize Workflow

Drive a PR opened by `merge-to-main.sh` through to merge in a **local session** where the session agent IS the LLM dispatch (no external `_LLM_DISPATCH_CMD` helper).

## When to read this doc

Read and execute this workflow whenever `merge-to-main.sh` has opened a PR but exits before the PR is merged — i.e., the script emitted `ESCALATE:` for any of: thread resolution, CI remediation, conflict resolution, or simply returned after the push/open-PR phase in PR-merge-strategy mode. Also read it when the user explicitly asks to "finish merging the PR" or "drive PR #N to merge."

## Prerequisites

- A PR exists. If unsure, run `gh pr view <number>` or `gh pr list --head $(git branch --show-current)`.
- `gh` CLI authenticated.
- **Current branch matches the PR's head branch.** Before entering the loop, verify:
  ```bash
  CURRENT=$(git branch --show-current)
  HEAD_REF=$(gh pr view <pr-number> --json headRefName --jq .headRefName)
  [[ "$CURRENT" == "$HEAD_REF" ]] || { echo "ESCALATE: on branch $CURRENT but PR <pr-number> is on $HEAD_REF — switch or escalate"; exit 1; }
  ```
  Agent actions (push, merge main into branch, resolve conflicts) operate on the current branch. Running the loop from a wrong branch will push fixes to the wrong place and corrupt state.
- Working tree clean before entering the loop (no staged or unstaged changes from unrelated work).

## Loop

Drive the PR via the classifier + agent-action loop until the classifier returns `MERGED` or the agent escalates a blocker the session cannot resolve.

```bash
.claude/scripts/dso pr-finalize-classify.sh <pr-number>
```

The classifier returns a single JSON object on stdout. Switch on its `status` field:

| status | Agent action |
|---|---|
| `MERGED` | Stop. Report SHA + URL to the user. |
| `CONFLICTING` | See **Resolve Conflicts** below. After resolving + pushing, re-classify. |
| `CHECKS_FAILED` | See **Fix Failing Checks** below. After fixing + pushing, re-classify. |
| `THREADS_UNRESOLVED` | See **Address Review Threads** below. After addressing + pushing, re-classify. |
| `CHECKS_PENDING` | Wait 60–120s, then re-classify. Do not push speculative changes. |
| `READY_TO_MERGE` | Run `gh pr merge <pr-number> --squash` (or the project's configured strategy). **Verify by re-classifying** — if status is not `MERGED` after the call, inspect the merge command's stderr: `behind main` → fetch+merge+push then re-classify; `checks not passing` → re-classify (likely a check transitioned to failing); `review required` → escalate. Do not assume merge succeeded without confirmation. |
| `BLOCKED_BY_REVIEW` | Stop and escalate to user — typically a required reviewer needs to approve; the agent cannot resolve this autonomously. Report what's blocking. |
| `UNKNOWN` | Stop and escalate to user with the classifier's raw output. |

### Bounded loop

- **Per-iteration sleep on `CHECKS_PENDING`**: 60s default, 120s max. Do not exceed 30 minutes of total wall-clock waiting on pending checks without escalating.
- **Per-PR maximum iterations**: 15. If the loop exceeds this, escalate to user with the last classifier output — there is likely a stable failure the agent cannot resolve.
- **Same-failure detection**: track the last failing-check name and the last unresolved-thread IDs you addressed. If the same item recurs three times after a fix attempt, escalate (cascade-recovery territory).

## Resolve Conflicts

```bash
git fetch origin main
git merge origin/main --no-commit --no-ff
```

- **Clean auto-merge**: review with `git status` and `git diff --cached`, then commit the merge with a message naming what was merged. Push.
- **Conflicts**: read the conflicted files. Apply the resolution by editing the files (not via `git checkout --theirs/--ours` unless the choice is obvious). For each conflict, decide whether main's version, this branch's version, or a hybrid is correct — prefer the more recent / better-reasoned change. Commit + push.

Use `/dso:resolve-conflicts` if available and the conflicts are non-trivial.

## Fix Failing Checks

The classifier's `payload.failing_checks` is `[{name, conclusion, run_url}, ...]`.

For each:

1. Fetch the run log: `gh run view <run-id> --log-failed` (extract `<run-id>` from `run_url`).
2. Identify the category from the check `name`:
   - **Unit/integration test failures** → dispatch `/dso:fix-bug` with the failing test name + log excerpt. After it returns, push.
   - **Lint / type errors** → fix inline (read the offending file, apply the suggested fix or correct manually). Push.
   - **llm-review findings** → read the findings, apply each per the existing review-defenses protocol (REVIEW-WORKFLOW.md). Push.
   - **Build / packaging** → investigate the build log; usually a missing dependency, path mismatch, or CI-only environment issue. Fix and push.
   - **Security scanning (CodeQL, Semgrep)** → read the finding, evaluate severity, fix or document a justified exception. Push.

3. **Never push speculative changes.** If the cause is unclear from the log, fetch additional context (file the test references, related source) before attempting a fix.

## Address Review Threads

The classifier's `payload.threads` is `[{id, file, line, author, body}, ...]`.

**Batch all threads into ONE push per iteration.** Do NOT push after fixing each thread — multiple consecutive pushes cancel each other's CI runs (`cancel-in-progress: true` on `github.ref`). Apply all code fixes, then push once. See COMMIT-WORKFLOW.md "Pacing Pushes to Avoid CI Cancellation" — when CI is already in flight on the branch, prefer `git commit --amend --no-edit && git push --force-with-lease` over a new commit, so the previous run is replaced rather than cancelled.

For each unresolved thread:

1. **Read the thread context**: open `file:line` in the working tree, read the comment body.
2. **Categorize**:
   - **Defense-worthy** (reviewer asked for a fix you have evidence against): post a reply via `gh api graphql` referencing the evidence, then explicitly resolve the thread (step 3).
   - **Code fix needed**: apply the fix in the working tree. Do NOT push yet — accumulate fixes across all threads in this iteration.
   - **Discussion / question**: reply via `gh api graphql`. If no code change is needed, explicitly resolve the thread after replying.
3. **Always explicitly resolve the thread after addressing it** — do NOT rely on GitHub auto-resolving from line changes:
   ```bash
   gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"<id>"}){thread{isResolved}}}'
   ```
   Auto-resolve only fires when the exact lines the thread was anchored to are removed/replaced. Edits near (but not at) those lines leave the thread open. Explicit resolution prevents the loop re-detecting the same thread on the next iteration.

After all threads in this iteration are addressed:
- If code fixes were made: commit all of them in ONE commit (or amend the last commit on the branch if no third party has based work on it), push once.
- Re-classify.

## Escalation

When escalating to the user, emit a single block containing:
- PR URL.
- The classifier status that triggered escalation.
- A concise description of what was attempted and why it failed.
- A specific question or decision the user needs to provide.

Do NOT silently exit the loop. Do NOT keep retrying the same failed fix indefinitely.

## Notes

- This workflow assumes the session has `git` + `gh` available and is checked out on the PR's head branch.
- The classifier is read-only — it never modifies the repo. Only the agent's actions between classifier calls modify state.
- The classifier is deliberately single-shot (not a polling loop itself) so the agent controls pacing, can interleave other work, and so test/dryrun harnesses can stub one iteration at a time.
- If `merge-to-main.sh` later grows a `--finalize` mode that calls this workflow inline, this doc becomes the canonical reference for that mode's loop body.
