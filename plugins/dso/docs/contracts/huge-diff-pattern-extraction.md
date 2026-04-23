# Contract: HUGE_DIFF_PATTERN_EXTRACTION Signal

## Purpose

Defines the output contract for the haiku sub-agent dispatched per sampled file by `REVIEW-WORKFLOW-HUGE.md` during the refactor pattern detection phase. The `REVIEW-WORKFLOW-HUGE.md` consensus evaluator aggregates these signals to determine whether a uniform refactor pattern is confirmed across the sampled files.

## Signal Name

`HUGE_DIFF_PATTERN_EXTRACTION`

## Emitter

Haiku sub-agent dispatched per sampled file by `REVIEW-WORKFLOW-HUGE.md` (Step 2 — per-file pattern extraction).

## Parser

`REVIEW-WORKFLOW-HUGE.md` consensus evaluation (Step 3) — aggregates signals across all sampled files to determine whether a uniform refactor pattern is confirmed.

## Output Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `transformation_description` | string | yes | Human-readable description of the transformation applied (e.g., "Replace `foo()` calls with `bar()` calls"). Used as the consensus key. |
| `before_pattern` | string | yes | Representative code pattern before the transformation. |
| `after_pattern` | string | yes | Representative code pattern after the transformation. |
| `confidence` | `"high"` \| `"medium"` \| `"low"` | yes | Confidence level that this file exemplifies the described pattern. |

## Output Format

```
HUGE_DIFF_PATTERN_EXTRACTION
transformation_description: <string>
before_pattern: <string>
after_pattern: <string>
confidence: high|medium|low
```

### Canonical parsing prefix

The parser MUST match against:

```
HUGE_DIFF_PATTERN_EXTRACTION
```

This prefix appears as a standalone line (no trailing colon or equals sign). All subsequent `key: value` lines up to the next blank line or end of output constitute the signal payload.

## Consensus Rule

After collecting `HUGE_DIFF_PATTERN_EXTRACTION` signals from all sampled files (up to 7), Step 3 applies the following consensus rule:

1. Count files with **identical** `transformation_description` strings.
2. If count **≥ 5 of 7**: emit `CONFIRMED_REFACTOR` — proceed with refactor-aware review path.
3. If count **< 5**: emit `FALLBACK` — route to standard deep-review path.

Matching is case-insensitive and trims leading/trailing whitespace. Files with `confidence: low` are excluded from the consensus count.

## Example

```
HUGE_DIFF_PATTERN_EXTRACTION
transformation_description: Replace direct dict access with get() method for safe key lookup
before_pattern: value = data["key"]
after_pattern: value = data.get("key")
confidence: high
```

## Related Files

- Emitter: `REVIEW-WORKFLOW-HUGE.md` Step 2
- Consumer: `REVIEW-WORKFLOW-HUGE.md` Step 3
- Sampling script: `review-sample-files.sh`
