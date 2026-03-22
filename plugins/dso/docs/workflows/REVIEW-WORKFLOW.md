# Code Review Workflow

Review the current code diff using a classifier-selected named review agent for analysis of bugs, logic errors, security vulnerabilities, code quality, and adherence to project conventions.

## Config Reference (from dso-config.conf)

Replace commands below with values from your `.claude/dso-config.conf`:

- `commands.format` (default: `make format`)
- `commands.lint` (default: `make lint-ruff`)
- `commands.type_check` (default: `make lint-mypy`)
- `commands.test_unit` (default: `make test-unit-only`)

The artifacts directory is computed by `get_artifacts_dir()` in `plugins/dso/hooks/lib/deps.sh` and resolves to `/tmp/workflow-plugin-<hash-of-REPO_ROOT>/`.

---

**CRITICAL**: Steps 0-5 are mandatory and sequential. Step 0 clears stale artifacts — always start here, even when restarting. Step 1 runs auto-fixers (format/lint/type-check) BEFORE Step 2 captures the diff hash — this ordering prevents pre-commit hooks from invalidating the hash. You MUST dispatch the code-reviewer sub-agent in Step 4. Skipping the sub-agent and recording review JSON directly is fabrication — it violates CLAUDE.md rule #15 regardless of how "simple" the changes appear.

**This workflow reviews CODE (diffs, commits). To review a PLAN or DESIGN, use `/dso:plan-review` instead.** See CLAUDE.md "Always Do These" rule 10 for the review routing table.

---

## Step 0: Clear Stale Review Artifacts

**Always run this step first.** Clear any leftover review state from prior sessions or earlier review passes. This ensures the current review computes a fresh diff hash and does not accidentally reuse a stale `review-status` that would let a commit bypass the review gate.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
rm -f "$ARTIFACTS_DIR/review-status"
rm -f "$ARTIFACTS_DIR"/review-diff-*.txt
rm -f "$ARTIFACTS_DIR"/review-stat-*.txt
```

If restarting the review workflow after a failed attempt, this step guarantees a clean slate.

## Step 1: Pre-commit Auto-fix Pass (format/lint/type-check before hash capture)

**Why this step exists**: Pre-commit hooks run format, lint, and type-check on commit. If the diff hash is captured before these auto-fixers run, any file modifications they make will invalidate the hash, forcing a re-review. Running the same checks here — before hash capture — ensures the hash reflects the final post-auto-fix state.

**Skip check**: If a validation state file exists and is fresh (< 60 seconds old), skip Step 1 and go directly to Step 2:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
VALIDATION_STATUS="$ARTIFACTS_DIR/validation-status"
if [ -f "$VALIDATION_STATUS" ]; then
    status_content=$(head -n 1 "$VALIDATION_STATUS")
    if [ "$(uname)" = "Darwin" ]; then
        status_age=$(( $(date +%s) - $(stat -f %m "$VALIDATION_STATUS" 2>/dev/null || echo 0) ))
    else
        status_age=$(( $(date +%s) - $(stat -c %Y "$VALIDATION_STATUS" 2>/dev/null || echo 0) ))
    fi
    if [ "$status_content" = "passed" ] && [ "$status_age" -lt 60 ]; then
        # Validation is fresh — skip to Step 2
    fi
fi
```

If the file is missing, stale (>60s), or shows "failed", execute Step 1 as normal:

Run these checks in order. They mirror the pre-commit hook suite so the diff hash is stable through commit.

1. **Format**: `cd app && make format` — run first so lint/type checks see the final formatted state.
   - After format, check if any files were changed: `git diff --name-only`
   - If format changed files, **re-stage them**: `git add -u`
   - This keeps the staged diff in sync with the formatted state.
2. **Lint check**: `cd app && make lint-ruff 2>&1 | tail -3` (on success, only summary needed; re-run with full output on failure)
3. **Type check**: `cd app && make lint-mypy 2>&1 | tail -5` (on success, only summary needed; re-run with full output on failure)
4. **Unit tests**: `cd app && make test-unit-only 2>&1 | tail -5` (on success, only summary needed; re-run with full output on failure)

If Docker is not available, use `python3 -m py_compile` on changed Python files as a lint fallback.

**If any check fails:**
- Do NOT proceed with the code review
- Fix the issue and restart from Step 0

## Step 2: Capture Diff Hash (after auto-fixers have run)

The diff hash is captured here — AFTER Step 1's format/lint/type-check pass — so it reflects the final post-auto-fix state. This prevents pre-commit hooks from invalidating the hash at commit time.

1. **Capture the diff hash**:
   ```bash
   DIFF_HASH=$("${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh")
   DIFF_HASH_SHORT="${DIFF_HASH:0:8}"
   ```

2. **Capture the diff to a hash-stamped file** (not inline in context):
   ```bash
   DIFF_FILE="$ARTIFACTS_DIR/review-diff-${DIFF_HASH_SHORT}.txt"
   STAT_FILE="$ARTIFACTS_DIR/review-stat-${DIFF_HASH_SHORT}.txt"
   ".claude/scripts/dso capture-review-diff.sh" "$DIFF_FILE" "$STAT_FILE"
   ```

3. **Read only the stat file** into context (small). Do NOT cat/read the full diff file — the sub-agent reads it from disk.

4. Store `DIFF_HASH`, `DIFF_FILE`, and `STAT_FILE` paths for use in Steps 2-5.

**Note**: The diff hash is staging-invariant for tracked file changes — `git add -u` produces the same hash as the pre-add state.

## Step 3: Classify Review Tier (MANDATORY — run the classifier, do not evaluate mentally)

**You MUST run this command and use its output.** Do NOT select a tier based on your assessment of diff complexity or file types — the classifier computes the tier deterministically from the diff.

```bash
# Run complexity classifier to determine review tier
CLASSIFIER="${CLAUDE_PLUGIN_ROOT}/scripts/review-complexity-classifier.sh"
CLASSIFIER_OUTPUT=$(bash "$CLASSIFIER" < "$DIFF_FILE" 2>/dev/null) || CLASSIFIER_EXIT=$?
if [[ "${CLASSIFIER_EXIT:-0}" -ne 0 ]] || ! echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    # Classifier failed — default to standard tier per contract (classifier-tier-output.md)
    REVIEW_TIER="standard"
    REVIEW_AGENT="dso:code-reviewer-standard"
else
    REVIEW_TIER=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["selected_tier"])')
    case "$REVIEW_TIER" in
        light)    REVIEW_AGENT="dso:code-reviewer-light" ;;
        standard) REVIEW_AGENT="dso:code-reviewer-standard" ;;
        deep)     REVIEW_AGENT="dso:code-reviewer-deep-correctness" ;;  # Deep multi-reviewer dispatch comes in w21-txt8
        *)        REVIEW_TIER="standard"; REVIEW_AGENT="dso:code-reviewer-standard" ;;
    esac
fi
echo "REVIEW_TIER=$REVIEW_TIER REVIEW_AGENT=$REVIEW_AGENT"
```

Use the `REVIEW_TIER` and `REVIEW_AGENT` values in Step 4. Do not override the classifier's tier selection.

## Step 4: Dispatch Code Review Sub-Agent (MANDATORY)

**You MUST launch a sub-agent.** There are no exceptions — not for documentation-only changes, not for "trivial" changes, not for config files. The sub-agent performs the review and assigns scores. Skipping this step and writing review JSON yourself is fabrication.

Dispatch the named review agent selected by the classifier in Step 3. The named agent's system prompt contains the stable review procedure — do NOT load `code-review-dispatch.md` as a template. Pass only per-review context to the sub-agent prompt.

### Tier-to-Agent Dispatch

| `REVIEW_TIER` | `REVIEW_AGENT` | Model |
|---|---|---|
| `light` | `dso:code-reviewer-light` | haiku |
| `standard` | `dso:code-reviewer-standard` | sonnet |
| `deep` | `dso:code-reviewer-deep-correctness` | opus (full parallel multi-reviewer dispatch comes in w21-txt8) |

### Per-Review Context (prompt content)

Pass only these items in the sub-agent prompt — the named agent's system prompt handles the review procedure:

- `DIFF_FILE`: the `DIFF_FILE` path from Step 2 (the sub-agent reads the diff from disk)
- `STAT_FILE` content: the stat summary from Step 2 (inline in the prompt)
- `REPO_ROOT`: repository root path
- `{issue_context}`: Issue context (see below)

**Resolving `{issue_context}`**: If a tk issue ID is known for the current work (e.g., passed from `/dso:sprint`, present in the task prompt, or tracked by the orchestrator), populate this with:

```
=== ISSUE CONTEXT ===
This change is for issue {issue_id}.
To view full issue details, run: tk show {issue_id}
```

If no issue is associated with the current work, omit the issue context section.

### Dispatch

```
Task tool:
  subagent_type: "{REVIEW_AGENT from Step 3}"
  description: "Review code changes"
  prompt: |
    Review the code changes for this commit.

    DIFF_FILE: {DIFF_FILE from Step 2}
    REPO_ROOT: {REPO_ROOT}

    === DIFF STAT ===
    {content of STAT_FILE from Step 2}

    {issue_context}
```

**NEVER set `isolation: "worktree"` on this sub-agent.** The reviewer must read `reviewer-findings.json` and run `write-reviewer-findings.sh` in the same working directory as the orchestrator. Worktree isolation gives the agent a separate branch where those files are not present, causing the review to fail.

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
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh
   ARTIFACTS_DIR=$(get_artifacts_dir)
   FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"
   cat "$FINDINGS_FILE" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'[{f[\"severity\"]}] {f[\"category\"]}: {f[\"description\"]}') for f in d['findings'] if f['severity'] in ('critical','important')]"
   ```

### Integrity Rules

Scores come exclusively from `reviewer-findings.json` (written by the code-reviewer sub-agent via `write-reviewer-findings.sh`). The orchestrator does NOT determine pass/fail.

- **R1 - Sub-agent only**: `record-review.sh` reads all review data directly from `reviewer-findings.json`. No orchestrator-constructed JSON is accepted. The orchestrator's only role is to pass `--reviewer-hash` and `--expected-hash`.
- **R2 - No dismissal**: "Pre-existing", "not a runtime bug", "trivial/cosmetic" are not valid grounds for dismissing findings. Create tracking issues for pre-existing problems instead.
- **R3 - Critical/important resolution**: Any critical or important finding triggers the Autonomous Resolution Loop (see "After Review").
- **R4 - Verbatim severity**: The summary must reference the reviewer's severity levels exactly as stated. Do not downgrade or rephrase severity.
- **R5 - Defense mechanism**: To dispute a finding without user involvement, the orchestrator MUST add a **code-visible defense** — an inline comment with the `# REVIEW-DEFENSE:` prefix, a docstring addition, or a type annotation that explains the design rationale to the reviewer. The orchestrator MUST NOT silently dismiss findings, override scores, or add comments that merely suppress warnings without explanation. Defense comments must reference verifiable artifacts (existing code, tests, ADRs, or documented patterns) — not unverifiable claims like "for performance reasons." The defense must be substantive enough that a human reading the code would understand the tradeoff. **Structural findings** (type annotations, test coverage gaps, missing error handling) should prefer Fix over Defend — the reviewer scores these based on code patterns, and a comment is unlikely to change the score.

### Record the review

Call `record-review.sh` with `--expected-hash` from Step 2 and `--reviewer-hash` from the sub-agent output. No stdin JSON is needed — the script reads directly from `reviewer-findings.json`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
"${CLAUDE_PLUGIN_ROOT}/hooks/record-review.sh" \
  --expected-hash "<DIFF_HASH from Step 2>" \
  --reviewer-hash "<REVIEWER_HASH from sub-agent>"
```

`record-review.sh` reads scores, summary, and findings from `reviewer-findings.json`, verifies `--reviewer-hash` integrity, validates findings against scores, checks file overlap with the actual diff, verifies `--expected-hash` against the current diff hash, and writes the review state file that the commit gate checks. If it rejects, fix and retry.

**IMPORTANT — always use `compute-diff-hash.sh`**: Never compute the diff hash via raw `git diff | shasum` — the canonical script applies pathspec exclusions (`.tickets/`, snapshots, images) and checkpoint-aware diff base detection. Untracked files are excluded (new files must be staged before review). A raw pipeline produces a completely different hash and will cause `--expected-hash` mismatch errors.

## After Review

### If ALL scores are 4, 5, or "N/A" AND no critical findings:
Review passed. **Immediately resume the calling workflow** — do NOT wait for user input. If this workflow was invoked from COMMIT-WORKFLOW.md Step 5, proceed directly to Step 6 (Commit). If invoked from another orchestrator, resume at the step after the review invocation. Important findings do not automatically fail — the reviewer uses judgment (score 3-4) for important findings.

### If ANY score is below 4, OR any critical finding exists:
Review failed. Enter the Autonomous Resolution Loop. Critical findings always fail regardless of score.

#### Autonomous Resolution Loop

**INLINE FIX PROHIBITION**: The orchestrator MUST NOT use Edit, Write, or Bash to fix review findings directly. All fixes MUST go through a resolution sub-agent dispatch. There are no exceptions.

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
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR="$(get_artifacts_dir)"
```

Read `${CLAUDE_PLUGIN_ROOT}/docs/workflows/prompts/review-fix-dispatch.md` and use its contents as the sub-agent prompt, filling in:
- `{findings_file}`: `$(get_artifacts_dir)/reviewer-findings.json`
- `{diff_file}`: the `DIFF_FILE` path from Step 2
- `{repo_root}`: `REPO_ROOT` value
- `{worktree}`: `WORKTREE` value
- `{issue_ids}`: issue IDs associated with the current work (for `tk create` defers), or empty string
- `{cached_model}`: model name derived from `REVIEW_TIER` in Step 3 (`light`→`haiku`, `standard`→`sonnet`, `deep`→`opus`)

```
Task tool:
  subagent_type: "general-purpose"
  model: "sonnet"
  description: "Resolve review findings"
  prompt: <filled template from review-fix-dispatch.md>
```

**NEVER set `isolation: "worktree"` on this sub-agent.** It must edit the same working tree files that the orchestrator and re-review agent will see.

**After resolution sub-agent returns**, interpret the compact output:

| `RESOLUTION_RESULT` | Action |
|---------------------|--------|
| `FIXES_APPLIED` | Fixes passed local validation. Orchestrator dispatches re-review sub-agent (see below). |
| `FAIL` | Use `REMAINING_CRITICAL` and `ESCALATION_REASON` from sub-agent output to escalate to user. Do NOT re-read `reviewer-findings.json` into orchestrator context. |
| `ESCALATE` | Present `ESCALATION_REASON` to user in the escalation format below. |

**When `RESOLUTION_RESULT: FIXES_APPLIED`** — orchestrator dispatches re-review sub-agent:

1. Capture a fresh diff hash and diff file (the resolution sub-agent changed the code):
   ```bash
   NEW_DIFF_HASH=$("${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh")
   NEW_DIFF_HASH_SHORT="${NEW_DIFF_HASH:0:8}"
   NEW_DIFF_FILE="$ARTIFACTS_DIR/review-diff-${NEW_DIFF_HASH_SHORT}.txt"
   NEW_STAT_FILE="$ARTIFACTS_DIR/review-stat-${NEW_DIFF_HASH_SHORT}.txt"
   ".claude/scripts/dso capture-review-diff.sh" "$NEW_DIFF_FILE" "$NEW_STAT_FILE"
   ```

2. Dispatch the re-review sub-agent using the same named agent from Step 3:
   ```
   Task tool:
     subagent_type: "{REVIEW_AGENT from Step 3}"
     description: "Re-review after fixes"
     prompt: |
       Review the code changes for this commit.

       DIFF_FILE: {NEW_DIFF_FILE}
       REPO_ROOT: {REPO_ROOT}

       === DIFF STAT ===
       {content of NEW_STAT_FILE}

       {issue_context}
   ```

   **NEVER set `isolation: "worktree"` on this sub-agent.** It must access `reviewer-findings.json` and `write-reviewer-findings.sh` in the shared working directory.

3. Parse re-review sub-agent output: extract `REVIEW_RESULT`, `MIN_SCORE`, `REVIEWER_HASH`.

4. **If re-review passes** (MIN_SCORE ≥ 4 and no critical findings):
   Call `record-review.sh` with the NEW diff hash and re-review's REVIEWER_HASH:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/hooks/record-review.sh" \
     --expected-hash "<NEW_DIFF_HASH>" \
     --reviewer-hash "<REVIEWER_HASH from re-review sub-agent>"
   ```
   Then proceed to commit.

5. **If re-review fails**: run the OSCILLATION GATE before dispatching another resolution sub-agent.

   **OSCILLATION GATE (mandatory on attempt 2+)**:
   - If attempt >= 2: run `/dso:oscillation-check` unconditionally. Do NOT skip based on whether findings appear new.
   - If OSCILLATION detected: escalate immediately. Do NOT dispatch another resolution sub-agent.
   - If CLEAR: dispatch the next resolution sub-agent.

   Up to 3 fix/defend attempts total before escalating.

6. **If re-review fails** (third attempt, or oscillation detected): escalate to user.

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
