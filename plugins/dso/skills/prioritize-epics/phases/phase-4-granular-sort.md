# Phase 4: Granular Sorting

**Goal**: Translate the Phase 3 buckets into final P0–P4 priorities and write them to the ticket tracker.

Priority mapping for this phase:

| Bucket | Sub-tier | Priority |
|--------|----------|----------|
| Out of scope | — | **P4** |
| North Star | High value | **P0** |
| North Star | Low value | **P1** |
| Optional additions | High value | **P2** |
| Optional additions | Low value | **P3** |

**Anti-anchor rule (applies to every step in this phase)**: an epic's *current* priority MUST NOT influence its new priority. The bucket decision from Phase 3 (computed without reference to current priority — see `prompts/coarse-sort-batch.md` Calibration) is the only input. A previously-P4 epic that landed in `BUCKETS.north_star` becomes P0 or P1 like any other North Star epic; a previously-P0 epic that landed in `BUCKETS.out_of_scope` becomes P4. Re-prioritization is the whole point of the skill.

## Step 1 — Out of scope → P4

For every epic in `BUCKETS.out_of_scope` (including Phase 1 `OUT_OF_SCOPE_IDS`, which were already set to P4 in Phase 1 Step 2 — re-running is idempotent):

1. Read current priority: `.claude/scripts/dso ticket show <id>` → inspect `priority` field.
2. If priority is already 4, skip. Otherwise:

```bash
.claude/scripts/dso ticket edit <id> --priority=4
```

Collect the list of writes performed for the Phase 4 report.

## Step 2 — North Star → P0/P1

### 2a. Score each North Star epic as high-value or low-value

For each epic in `BUCKETS.north_star`, apply this rubric (your own judgment as the orchestrator — no sub-agent needed for this small set):

- **High value** if the epic clearly advances the user's North Star definition, aligns with the user's stated Tradeoffs (golden path / preferred archetype / functionality-vs-quality bias), and fits the user's Risk Tolerance. A North Star epic should default to high value unless one of these is significantly off.
- **Low value** if the epic is in scope (it is, by virtue of being in the North Star bucket) but is materially less aligned with the tradeoffs and risk-tolerance signals than the rest of the North Star bucket.

If the bucket is small (≤ 3 epics), every member is high value by default — there is no meaningful spread.

### 2b. Inherit enabler priority

After initial scoring, propagate inherited high-value:

> **Rule**: If epic A is high value, every epic that blocks A (direct or transitive, restricted to epics inside `BUCKETS.north_star`) is also high value.

Run this as a fixed-point pass over `BUCKETS.north_star` until no labels change. Use the transitive blocker chains already computed in Phase 3 Step 3 to avoid re-walking the graph.

### 2c. Write priorities

- Each high-value North Star epic → `.claude/scripts/dso ticket edit <id> --priority=0`
- Each low-value North Star epic → `.claude/scripts/dso ticket edit <id> --priority=1`

Skip writes that would be no-ops (priority already matches).

## Step 3 — Optional additions → P2/P3

### 3a. Score each optional-additions epic as high-value or low-value

Same approach as Step 2a, but using a higher bar — the question is "within the set of nice-to-haves, which deliver more relative bang for the buck given the stated tradeoffs and risk tolerance?"

- If `AVOID_RISK=true`, downgrade epics whose risk profile is notably high (per the Phase 3 sub-agent's `risk_flag`, or Phase 1 `RISK_HOTSPOTS` overlap with the epic's described area).

### 3b. Inherit enabler priority (scoped)

> **Rule**: If optional-additions epic A is high value, every epic in `BUCKETS.optional_additions` that blocks A (direct or transitive) is also high value.

This rule is **scoped to within optional_additions** — do NOT promote optional-additions epics into the North Star tier here. Cross-bucket blocker promotion was already handled in Phase 3 Step 3 (Rule 1). Run as a fixed-point pass.

### 3c. Write priorities

- Each high-value optional-additions epic → `.claude/scripts/dso ticket edit <id> --priority=2`
- Each low-value optional-additions epic → `.claude/scripts/dso ticket edit <id> --priority=3`

Skip no-op writes.

## Phase 4 Output

```
=== Phase 4 Complete ===

Priorities written:
- P0 (<N>): <ids — title>
- P1 (<N>): <ids — title>
- P2 (<N>): <ids — title>
- P3 (<N>): <ids — title>
- P4 (<N>): <ids — title>

No-op writes skipped: <N>

PHASE GATE QUESTION:
Final priorities look right? On confirmation I'll check whether any P0/P1 epics still need brainstorming.

Do NOT proceed until user responds.
```

If the user disagrees with any specific assignment, accept the correction, write the override (`ticket edit <id> --priority=<n>`), and update the report. Do NOT re-run the whole phase for a single override.
