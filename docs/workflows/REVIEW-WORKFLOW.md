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

**CRITICAL**: Steps 0-5 are mandatory and sequential. Step 0 clears stale artifacts — always start here, even when restarting. You MUST dispatch the code-reviewer sub-agent in Step 4. Skipping the sub-agent and recording review JSON directly is fabrication — it violates CLAUDE.md rule #15 regardless of how "simple" the changes appear.

**This workflow reviews CODE (diffs, commits). To review a PLAN or DESIGN, use `/plan-review` instead.** See CLAUDE.md "Always Do These" rule 10 for the review routing table.

---

## Step 0: Clear Stale Review Artifacts

**Always run this step first.** Clear any leftover review state and snapshot files from prior sessions or earlier review passes. This ensures the current review computes a fresh diff hash and does not accidentally reuse a stale `review-status` that would let a commit bypass the review gate.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
rm -f "$ARTIFACTS_DIR/review-status"
rm -f "$ARTIFACTS_DIR/untracked-snapshot.txt"
rm -f "$ARTIFACTS_DIR"/review-diff-*.txt
rm -f "$ARTIFACTS_DIR"/review-stat-*.txt
```

If restarting the review workflow after a failed attempt, this step guarantees a clean slate.

## Step 1: Gather Context

> **Pre-compaction checkpoint detection**: If the working tree is unexpectedly clean when you expected uncommitted changes, check `git log --oneline -3` for a checkpoint commit (message contains "pre-compaction auto-save" or "checkpoint:"). If found, the diff-hash infrastructure already handles this correctly — `compute-diff-hash.sh` uses the checkpoint commit as the diff base. Proceed normally.

Capture the diff NOW and save it to a hash-stamped temp file. Sub-agents read the diff from this file instead of receiving it inline.

1. **Initialize artifacts directory and snapshot**:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   SNAPSHOT_FILE="$ARTIFACTS_DIR/untracked-snapshot.txt"
   ```

2. **Capture an initial diff hash** (may be re-captured after Step 2 if format changes files):
   ```bash
   DIFF_HASH=$("$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh" --snapshot "$SNAPSHOT_FILE")
   DIFF_HASH_SHORT="${DIFF_HASH:0:8}"
   ```
   The `--snapshot` flag saves the untracked file list to `$SNAPSHOT_FILE` on the first call.
   All subsequent calls in this review session reuse the saved list, making the hash
   deterministic regardless of concurrent file creation by sub-agents.

3. **Capture the diff to a hash-stamped file** (not inline in context):
   ```bash
   DIFF_FILE="$ARTIFACTS_DIR/review-diff-${DIFF_HASH_SHORT}.txt"
   STAT_FILE="$ARTIFACTS_DIR/review-stat-${DIFF_HASH_SHORT}.txt"
   "$REPO_ROOT/lockpick-workflow/scripts/capture-review-diff.sh" "$DIFF_FILE" "$STAT_FILE"
   ```

4. **Read only the stat file** into context (small). Do NOT cat/read the full diff file — the sub-agent reads it from disk.

5. Store `DIFF_HASH`, `DIFF_FILE`, `STAT_FILE`, and `SNAPSHOT_FILE` paths for use in Steps 1-5.

**Note**: The diff hash is staging-invariant for tracked file changes — `git add -u` produces the same hash as the pre-add state. If you stage a new untracked file with `git add <file>` between review and commit, delete the snapshot file and re-run the review workflow to capture the updated hash.

## Step 2: Validate (conditional)

**Skip check**: If a validation state file exists and is fresh (< 60 seconds old), skip Step 2 and go directly to Step 3:

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

If the file is missing, stale (>60s), or shows "failed", execute Step 2 as normal:

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

## Step 2.5: Re-capture Hash (if format changed files)

If Step 2's format step (`make format`) modified any files, the diff hash from Step 1 is now stale. Re-capture it:

```bash
# Check if format changed files (tracked in Step 2 via git diff --name-only)
# If files were changed and re-staged:
rm -f "$SNAPSHOT_FILE"  # Clear snapshot so untracked list is refreshed
DIFF_HASH=$("$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh" --snapshot "$SNAPSHOT_FILE")
DIFF_HASH_SHORT="${DIFF_HASH:0:8}"
DIFF_FILE="$ARTIFACTS_DIR/review-diff-${DIFF_HASH_SHORT}.txt"
STAT_FILE="$ARTIFACTS_DIR/review-stat-${DIFF_HASH_SHORT}.txt"
"$REPO_ROOT/lockpick-workflow/scripts/capture-review-diff.sh" "$DIFF_FILE" "$STAT_FILE"
```

If format did NOT change any files, skip this step — the Step 1 hash is still valid.

## Step 3: Determine Model (MANDATORY — run the command, do not evaluate mentally)

**You MUST run this command and use its output.** Do NOT select a model based on your assessment of diff complexity or file types — only file paths determine model selection.

```bash
CHANGED_FILES=$({ git diff HEAD --name-only; git ls-files --others --exclude-standard; } | sort -u)
MODEL="sonnet"
if echo "$CHANGED_FILES" | grep -qE '^(\.claude/skills/|\.claude/workflows/|lockpick-workflow/|\.claude/docs/|CLAUDE\.md$|\.github/workflows/|scripts/|\.pre-commit-config\.yaml$|Makefile$|app/src/app\.py$)'; then
    MODEL="opus"
fi
echo "REVIEW_MODEL=$MODEL"
```

Use the `REVIEW_MODEL=` value in Step 4. Do not substitute `sonnet` when the command outputs `opus`.

## Step 4: Dispatch Code Review Sub-Agent (MANDATORY)

**You MUST launch a sub-agent.** There are no exceptions — not for documentation-only changes, not for "trivial" changes, not for config files. The sub-agent performs the review and assigns scores. Skipping this step and writing review JSON yourself is fabrication.

Launch a `general-purpose` sub-agent using the Task tool. This agent type has full tool access, which is required to write `reviewer-findings.json` and compute its hash.

**Do NOT use specialized sub-agent types** (e.g., `feature-dev:code-reviewer`, `unit-testing:test-automator`). Those types lack the Bash tool, which is required to run `verify-review-diff.sh` and pipe JSON to `write-reviewer-findings.sh`. Using a non-general-purpose type will cause the review to fail with a malformed output and require a re-dispatch.

Read the prompt template at `$REPO_ROOT/lockpick-workflow/docs/workflows/prompts/code-review-dispatch.md` and fill in placeholders:
- `{working_directory}`: current working directory
- `{diff_stat}`: content of the stat file from Step 1 or 2.5
- `{diff_file_path}`: the `DIFF_FILE` path from Step 1 or 2.5
- `{repo_root}`: `REPO_ROOT` value
- `{issue_context}`: Issue context (see below)

**Resolving `{issue_context}`**: If a tk issue ID is known for the current work (e.g., passed from `/sprint`, present in the task prompt, or tracked by the orchestrator), populate this placeholder with:

```
=== ISSUE CONTEXT ===
This change is for issue {issue_id}.
To view full issue details, run: tk show {issue_id}
```

If no issue is associated with the current work, set `{issue_context}` to an empty string.

**If you have already read `code-review-dispatch.md` earlier in this conversation and have not compacted since, use the version in context.**

```
Task tool:
  subagent_type: "general-purpose"
  model: "{opus or sonnet from Step 3}"
  description: "Review code changes"
  prompt: <filled template from code-review-dispatch.md>
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
   source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh
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

Call `record-review.sh` with `--expected-hash` from Step 1/2.5 and `--reviewer-hash` from the sub-agent output. No stdin JSON is needed — the script reads directly from `reviewer-findings.json`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
"$REPO_ROOT/lockpick-workflow/hooks/record-review.sh" \
  --expected-hash "<DIFF_HASH from Step 1/2.5>" \
  --reviewer-hash "<REVIEWER_HASH from sub-agent>"
```

`record-review.sh` reads scores, summary, and findings from `reviewer-findings.json`, verifies `--reviewer-hash` integrity, validates findings against scores, checks file overlap with the actual diff, verifies `--expected-hash` against the current diff hash, and writes the review state file that the commit gate checks. If it rejects, fix and retry.

**IMPORTANT — always use `compute-diff-hash.sh`**: Never compute the diff hash via raw `git diff | shasum` — the canonical script applies pathspec exclusions (`.tickets/`, snapshots, images), checkpoint-aware diff base detection, and includes untracked file contents. A raw pipeline produces a completely different hash and will cause `--expected-hash` mismatch errors.

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
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
ARTIFACTS_DIR="$(get_artifacts_dir)"
```

Read `$REPO_ROOT/lockpick-workflow/docs/workflows/prompts/review-fix-dispatch.md` and use its contents as the sub-agent prompt, filling in:
- `{findings_file}`: `$(get_artifacts_dir)/reviewer-findings.json`
- `{diff_file}`: the `DIFF_FILE` path from Step 1/2.5
- `{repo_root}`: `REPO_ROOT` value
- `{worktree}`: `WORKTREE` value
- `{issue_ids}`: issue IDs associated with the current work (for `tk create` defers), or empty string
- `{cached_model}`: model determined in Step 3 (`opus` or `sonnet`)

```
Task tool:
  subagent_type: "general-purpose"
  model: "{cached_model}"
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
   NEW_DIFF_HASH=$("$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh")
   NEW_DIFF_HASH_SHORT="${NEW_DIFF_HASH:0:8}"
   NEW_DIFF_FILE="$ARTIFACTS_DIR/review-diff-${NEW_DIFF_HASH_SHORT}.txt"
   NEW_STAT_FILE="$ARTIFACTS_DIR/review-stat-${NEW_DIFF_HASH_SHORT}.txt"
   "$REPO_ROOT/lockpick-workflow/scripts/capture-review-diff.sh" "$NEW_DIFF_FILE" "$NEW_STAT_FILE"
   ```

2. Dispatch the re-review sub-agent using the same `code-review-dispatch.md` template:
   ```
   Task tool:
     subagent_type: "general-purpose"
     model: "{cached_model}"
     description: "Re-review after fixes"
     prompt: <filled code-review-dispatch.md with NEW_DIFF_HASH, NEW_DIFF_FILE, NEW_STAT_FILE>
   ```

   **NEVER set `isolation: "worktree"` on this sub-agent.** It must access `reviewer-findings.json` and `write-reviewer-findings.sh` in the shared working directory.

3. Parse re-review sub-agent output: extract `REVIEW_RESULT`, `MIN_SCORE`, `REVIEWER_HASH`.

4. **If re-review passes** (MIN_SCORE ≥ 4 and no critical findings):
   Call `record-review.sh` with the NEW diff hash and re-review's REVIEWER_HASH:
   ```bash
   "$REPO_ROOT/lockpick-workflow/hooks/record-review.sh" \
     --expected-hash "<NEW_DIFF_HASH>" \
     --reviewer-hash "<REVIEWER_HASH from re-review sub-agent>"
   ```
   Then proceed to commit.

5. **If re-review fails**: run the OSCILLATION GATE before dispatching another resolution sub-agent.

   **OSCILLATION GATE (mandatory on attempt 2+)**:
   - If attempt >= 2: run `/oscillation-check` unconditionally. Do NOT skip based on whether findings appear new.
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
