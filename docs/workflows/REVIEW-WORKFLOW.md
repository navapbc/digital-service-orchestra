# Code Review Workflow

Review the current code diff using a `superpowers:code-reviewer` sub-agent for deep analysis of bugs, logic errors, security vulnerabilities, code quality, and adherence to project conventions.

**CRITICAL**: Steps 0-5 are mandatory and sequential. You MUST dispatch the code-reviewer sub-agent in Step 4. Skipping the sub-agent and recording review JSON directly is fabrication — it violates CLAUDE.md rule #15 regardless of how "simple" the changes appear.

**This workflow reviews CODE (diffs, commits). To review a PLAN or DESIGN, use `/plan-review` instead.** See CLAUDE.md "Always Do These" rule 10 for the review routing table.

---

## Step 0: Gather Context

Capture the diff NOW and save it to a hash-stamped temp file. Sub-agents read the diff from this file instead of receiving it inline.

1. **Capture the diff hash** for later verification:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   WORKTREE=$(basename "$REPO_ROOT")
   ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-${WORKTREE}"
   mkdir -p "$ARTIFACTS_DIR"
   DIFF_HASH=$("$REPO_ROOT/.claude/hooks/compute-diff-hash.sh")
   DIFF_HASH_SHORT="${DIFF_HASH:0:8}"
   ```

2. **Capture the diff to a hash-stamped file** (not inline in context):
   ```bash
   DIFF_FILE="$ARTIFACTS_DIR/review-diff-${DIFF_HASH_SHORT}.txt"
   STAT_FILE="$ARTIFACTS_DIR/review-stat-${DIFF_HASH_SHORT}.txt"
   { git diff --staged; git diff; } > "$DIFF_FILE"
   # If both empty, fall back to last commit
   [ -s "$DIFF_FILE" ] || git diff HEAD~1 > "$DIFF_FILE"
   git diff HEAD --stat > "$STAT_FILE"
   ```

3. **Read only the stat file** into context (small). Do NOT cat/read the full diff file — the sub-agent reads it from disk.

4. Store `DIFF_HASH`, `DIFF_FILE`, and `STAT_FILE` paths for use in Steps 3-5.

**Note**: The diff hash includes both staged and unstaged changes. Callers must stage all intended files before invoking this workflow to avoid hash drift at commit time.

## Step 1: Validate (conditional)

**Skip check**: If a validation state file exists and is fresh (< 60 seconds old), skip Step 1 and go directly to Step 3:

```bash
VALIDATION_STATUS="$ARTIFACTS_DIR/validation-status"
if [ -f "$VALIDATION_STATUS" ]; then
    status_content=$(head -n 1 "$VALIDATION_STATUS")
    status_age=$(( $(date +%s) - $(stat -f %m "$VALIDATION_STATUS" 2>/dev/null || stat -c %Y "$VALIDATION_STATUS" 2>/dev/null || echo 0) ))
    if [ "$status_content" = "passed" ] && [ "$status_age" -lt 60 ]; then
        # Validation is fresh — skip to Step 3
    fi
fi
```

If the file is missing, stale (>60s), or shows "failed", execute Step 1 as normal:

Run these checks in order. The code is sound before the review sub-agent sees it.

1. **Lint check**: `cd app && make lint-ruff 2>&1 | tail -3` (on success, only summary needed; re-run with full output on failure)
2. **Type check**: `cd app && make lint-mypy 2>&1 | tail -5` (on success, only summary needed; re-run with full output on failure)
3. **Unit tests**: `cd app && make test-unit-only 2>&1 | tail -5` (on success, only summary needed; re-run with full output on failure)

If Docker is not available, use `python3 -m py_compile` on changed Python files as a lint fallback.

**If any check fails:**
- Do NOT proceed with the code review
- Fix the issue and restart from Step 0

## Step 3: Determine Model

Scan changed files (`git diff HEAD --name-only`) for high-blast-radius patterns:

- `.claude/skills/**`
- `.claude/workflows/**`
- `.claude/hooks/**`
- `.claude/docs/**`
- `CLAUDE.md`
- `.github/workflows/**`
- `scripts/**`
- `.pre-commit-config.yaml`
- `Makefile`

If **any** changed file matches one of the patterns above -> `model="opus"`.
If **none** match -> `model="sonnet"`.

## Step 4: Dispatch Code Review Sub-Agent (MANDATORY)

**You MUST launch a sub-agent.** There are no exceptions — not for documentation-only changes, not for "trivial" changes, not for config files. The sub-agent performs the review and assigns scores. Skipping this step and writing review JSON yourself is fabrication.

Launch a `superpowers:code-reviewer` sub-agent using the Task tool. This agent type has Bash access, which is required to write `reviewer-findings.json` and compute its hash.

Read the prompt template at `$REPO_ROOT/.claude/workflows/prompts/code-review-dispatch.md` and fill in placeholders:
- `{working_directory}`: current working directory
- `{diff_stat}`: content of the stat file from Step 0/2
- `{diff_file_path}`: the `DIFF_FILE` path from Step 0/2
- `{repo_root}`: `REPO_ROOT` value
- `{beads_context}`: Beads issue context (see below)

**Resolving `{beads_context}`**: If a beads issue ID is known for the current work (e.g., passed from `/sprint`, present in the task prompt, or tracked by the orchestrator), populate this placeholder with:

```
=== BEADS ISSUE CONTEXT ===
This change is for beads issue {issue_id}.
To view full issue details, run: bd show {issue_id}
```

If no beads issue is associated with the current work, set `{beads_context}` to an empty string.

**If you have already read `code-review-dispatch.md` earlier in this conversation and have not compacted since, use the version in context.**

```
Task tool:
  subagent_type: "superpowers:code-reviewer"
  model: "{opus or sonnet from Step 3}"
  description: "Review code changes"
  prompt: <filled template from code-review-dispatch.md>
```

**Retry on malformed output:** If the sub-agent does not return the fixed format (`REVIEW_RESULT:`, `REVIEWER_HASH=`, etc.) or does not include `REVIEWER_HASH=`, re-dispatch with a correction prompt. Never fabricate scores.

**NO-FIX RULE**: After dispatching the sub-agent in this step, you (the orchestrator) MUST NOT use Edit, Write, or Bash to modify any files until Step 5 is complete. Any file modification between dispatch and recording invalidates the diff hash and will be rejected by `--expected-hash`.

## Step 5: Record Review

**Prerequisite**: You MUST have a sub-agent result from Step 4. If you do not have a Task tool result to reference, STOP — you skipped Step 4.

### Extract sub-agent output

1. Extract `REVIEWER_HASH=<hash>` from the sub-agent's fixed-format Task tool return value.
2. Extract `REVIEW_RESULT` (passed/failed), `FINDING_COUNT`, and `FILES` for constructing `feedback` and `files_targeted`.
3. If the review failed and you need finding details, read `reviewer-findings.json` from disk:
   ```bash
   WORKTREE=$(basename "$(git rev-parse --show-toplevel)")
   FINDINGS_FILE="/tmp/lockpick-test-artifacts-${WORKTREE}/reviewer-findings.json"
   cat "$FINDINGS_FILE" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'[{f[\"severity\"]}] {f[\"category\"]}: {f[\"description\"]}') for f in d['findings'] if f['severity'] in ('critical','important')]"
   ```

### Relay Rules

The orchestrator's role is reduced to relaying — not translating — the sub-agent's review. Scores come exclusively from the reviewer's temp file (`reviewer-findings.json`), not from the orchestrator's JSON.

- **R1 - No score relay**: Set ALL scores to `"N/A"` in the orchestrator's JSON. `record-review.sh` reads actual scores from the reviewer's temp file. The orchestrator does NOT determine pass/fail.
- **R2 - No dismissal**: "Pre-existing", "not a runtime bug", "trivial/cosmetic" are not valid grounds for dismissing findings. Create tracking beads issues for pre-existing problems instead.
- **R3 - Critical/important resolution**: Any critical or important finding triggers the Autonomous Resolution Loop (see "After Review").
- **R4 - Verbatim severity**: The summary must reference the reviewer's severity levels exactly as stated. Do not downgrade or rephrase severity.
- **R5 - Defense mechanism**: To dispute a finding without user involvement, the orchestrator MUST add a **code-visible defense** — an inline comment with the `# REVIEW-DEFENSE:` prefix, a docstring addition, or a type annotation that explains the design rationale to the reviewer. The orchestrator MUST NOT silently dismiss findings, override scores, or add comments that merely suppress warnings without explanation. Defense comments must reference verifiable artifacts (existing code, tests, ADRs, or documented patterns) — not unverifiable claims like "for performance reasons." The defense must be substantive enough that a human reading the code would understand the tradeoff. **Structural findings** (type annotations, test coverage gaps, missing error handling) should prefer Fix over Defend — the reviewer scores these based on code patterns, and a comment is unlikely to change the score.

### Record the review

Construct the JSON and pipe it into `record-review.sh` with `--expected-hash` from Step 0/2 and `--reviewer-hash` from the sub-agent output:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cat <<'REVIEW_EOF' | "$REPO_ROOT/.claude/hooks/record-review.sh" \
  --expected-hash "<DIFF_HASH from Step 0/2>" \
  --reviewer-hash "<REVIEWER_HASH from sub-agent>"
{
  "scores": {
    "build_lint": "N/A",
    "object_oriented_design": "N/A",
    "readability": "N/A",
    "functionality": "N/A",
    "testing_coverage": "N/A"
  },
  "feedback": {
    "build_lint": "<lint result from Step 1>",
    "object_oriented_design": "<feedback from code-reviewer or null>",
    "readability": "<feedback from code-reviewer or null>",
    "functionality": "<feedback from code-reviewer or null>",
    "testing_coverage": "<feedback from code-reviewer or null>",
    "files_targeted": ["<files from sub-agent FILES line>"]
  },
  "summary": "<2-3 sentence assessment using reviewer's exact severity levels>"
}
REVIEW_EOF
```

If build/lint failed (Step 1), set `build_lint: "N/A"`, all others `"N/A"`, and summary: `"BLOCKED: Build/lint checks failed."`.

`record-review.sh` validates JSON structure, summary, `files_targeted` overlap with actual diff, `--expected-hash` match, reads scores from `reviewer-findings.json`, verifies `--reviewer-hash` integrity, cross-validates findings against scores, and writes the review state file that the commit gate checks. If it rejects the input, fix and retry.

## After Review

### If ALL scores are 4, 5, or "N/A" AND no critical findings:
Review passed. Return control to the caller. Important findings do not automatically fail — the reviewer uses judgment (score 3-4) for important findings.

### If ANY score is below 4, OR any critical finding exists:
Review failed. Enter the Autonomous Resolution Loop. Critical findings always fail regardless of score.

#### Autonomous Resolution Loop

The orchestrator gets up to **2 autonomous resolution attempts** before escalating to the user. Each attempt is a full cycle: triage findings → act → re-review.

**Re-review optimization:** On re-review, skip Step 3 (Determine Model) — the model determination is cached from the initial review since the changed file list does not change between attempts. Re-run from Step 0 with the cached model.

**For each finding, the orchestrator chooses ONE action:**

| Action | When | What to do |
|--------|------|------------|
| **Fix** | The finding is correct and fixable. Prefer Fix for structural findings (types, tests, error handling). | Fix the code, write/update tests as needed. |
| **Defend** | The finding is a false positive or acceptable tradeoff. Best for subjective findings (readability, design). | Add a `# REVIEW-DEFENSE: <explanation>` comment near the flagged code explaining the design rationale. Must reference verifiable artifacts. |
| **Defer** | The finding is pre-existing or out of scope. | Create a beads tracking issue (`bd create --title="Fix: <finding>" --type=bug --priority=<0-4 based on severity>`). A Deferred finding is NOT resolved for the current review. |

**Defer semantics:** Defer is a documentation/tracking mechanism, not a resolution mechanism. If after applying all Fix and Defend actions, only Deferred findings remain unresolved, the review will still fail. On attempt 2, if the only remaining findings were already Deferred in attempt 1, skip directly to user escalation (do not waste the attempt).

**Loop flow:**

1. Triage all findings into Fix, Defend, or Defer buckets
2. If ALL findings were Deferred, escalate to user immediately (defer alone cannot pass)
3. Apply all Fix and Defend actions
4. **Validate fixes:** Run format, lint, type check, and unit tests on fixed code.
   - **Auto-fixable failures** (format only): run `make format`, re-stage, and continue within the same attempt. This does not consume the attempt.
   - **Substantive failures** (tests, type errors, lint errors): the attempt is exhausted — revert the failed changes (`git checkout -- <affected files>`) and proceed to the next attempt or escalate.
5. Re-run review from Step 0 with cached model (skip Step 3)
6. **Exclude known-Deferred findings from pass/fail:** If a finding was Deferred in the previous attempt and the finding's target file was NOT modified in this attempt, exclude it from the pass/fail determination. The reviewer will still report it, but it does not block the loop.
7. If review passes → done
8. If review fails again:
   - **Attempt 1 exhausted**: Detect new findings introduced by fixes: compare finding `(category, file)` tuples between the initial review and the re-review. Any finding in the re-review that did not appear in the initial review was introduced by the fix — prefer escalation over another fix attempt. Run oscillation-check (`/oscillation-check` with iteration=2) only if the new findings target files modified in attempt 1. If CLEAR (or oscillation-check skipped), proceed to attempt 2. If OSCILLATION, escalate to user.
   - **Attempt 2 exhausted**: Escalate to user with the structured escalation format (see below). The user decides: override, fix differently, or defer.

**Escalation message format:**

When escalating to the user, use this structure to minimize cognitive load:

```
## Review Escalation (attempt N/2 exhausted)

### Remaining Findings
1. [severity] category: <description> -- ACTION TAKEN in attempt N (e.g., "FIXED in attempt 1, reviewer still flagged")
2. [severity] category: <description> -- DEFENDED in attempt 1, reviewer still flagged
3. [severity] category: <description> -- DEFERRED (tracking issue beads-XXX)

### Recommendation
<1-2 sentences: what the orchestrator thinks the best path forward is>

### Actions Needed
For each finding, reply: fix (I'll try a different approach), override (accept as-is), or defer (skip for now).
```

**Defense comment convention:**

All defense comments MUST use the `# REVIEW-DEFENSE:` prefix so they can be found and cleaned up:

```python
# REVIEW-DEFENSE: Using dict instead of dataclass here because the schema
# varies per document type — a fixed dataclass would require constant
# modification. See ADR-007 for the flexibility vs. type-safety tradeoff.
config: dict[str, Any] = field(default_factory=dict)
```

Bad (not visible to reviewer, does not address the concern):
- Adding a comment in a separate ADR file the reviewer doesn't read
- Logging a disagreement in beads notes
- Adding `# noqa` or `# type: ignore` without explanation
- Unverifiable claims: `# REVIEW-DEFENSE: This is faster` (faster than what? measured how?)
