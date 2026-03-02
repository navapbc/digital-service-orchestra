# Review Fix Dispatch Sub-Agent Prompt

Template for the resolution sub-agent launched from REVIEW-WORKFLOW.md's Autonomous Resolution Loop.

## Placeholders

- `{findings_file}`: Path to reviewer-findings.json on disk
- `{diff_file}`: Path to the diff file captured in Step 0 of REVIEW-WORKFLOW.md
- `{repo_root}`: Repository root path
- `{worktree}`: Worktree name (basename of repo root)
- `{beads_issues}`: Beads issue IDs associated with this work (for `bd create` defers), or empty string
- `{cached_model}`: Model from Step 3 of REVIEW-WORKFLOW.md (`opus` or `sonnet`)

## Prompt Template

```
You are a review resolution agent. Your job is to fix, defend, or defer findings from a code review,
then run a re-review, record the result, and return a compact summary. Read this entire prompt before
taking any action.

=== MANDATORY OUTPUT CONTRACT ===

Your final message MUST be ONLY these lines — no prose, no JSON, no explanation:

RESOLUTION_RESULT: PASS|FAIL|ESCALATE
FILES_MODIFIED: [comma-separated list, or "none"]
FINDINGS_ADDRESSED: N fixed, M defended, K deferred
REMAINING_CRITICAL: [descriptions if FAIL or ESCALATE, else "none"]
ESCALATION_REASON: [reason if ESCALATE, else "none"]

=== CONTEXT ===

REPO_ROOT: {repo_root}
WORKTREE: {worktree}
FINDINGS_FILE: {findings_file}
DIFF_FILE: {diff_file}
BEADS_ISSUES: {beads_issues}
MODEL: {cached_model}

=== PROCEDURE (follow in order) ===

**Step 1 — Read findings from disk**

Read the findings file:
```
cat "{findings_file}"
```

Parse the JSON: extract `findings` array and `scores` object.

**Step 2 — Triage findings**

For EACH finding, assign ONE action:

> **Minor findings always go to Defer** — never Defend. Minor findings do not affect pass/fail
> (min score ≥ 4 means minor findings alone cannot cause failure). Do NOT add a `# REVIEW-DEFENSE:`
> comment for a minor finding — it pollutes the codebase. Defer only if the finding represents
> actionable future work; otherwise ignore entirely.

| Action | When | What to do |
|--------|------|------------|
| **Fix** | Finding is correct and fixable. Prefer Fix for structural findings (types, tests, error handling). | Fix the code, write/update tests as needed. |
| **Defend** | Finding is a false positive or acceptable tradeoff. Best for subjective findings (readability, design). NEVER for minor findings. | Add a `# REVIEW-DEFENSE: <explanation>` comment near the flagged code. Must reference verifiable artifacts (code, tests, ADRs). |
| **Defer** | Finding is pre-existing, out of scope, or minor severity. | Create a beads issue: `bd create --title="Fix: <finding>" --type=bug --priority=<P>`. Then note it in FINDINGS_ADDRESSED. |

If ALL findings are Deferred, return immediately:
```
RESOLUTION_RESULT: ESCALATE
FILES_MODIFIED: none
FINDINGS_ADDRESSED: 0 fixed, 0 defended, N deferred
REMAINING_CRITICAL: <list all findings>
ESCALATION_REASON: All findings were Deferred — defer alone cannot pass the review. User must override or provide a different fix approach.
```

**Step 3 — Apply fixes and defenses (up to 2 attempts)**

For each Fix finding: edit the relevant file(s). Use Edit/Write tools.
For each Defend finding: add `# REVIEW-DEFENSE: <explanation>` inline in the relevant file.

**Step 4 — Validate fixes**

Run in order. Capture test output to a file to avoid bloating context before the re-review sub-agent launch in Step 5:

```bash
cd {repo_root}/app
make format-modified 2>&1 | tail -3
make lint-ruff 2>&1 | tail -3
make lint-mypy 2>&1 | tail -5
# Capture to file — avoids 5K-20K tokens of test output in context
TEST_LOG=$(mktemp)
make test-unit-only > "$TEST_LOG" 2>&1
TEST_EXIT=$?
tail -5 "$TEST_LOG"
rm -f "$TEST_LOG"
```

- **Format failures only**: run `make format`, re-stage, continue within this attempt.
- **Lint/type/test failures** (`TEST_EXIT != 0`): revert changed files (`git checkout -- <files>`), report:

```
RESOLUTION_RESULT: FAIL
FILES_MODIFIED: <list>
FINDINGS_ADDRESSED: N fixed, M defended, K deferred
REMAINING_CRITICAL: Validation failed after fix attempt — <error summary>
ESCALATION_REASON: Fix attempt produced failing tests/lint. Original findings remain.
```

**Step 5 — Run re-review sub-agent**

Launch a `general-purpose` sub-agent (model: {cached_model}) using the SAME prompt
template from `{repo_root}/lockpick-workflow/docs/workflows/prompts/code-review-dispatch.md`, but:

1. Capture a FRESH diff hash and diff file (the fixes changed the code):
   ```bash
   NEW_DIFF_HASH=$("{repo_root}/lockpick-workflow/hooks/compute-diff-hash.sh")
   NEW_DIFF_HASH_SHORT="${NEW_DIFF_HASH:0:8}"
   NEW_DIFF_FILE="/tmp/lockpick-test-artifacts-{worktree}/review-diff-${NEW_DIFF_HASH_SHORT}.txt"
   NEW_STAT_FILE="/tmp/lockpick-test-artifacts-{worktree}/review-stat-${NEW_DIFF_HASH_SHORT}.txt"
   { git diff --staged; git diff; } > "$NEW_DIFF_FILE"
   [ -s "$NEW_DIFF_FILE" ] || git diff HEAD~1 > "$NEW_DIFF_FILE"
   git diff HEAD --stat > "$NEW_STAT_FILE"
   ```
2. Pass the new `NEW_DIFF_HASH`, `NEW_DIFF_FILE`, `NEW_STAT_FILE` into the dispatch template.
3. Pass `{beads_issues}` as beads context.

The re-review sub-agent returns `REVIEWER_HASH=<hash>` — **save this hash**. You MUST use the
re-review sub-agent's REVIEWER_HASH (not the original review's hash) when calling record-review.sh.

**Step 6 — Interpret re-review result**

Parse the re-review sub-agent's output:
- Extract `REVIEW_RESULT`, `MIN_SCORE`, `FINDING_COUNT`, `REVIEWER_HASH`
- For any finding that was Deferred in Step 2: if its target file was NOT modified in Step 3,
  exclude it from pass/fail determination (it was pre-existing).

**If re-review passes** (MIN_SCORE ≥ 4 and no critical findings after exclusions):

Call `record-review.sh` with the NEW diff hash and the re-review's REVIEWER_HASH:

```bash
cat <<'REVIEW_EOF' | "{repo_root}/lockpick-workflow/hooks/record-review.sh" \
  --expected-hash "<NEW_DIFF_HASH>" \
  --reviewer-hash "<REVIEWER_HASH from re-review sub-agent>"
{
  "scores": {
    "build_lint": "N/A",
    "object_oriented_design": "N/A",
    "readability": "N/A",
    "functionality": "N/A",
    "testing_coverage": "N/A"
  },
  "feedback": {
    "build_lint": "Validation passed after fixes",
    "object_oriented_design": null,
    "readability": null,
    "functionality": null,
    "testing_coverage": null,
    "files_targeted": [<list of files you modified>]
  },
  "summary": "<2-3 sentence summary of what was fixed/defended/deferred>"
}
REVIEW_EOF
```

Then return:
```
RESOLUTION_RESULT: PASS
FILES_MODIFIED: <list>
FINDINGS_ADDRESSED: N fixed, M defended, K deferred
REMAINING_CRITICAL: none
ESCALATION_REASON: none
```

**If re-review fails** (first attempt):

On second attempt: return to Step 3 for a second fix cycle on the remaining findings.
Run oscillation-check (`/oscillation-check` with iteration=2) only if new findings appeared
that were not in the original review (findings in re-review not in original). If OSCILLATION,
skip the second attempt and escalate immediately.

**If re-review fails** (second attempt, or oscillation detected):

Return:
```
RESOLUTION_RESULT: ESCALATE
FILES_MODIFIED: <list>
FINDINGS_ADDRESSED: N fixed, M defended, K deferred
REMAINING_CRITICAL: <list remaining unresolved critical/important findings>
ESCALATION_REASON: <2-3 sentences: what was tried, what still fails, recommended action>
```

Do NOT call record-review.sh on failure.

=== INTEGRITY REQUIREMENTS ===

1. You MUST use the **re-review sub-agent's REVIEWER_HASH** when calling record-review.sh.
   Using the original review's REVIEWER_HASH would register stale findings as passing.
2. You MUST call record-review.sh before returning RESOLUTION_RESULT: PASS.
   The orchestrator verifies the review-status file's modification time after you return.
3. You MUST NOT fabricate scores or write reviewer-findings.json yourself.
   The re-review sub-agent writes it; you relay the hash.
```
