---
name: respond-to-pr-comments
description: Use when an engineer wants to classify and respond to all unresolved PR review comments on a pull request. Fetches unresolved comments, classifies each as accept/defend/defer using an embedded LLM prompt, dispatches the appropriate action handler, and prints a summary table. Trigger phrases include 'respond to PR comments', 'address PR comments', 'handle PR feedback', 'respond to review comments', 'respond to my PR', '/dso:respond-to-pr-comments'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Respond to PR Comments

Orchestrates the full comment-response pipeline for a GitHub pull request: fetches all unresolved review comments, classifies each one with an embedded LLM prompt, and dispatches the accept, defend, or defer action handler accordingly. Prints a summary table when done.

## Invocation

```
/dso:respond-to-pr-comments <PR-URL-or-number>
```

Examples:
- `/dso:respond-to-pr-comments 42`
- `/dso:respond-to-pr-comments https://github.com/owner/repo/pull/42`

## Concurrency Warning

Concurrent invocations on the same PR may both fetch comments before either has posted replies. The `<!-- dso-agent-reply -->` sentinel prevents double-posting on sequential runs but does NOT prevent double-processing within concurrent runs. If another invocation is running on this PR, wait for it to complete before invoking this skill.

## Steps

### Step 1 — Parse the PR argument

Accept either a full GitHub PR URL or a bare PR number.

If a full URL is provided, extract the PR number with:
```bash
PR_NUMBER=$(echo "$1" | grep -oE '[0-9]+$')
```

If a bare number is provided, use it directly. If neither pattern matches, print:
```
ERROR: Expected a PR number (e.g. 42) or a GitHub PR URL (e.g. https://github.com/owner/repo/pull/42).
```
and stop.

### Step 2 — Fetch and normalize PR comments

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
NORMALIZED_JSON=$(mktemp "/tmp/dso-pr-normalized.XXXXXX")
"$REPO_ROOT/.claude/scripts/dso" pr-comment-response \
    --pr-number "$PR_NUMBER" \
    --output "$NORMALIZED_JSON"
fetch_rc=$?
```

If `fetch_rc` is non-zero, print the error from the script and stop.

Read the output:
```bash
COMMENTS_JSON=$(cat "$NORMALIZED_JSON")
COMMENT_COUNT=$(echo "$COMMENTS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['comments']))")
SKIPPED_COUNT=$(echo "$COMMENTS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('skipped_count',0))")
```

If `COMMENT_COUNT` is 0, print:
```
No unresolved comments found on PR #<PR_NUMBER>.
```
(including the skipped count if > 0: `(N already-replied threads skipped)`) and stop.

### Step 3 — Classify each comment

For each comment in the normalized JSON, apply the classification prompt below to determine the action.

**Classification prompt** (apply this reasoning for each comment body):

> You are classifying a GitHub PR review comment to determine the appropriate automated response.
>
> Comment body:
> """
> {comment_body}
> """
>
> Classify as exactly one of:
>
> **accept** — The engineer is requesting a specific, actionable code change. The request is unambiguous: a concrete edit, rename, refactor, or fix is clearly described. The change can be implemented in the PR's current scope without architectural discussion.
>
> **defend** — The existing design is justifiable with codebase evidence. The comment raises a concern, asks a question about a design choice, or suggests an alternative that the current implementation already addresses or consciously decided against. You can produce a well-reasoned, evidence-backed argument that the current approach is correct.
>
> **defer** — The comment is out-of-scope, requires cross-team coordination, is ambiguous, is a general discussion point without a specific ask, or you cannot confidently classify it as accept or defend. When in doubt, defer.
>
> **Rules:**
> - Default to defer for any ambiguous case.
> - For defend: output the classification label AND a defense argument — a 1–3 sentence codebase-backed justification explaining why the current design is correct. This text will be posted as a PR review comment.
> - For accept and defer: output only the classification label.
>
> **Output format** (strict JSON, no prose outside the JSON):
> ```json
> {
>   "classification": "accept" | "defend" | "defer",
>   "defense_argument": "<only present when classification=defend; 1–3 sentence justification>"
> }
> ```

Apply this classification to each comment. If the LLM output is not valid JSON or does not contain a valid `classification` field, default to `defer`.

Collect results into a list: `[{comment_id, classification, defense_argument?}, ...]`

### Step 4 — Dispatch action handlers

For each classified comment, call `pr-comment-response.sh` with the `--classify-as` flag to invoke the appropriate handler:

```bash
for each classified comment:
    ACTION="<accept|defend|defer>"
    "$REPO_ROOT/.claude/scripts/dso" pr-comment-response \
        --pr-number "$PR_NUMBER" \
        --output "$NORMALIZED_JSON" \
        --classify-as "<comment_id>:<action>"
```

**For defend-classified comments only**: Before dispatching, write the `defense_argument` text from the classification step into the normalized JSON so that `_handle_defend` can read it. Update the `body` field of the matching comment entry in the JSON with the defense argument text — the defend handler reads `body` as the defense text to post.

If an action handler exits non-zero, record the error in the summary table (action: `ERROR`) and continue with remaining comments.

### Step 5 — Print summary table

After all comments are processed, print a summary table:

```
PR #<N> comment response summary
─────────────────────────────────────────────────────────────────────
 Comment ID        Classification  Action Taken
─────────────────────────────────────────────────────────────────────
 <comment_id>      accept          Fix applied and pushed (SHA: <sha>)
 <comment_id>      defend          Defense posted as review comment
 <comment_id>      defer           Tracking ticket created (<ticket_id>)
 <comment_id>      defer           ERROR: <error message>
─────────────────────────────────────────────────────────────────────
Total: N comments processed (<N_skipped> already-replied threads skipped)
```

Column widths: comment_id 20 chars, classification 16 chars, action taken remainder.

If `SKIPPED_COUNT` is 0, omit the parenthetical from the Total line.

### Step 6 — Cleanup

Remove the temporary normalized JSON file:
```bash
rm -f "$NORMALIZED_JSON"
```
