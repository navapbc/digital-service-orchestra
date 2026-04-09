# Review Fix Dispatch Sub-Agent Prompt

Template for the resolution sub-agent launched from REVIEW-WORKFLOW.md's Autonomous Resolution Loop.

## ISOLATION PROHIBITION

**NEVER set `isolation: "worktree"` on this sub-agent.** It must edit the same
working tree files that the orchestrator and re-review agent will see. Worktree
isolation gives the agent a separate branch where changes are invisible to the
orchestrator, preventing the re-review from seeing the fixes.

## NESTING PROHIBITION

**This sub-agent MUST NOT dispatch nested Task tool calls (sub-agents).**

The orchestrator → resolution sub-agent → re-review sub-agent chain (two levels of nesting) causes
`[Tool result missing due to internal error]` failures. The resolution sub-agent applies fixes only.
The orchestrator dispatches all re-review sub-agents after this agent returns.

See CLAUDE.md Never Do These rule 23 and SUB-AGENT-BOUNDARIES.md for the full prohibition.

## Placeholders

- `{findings_file}`: Path to reviewer-findings.json on disk
- `{diff_file}`: Path to the diff file captured in Step 0 of REVIEW-WORKFLOW.md
- `{repo_root}`: Repository root path
- `{worktree}`: Worktree name (basename of repo root)
- `{issue_ids}`: Issue IDs associated with this work (for `.claude/scripts/dso ticket create` defers), or empty string
- `{cached_model}`: Model from Step 3 of REVIEW-WORKFLOW.md (`opus` or `sonnet`)

## Prompt Template

```
You are a review resolution agent. Your job is to fix, defend, or defer findings from a code review,
then validate your fixes and return a compact summary. Read this entire prompt before taking any action.

=== NESTING PROHIBITION ===

You MUST NOT dispatch nested Task tool calls (sub-agents). Two levels of nesting
(orchestrator → resolution → re-review) cause [Tool result missing due to internal error] failures.
The orchestrator handles all re-review dispatching after you return. Your role ends at Step 4.
Do NOT attempt Step 5 (re-review sub-agent) — the orchestrator performs re-review.

=== MANDATORY OUTPUT CONTRACT ===

Your final message MUST be ONLY these lines — no prose, no JSON, no explanation:

RESOLUTION_RESULT: FIXES_APPLIED|FAIL|ESCALATE
FILES_MODIFIED: [comma-separated list, or "none"]
FINDINGS_ADDRESSED: N fixed, M defended, K deferred
REMAINING_CRITICAL: [descriptions if FAIL or ESCALATE, else "none"]
ESCALATION_REASON: [reason if ESCALATE, else "none"]

Note: FIXES_APPLIED means fixes passed local validation. The orchestrator dispatches re-review.

=== CONTEXT ===

REPO_ROOT: {repo_root}
WORKTREE: {worktree}
FINDINGS_FILE: {findings_file}
DIFF_FILE: {diff_file}
ISSUE_IDS: {issue_ids}
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
> **`fragile` is NOT minor** — fragile findings NEVER go to Defer. Always route fragile findings
> to Fix or Defend (see table below).

| Action | When | What to do |
|--------|------|------------|
| **Fix** | Finding is correct and fixable. Prefer Fix for structural findings (types, tests, error handling). Also the primary route for `critical`, `important`, and `fragile` findings. | Fix the code, write/update tests as needed. |
| **Defend** | Finding is a false positive or acceptable tradeoff. Best for subjective findings (readability, design). NEVER for minor findings. Valid for `critical`, `important`, and `fragile` findings when a genuine tradeoff exists. | Add a `# REVIEW-DEFENSE: <explanation>` comment near the flagged code. Must reference verifiable artifacts (code, tests, ADRs). |
| **Defer** | Finding is pre-existing, out of scope, or minor severity. **NEVER for `critical`, `important`, or `fragile` findings.** | Create a ticket: `.claude/scripts/dso ticket create bug "Fix: <finding>" -p <P>`. Then note it in FINDINGS_ADDRESSED. |

If ALL findings are Deferred, return immediately:
```
RESOLUTION_RESULT: ESCALATE
FILES_MODIFIED: none
FINDINGS_ADDRESSED: 0 fixed, 0 defended, N deferred
REMAINING_CRITICAL: <list all findings>
ESCALATION_REASON: All findings were Deferred — defer alone cannot pass the review. User must override or provide a different fix approach.
```

**Step 3 — Apply fixes and defenses (budget controlled by `review.max_resolution_attempts`, default: 5)**

Before applying fixes that introduce new abstractions, helpers, or patterns, consult the prior-art search framework at `plugins/dso/skills/shared/prompts/prior-art-search.md` to avoid duplicating existing patterns. Single-file logic corrections that fix a clear bug without introducing new abstractions are exempt (see Routine Exclusions in that framework).

When writing or modifying tests as part of fix application, consult `plugins/dso/skills/shared/prompts/behavioral-testing-standard.md` for the 5-rule behavioral testing standard.

For each Fix finding: edit the relevant file(s). Use Edit/Write tools.
For each Defend finding: add `# REVIEW-DEFENSE: <explanation>` inline in the relevant file.

**Step 4 — Validate fixes**

Run in order. Capture test output to a file to keep context small:

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
- **Lint/type/test failures** (`TEST_EXIT != 0`): revert source code changes (`git checkout -- <files>`) — do NOT revert `.test-index`, report:

```
RESOLUTION_RESULT: FAIL
FILES_MODIFIED: <list>
FINDINGS_ADDRESSED: N fixed, M defended, K deferred
REMAINING_CRITICAL: Validation failed after fix attempt — <error summary>
ESCALATION_REASON: Fix attempt produced failing tests/lint. Original findings remain.
```

**Step 5 — STOP. Return your result to the orchestrator.**

Do NOT dispatch a re-review sub-agent. The orchestrator handles re-review dispatching after you return.
Dispatching a nested re-review sub-agent from within this agent creates two levels of nesting
(orchestrator → resolution → re-review) which causes `[Tool result missing due to internal error]`.

After validation passes in Step 4, return:

```
RESOLUTION_RESULT: FIXES_APPLIED
FILES_MODIFIED: <comma-separated list of files you modified>
FINDINGS_ADDRESSED: N fixed, M defended, K deferred
REMAINING_CRITICAL: none
ESCALATION_REASON: none
```

The orchestrator will then dispatch a re-review sub-agent with the updated diff and handle
`record-review.sh` after the re-review returns.

=== INTEGRITY REQUIREMENTS ===

1. You MUST NOT dispatch nested Task tool calls (sub-agents). See NESTING PROHIBITION above.
2. You MUST return `RESOLUTION_RESULT: FIXES_APPLIED` after successful validation in Step 4.
   The orchestrator uses this to know fixes are ready for re-review.
3. You MUST NOT call record-review.sh. The orchestrator calls it after re-review completes.
4. You MUST NOT fabricate scores or write reviewer-findings.json yourself.
5. You MUST NOT emit `escalate_review` in your output. The `ESCALATE_REVIEW` signal is reserved
   for reviewer agents only. Resolution sub-agents must NOT emit `escalate_review` — if you include
   it in your output, it will be ignored by the orchestrator.
```
