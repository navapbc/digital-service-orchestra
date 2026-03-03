# Code Review Workflow

Review the current code diff using a `general-purpose` sub-agent for deep analysis of bugs, logic errors, security vulnerabilities, code quality, and adherence to project conventions.

## Config Reference (from workflow-config.yaml)

Replace commands below with values from your `workflow-config.yaml`:

- `commands.format` (default: `make format`)
- `commands.lint` (default: `make lint-ruff`)
- `commands.type_check` (default: `make lint-mypy`)
- `commands.test_unit` (default: `make test-unit-only`)

The artifacts directory is computed by `get_artifacts_dir()` in `hooks/lib/deps.sh` and resolves to `/tmp/workflow-plugin-<hash-of-REPO_ROOT>/`.

---

**CRITICAL**: Steps 0-5 are mandatory and sequential. You MUST dispatch the code-reviewer sub-agent in Step 4. Skipping the sub-agent and recording review JSON directly is fabrication — it violates CLAUDE.md rule #15 regardless of how "simple" the changes appear.

**This workflow reviews CODE (diffs, commits). To review a PLAN or DESIGN, use `/plan-review` instead.** See CLAUDE.md "Always Do These" rule 10 for the review routing table.

---

## Step 0: Gather Context

Capture the diff NOW and save it to a hash-stamped temp file. Sub-agents read the diff from this file instead of receiving it inline.

1. **Capture the diff hash** for later verification:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh
   ARTIFACTS_DIR=$(get_artifacts_dir)
   mkdir -p "$ARTIFACTS_DIR"
   DIFF_HASH=$("$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh")
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

1. **Format**: `cd app && make format` — run first so lint/type checks see the final formatted state.
   - After format, check if any files were changed: `git diff --name-only`
   - If format changed files, re-stage them: `git add -u`
   - This keeps the staged diff in sync with the formatted state.
2. **Lint check**: `cd app && make lint-ruff 2>&1 | tail -3` (on success, only summary needed; re-run with full output on failure)
3. **Type check**: `cd app && make lint-mypy 2>&1 | tail -5` (on success, only summary needed; re-run with full output on failure)
4. **Unit tests**: `cd app && make test-unit-only 2>&1 | tail -5` (on success, only summary needed; re-run with full output on failure)

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
- `app/src/app.py`

If **any** changed file matches one of the patterns above -> `model="opus"`.
If **none** match -> `model="sonnet"`.

## Step 4: Dispatch Code Review Sub-Agent (MANDATORY)

**You MUST launch a sub-agent.** There are no exceptions — not for documentation-only changes, not for "trivial" changes, not for config files. The sub-agent performs the review and assigns scores. Skipping this step and writing review JSON yourself is fabrication.

Launch a `general-purpose` sub-agent using the Task tool. This agent type has full tool access, which is required to write `reviewer-findings.json` and compute its hash.

Read the prompt template at `$REPO_ROOT/lockpick-workflow/docs/workflows/prompts/code-review-dispatch.md` and fill in placeholders:
- `{working_directory}`: current working directory
- `{diff_stat}`: content of the stat file from Step 0/2
- `{diff_file_path}`: the `DIFF_FILE` path from Step 0/2
- `{repo_root}`: `REPO_ROOT` value
- `{beads_context}`: Beads issue context (see below)

**Resolving `{beads_context}`**: If a beads issue ID is known for the current work (e.g., passed from `/sprint`, present in the task prompt, or tracked by the orchestrator), populate this placeholder with:

```
=== BEADS ISSUE CONTEXT ===
This change is for beads issue {issue_id}.
To view full issue details, run: tk show {issue_id}
```

If no beads issue is associated with the current work, set `{beads_context}` to an empty string.

**If you have already read `code-review-dispatch.md` earlier in this conversation and have not compacted since, use the version in context.**

```
Task tool:
  subagent_type: "general-purpose"
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
   REPO_ROOT=$(git rev-parse --show-toplevel)
   source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh
   ARTIFACTS_DIR=$(get_artifacts_dir)
   FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"
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
cat <<'REVIEW_EOF' | "$REPO_ROOT/lockpick-workflow/hooks/record-review.sh" \
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
    "build_lint": "<lint result from Step 1 (or 'passed' if skipped)>",
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

If format/lint/tests failed (Step 1), set `build_lint: "N/A"`, all others `"N/A"`, and summary: `"BLOCKED: Build/lint checks failed."`.

`record-review.sh` validates JSON structure, summary, `files_targeted` overlap with actual diff, `--expected-hash` match, reads scores from `reviewer-findings.json`, verifies `--reviewer-hash` integrity, cross-validates findings against scores, and writes the review state file that the commit gate checks. If it rejects the input, fix and retry.

## After Review

### If ALL scores are 4, 5, or "N/A" AND no critical findings:
Review passed. **Immediately resume the calling workflow** — do NOT wait for user input. If this workflow was invoked from COMMIT-WORKFLOW.md Step 5, proceed directly to Step 6 (Commit). If invoked from another orchestrator, resume at the step after the review invocation. Important findings do not automatically fail — the reviewer uses judgment (score 3-4) for important findings.

### If ANY score is below 4, OR any critical finding exists:
Review failed. Enter the Autonomous Resolution Loop. Critical findings always fail regardless of score.

#### Autonomous Resolution Loop

**Architecture**: The resolution loop is split across two levels to avoid nested sub-agent nesting
that causes `[Tool result missing due to internal error]`:

1. **Resolution sub-agent** (fix only): reads findings, applies fixes/defenses/defers, validates.
   Returns `FIXES_APPLIED` when local validation passes. Does NOT dispatch a re-review sub-agent.
2. **Orchestrator** (re-review): after the resolution sub-agent returns `FIXES_APPLIED`, dispatches
   a re-review sub-agent, interprets results, and calls `record-review.sh`.

This design keeps nesting at one level (orchestrator → sub-agent) for both the fix and re-review steps.

**Before dispatching**, record the current time for freshness verification:

```bash
DISPATCH_TIME=$(date +%s)
ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-${WORKTREE}"
```

Read `$REPO_ROOT/lockpick-workflow/docs/workflows/prompts/review-fix-dispatch.md` and use its contents as the sub-agent prompt, filling in:
- `{findings_file}`: `/tmp/lockpick-test-artifacts-${WORKTREE}/reviewer-findings.json`
- `{diff_file}`: the `DIFF_FILE` path from Step 0/2
- `{repo_root}`: `REPO_ROOT` value
- `{worktree}`: `WORKTREE` value
- `{beads_issues}`: beads issue IDs associated with the current work (for `tk create` defers), or empty string
- `{cached_model}`: model determined in Step 3 (`opus` or `sonnet`)

```
Task tool:
  subagent_type: "general-purpose"
  model: "{cached_model}"
  description: "Resolve review findings"
  prompt: <filled template from review-fix-dispatch.md>
```

**After resolution sub-agent returns**, interpret the compact output:

| `RESOLUTION_RESULT` | Action |
|---------------------|--------|
| `FIXES_APPLIED` | Fixes passed local validation. Orchestrator dispatches re-review sub-agent (see below). |
| `FAIL` | Use `REMAINING_CRITICAL` and `ESCALATION_REASON` from sub-agent output to escalate to user. Do NOT re-read `reviewer-findings.json` into orchestrator context. |
| `ESCALATE` | Present `ESCALATION_REASON` to user in the escalation format below. |

**When `RESOLUTION_RESULT: FIXES_APPLIED`** — orchestrator dispatches re-review sub-agent:

1. Capture a fresh diff hash and diff file (the resolution sub-agent changed the code):
   ```bash
   NEW_DIFF_HASH=$("$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh")
   NEW_DIFF_HASH_SHORT="${NEW_DIFF_HASH:0:8}"
   NEW_DIFF_FILE="$ARTIFACTS_DIR/review-diff-${NEW_DIFF_HASH_SHORT}.txt"
   NEW_STAT_FILE="$ARTIFACTS_DIR/review-stat-${NEW_DIFF_HASH_SHORT}.txt"
   { git diff --staged; git diff; } > "$NEW_DIFF_FILE"
   [ -s "$NEW_DIFF_FILE" ] || git diff HEAD~1 > "$NEW_DIFF_FILE"
   git diff HEAD --stat > "$NEW_STAT_FILE"
   ```

2. Dispatch the re-review sub-agent using the same `code-review-dispatch.md` template:
   ```
   Task tool:
     subagent_type: "general-purpose"
     model: "{cached_model}"
     description: "Re-review after fixes"
     prompt: <filled code-review-dispatch.md with NEW_DIFF_HASH, NEW_DIFF_FILE, NEW_STAT_FILE>
   ```

3. Parse re-review sub-agent output: extract `REVIEW_RESULT`, `MIN_SCORE`, `REVIEWER_HASH`.

4. **If re-review passes** (MIN_SCORE ≥ 4 and no critical findings):
   Call `record-review.sh` with the NEW diff hash and re-review's REVIEWER_HASH:
   ```bash
   cat <<'REVIEW_EOF' | "$REPO_ROOT/lockpick-workflow/hooks/record-review.sh" \
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
       "files_targeted": [<FILES_MODIFIED from resolution sub-agent>]
     },
     "summary": "<2-3 sentence summary of what was fixed/defended/deferred>"
   }
   REVIEW_EOF
   ```
   Then proceed to commit.

5. **If re-review fails** (first attempt): dispatch a second resolution sub-agent (second fix cycle).
   Run `/oscillation-check` (iteration=2) only if new findings appeared not in the original review —
   if OSCILLATION detected, skip second attempt and escalate immediately.

6. **If re-review fails** (second attempt, or oscillation detected): escalate to user.

**Escalation message format** (when sub-agent returns FAIL or ESCALATE, or re-review fails twice):

```
## Review Escalation

### Remaining Findings
<REMAINING_CRITICAL from sub-agent>

### Recommendation
<ESCALATION_REASON from sub-agent>

### Actions Needed
For each finding, reply: fix (I'll try a different approach), override (accept as-is), or defer (skip for now).
```
