# Large-Diff Review Workflow

This workflow handles diffs with ≥`review.huge_diff_file_threshold` changed files (default: 20).
It is invoked from REVIEW-WORKFLOW.md Step 2b when the file-count threshold is met.

## Prerequisites

`DIFF_HASH` and `ARTIFACTS_DIR` are passed from the REVIEW-WORKFLOW.md Step 2b diversion caller.
The caller already computed these in REVIEW-WORKFLOW.md Steps 1–2. Do NOT recompute them here.

**ARTIFACTS_DIR propagation (mandatory)**: Every sub-agent dispatched from this workflow that writes to an artifacts-dir-derived path (`reviewer-findings.json`, `classifier-telemetry.jsonl`, review-status, etc.) MUST receive `WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR` in its dispatch context. Under worktree isolation, a sub-agent that re-derives the artifacts dir via `get_artifacts_dir()` resolves against its own worktree root, writing findings where no downstream consumer will look. This includes the Step 2 pattern-extraction agents (if they emit structured artifacts), Step 4 FALLBACK `huge-diff-reviewer-*` agents (write `reviewer-findings.json`), and Step 4 CONFIRMED_REFACTOR `huge-diff-refactor-anomaly` agent (writes `reviewer-findings.json`). Pass as an explicit prompt line:

```
WORKFLOW_PLUGIN_ARTIFACTS_DIR: {ARTIFACTS_DIR}
```

Do NOT rely on the sub-agent to compute its own artifacts dir.

## Step 1: Sampling

Run the stratified file sampler to select up to 7 representative files:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
SAMPLED_FILES=$("$REPO_ROOT/.claude/scripts/dso" review-sample-files.sh)
SAMPLE_EXIT=$?
```

If exit 1 (INSUFFICIENT_FILES): set `ROUTING=FALLBACK`, skip to Step 4.

## Step 2: Pattern Extraction

For each of the 7 sampled files, dispatch a haiku sub-agent with the file's diff excerpt.

Each agent returns a signal per `${CLAUDE_PLUGIN_ROOT}/docs/contracts/huge-diff-pattern-extraction.md`:

```
HUGE_DIFF_PATTERN_EXTRACTION
transformation_description: <string>
before_pattern: <string>
after_pattern: <string>
confidence: high|medium|low
```

If ≥2 agent failures (timeout, non-zero exit, missing `transformation_description`, or `confidence: low`): set `ROUTING=FALLBACK`, skip to Step 4.

## Step 3: Consensus Evaluation

Count files with identical `transformation_description` (case-insensitive, trim whitespace). Exclude `confidence: low` responses.

- `match_count ≥ 5`: set `ROUTING=CONFIRMED_REFACTOR`
- `match_count < 5`: set `ROUTING=FALLBACK`

## Step 4: Routing

**FALLBACK**: Dispatch with opus model override.

1. Emit MODEL_OVERRIDE: opus before dispatch.
2. Use the review classifier to score the diff.
3. Route by classifier tier:
   - Light (score 0–2): Dispatch `huge-diff-reviewer-light` agent
   - Standard (score 3–6): Dispatch `huge-diff-reviewer-standard` agent
   - Deep (score 7+): Dispatch standard deep-tier code review with `code-reviewer-deep-arch` as synthesis agent
4. Proceed to Step 5 with `reviewer-findings.json` and `REVIEWER_HASH`.

**CONFIRMED_REFACTOR**: Group files and dispatch anomaly reviewer.

1. Group the full file list using `review-batch-groups.sh`:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   GROUPED=$("$REPO_ROOT/.claude/scripts/dso" review-batch-groups.sh <<< "$SAMPLED_FILES")
   ```
2. For each group, dispatch a haiku sub-agent to check conformance against the consensus `transformation_description`.
3. Collect anomalous files (those that deviate from the pattern).
4. If anomalous files exist: dispatch `huge-diff-refactor-anomaly` agent with anomalous file diffs.
5. Proceed to Step 5 with `reviewer-findings.json` and `REVIEWER_HASH`.

## Step 5: Record Review

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
"${CLAUDE_PLUGIN_ROOT}/hooks/record-review.sh" --expected-hash "$DIFF_HASH" --reviewer-hash "$REVIEWER_HASH"
```

Surface error to user if non-zero exit.
