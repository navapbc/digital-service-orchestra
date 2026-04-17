# Large-Diff Review Workflow

This workflow handles diffs with ≥`review.huge_diff_file_threshold` changed files (default: 20).
It is invoked from REVIEW-WORKFLOW.md Step 2b when the file-count threshold is met.

## Prerequisites

`DIFF_HASH` and `ARTIFACTS_DIR` are passed from the REVIEW-WORKFLOW.md Step 2b diversion caller.
The caller already computed these in REVIEW-WORKFLOW.md Steps 1–2. Do NOT recompute them here.

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

**CONFIRMED_REFACTOR**: Dispatch standard deep-tier code review.
*(Note: Specialized haiku batch agents + refactor-anomaly reviewer pending Stories cf76-7091 / efe7-7f1d.)*

**FALLBACK**: Dispatch standard deep-tier code review with MODEL_OVERRIDE: opus signal emitted before dispatch.

Both paths produce `reviewer-findings.json` and `REVIEWER_HASH`.

## Step 5: Record Review

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
"${CLAUDE_PLUGIN_ROOT}/hooks/record-review.sh" --expected-hash "$DIFF_HASH" --reviewer-hash "$REVIEWER_HASH"
```

Surface error to user if non-zero exit.
