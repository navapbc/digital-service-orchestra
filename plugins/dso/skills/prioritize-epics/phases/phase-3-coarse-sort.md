# Phase 3: Coarse Sorting

**Goal**: Place every open epic into exactly one of four buckets: **North Star**, **optional additions**, **out of scope**, or **needs review** (transient, resolved before Phase 4).

The downstream priority mapping is:

| Bucket | Maps to (Phase 4) |
|--------|-------------------|
| North Star — high value | P0 |
| North Star — low value | P1 |
| Optional additions — high value | P2 |
| Optional additions — low value | P3 |
| Out of scope | P4 |

## Step 1 — Sub-agent batch review

### 1a. Build the candidate set

```bash
.claude/scripts/dso ticket list --type=epic --status=open,in_progress --format=llm
```

Exclude every epic ID in `OUT_OF_SCOPE_IDS` from Phase 1 — those are already bucketed as out of scope and do not need re-evaluation.

### 1b. Partition into batches of up to 10

Split the candidate set into batches of at most 10 epic IDs. If there are 10 or fewer candidates, there is one batch.

### 1c. Dispatch one sub-agent per batch (sonnet)

For each batch, dispatch a sub-agent using the prompt template in `prompts/coarse-sort-batch.md`. The dispatch payload must include all of these fields:

```json
{
  "directive": "<read the directive section from prompts/coarse-sort-batch.md verbatim>",
  "ticket_command_syntax": "Read each epic with: .claude/scripts/dso ticket show <id>",
  "epic_ids": ["<id1>", "<id2>", "..."],
  "avoid_risk": <true|false>,
  "north_star": "<NORTH_STAR>",
  "out_of_scope_definition": "<OUT_OF_SCOPE_DEFINITION>"
}
```

Each sub-agent returns:

```json
{
  "assignments": [
    {"id": "<epic-id>", "bucket": "north_star" | "optional_additions" | "out_of_scope" | "needs_review", "rationale": "<1 sentence>", "risk_flag": <true|false>}
  ]
}
```

### 1d. Throttle awareness

Before dispatching, check the agent throttle:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
PRE_CHECK_OUTPUT=$(bash "$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh" pre-check 2>/dev/null || echo "MAX_AGENTS: unlimited")
MAX_AGENTS=$(echo "$PRE_CHECK_OUTPUT" | grep "^MAX_AGENTS:" | awk '{print $2}')
MAX_AGENTS="${MAX_AGENTS:-unlimited}"
```

- `MAX_AGENTS=0`: do not dispatch. Tell the user usage is paused and ask whether to wait or sort sequentially in-orchestrator (single-thread, slower).
- `MAX_AGENTS=1`: dispatch batches serially.
- Otherwise: dispatch all batches in parallel.

### 1e. Merge results

Merge every batch's `assignments` array into a single flat array. Build four lists:

- `BUCKETS.north_star`
- `BUCKETS.optional_additions`
- `BUCKETS.out_of_scope` — extend with `OUT_OF_SCOPE_IDS` from Phase 1
- `BUCKETS.needs_review`

## Step 2 — Needs-review clarification

For each epic in `BUCKETS.needs_review`:

1. Re-read the epic: `.claude/scripts/dso ticket show <id>`.
2. Cross-reference Phase 1 research (`VISION_SUMMARY`, `STATE_VS_VISION_GAP`, `RISK_HOTSPOTS`) and the Phase 2 rubric.
3. Reach a confident bucket assignment yourself (`north_star`, `optional_additions`, or `out_of_scope`):
   - If `AVOID_RISK=true` AND your candidate bucket is `north_star` AND the sub-agent flagged the epic with `risk_flag=true`, do NOT assign `north_star` autonomously. Ask the user:
     > *"Epic `<id>` — '<title>' — looks aligned with the North Star, but it carries notable execution risk: \[1-sentence why]. You asked me to lean toward stability. Promote it to North Star anyway, or hold it as optional?"*
     Apply the user's choice.
4. **If you cannot reach high confidence**: STOP and ask the user one specific question. Apply the user's answer to the bucketing decision.
5. Move the epic from `needs_review` into its final bucket. `needs_review` MUST be empty when this step completes.

## Step 3 — Dependency adjustments

For every epic in `BUCKETS.north_star` and `BUCKETS.optional_additions` (only those buckets — out-of-scope epics are not adjusted in this step), compute the full transitive blocker chain:

```bash
.claude/scripts/dso ticket deps <epic-id>
```

`deps` returns direct blockers. To get the full chain (direct + transitive), recurse: for each blocker, run `ticket deps` on it and collect blockers-of-blockers, until you reach epics with no open blockers. Track visited IDs to avoid cycles.

For each epic-with-its-full-blocker-chain, apply these rules **in this order** (treat each rule as a fixed-point pass — re-run rules 1–3 until no bucket changes occur):

### Rule 1 — North Star pulls its blockers up from optional_additions

If a North Star epic is blocked (directly or transitively) by an open epic currently in `BUCKETS.optional_additions`, move the blocking epic to `BUCKETS.north_star`. Mark it as an "enabler" in your notes so Phase 4 inherits priority correctly.

### Rule 2 — Out-of-scope drags its dependents down from optional_additions

If an epic in `BUCKETS.optional_additions` is blocked (directly or transitively) by an open epic in `BUCKETS.out_of_scope`, move the blocked epic to `BUCKETS.out_of_scope`. (We cannot deliver it without first delivering an out-of-scope blocker, so it cannot be in scope.)

### Rule 3 — Out-of-scope blocking North Star is an escalation

If an epic in `BUCKETS.north_star` is blocked (directly or transitively) by:

- An open epic in `BUCKETS.out_of_scope`, OR
- An epic the user declared out of scope in Phase 1 Step 2 (`OUT_OF_SCOPE_IDS`)

**STOP**. Present to the user:

```
DEPENDENCY CONFLICT — needs your call.

North Star epic <id> ('<title>') is blocked by an out-of-scope epic <blocker-id> ('<blocker-title>')
via this chain: <id> ← <intermediate-id> ← ... ← <blocker-id>.

Options:
  (a) Promote the blocker into scope (will become part of the rubric; expect P0/P1 in Phase 4).
  (b) Drop the North Star epic from scope (treat as out of scope and re-assign P4).
  (c) Manually adjust the dependency graph (e.g., the blocker isn't actually required) — tell me the change and I'll re-check.

Which do you want?
```

Apply the user's choice, update buckets accordingly, then re-run Rules 1–3 from the top. Do not move on until no Rule-3 conflicts remain.

## Phase 3 Output

```
=== Phase 3 Complete ===

Coarse sort:
- North Star (<N>): <ids>
- Optional additions (<N>): <ids>
- Out of scope (<N>): <ids>

Dependency adjustments applied:
- <list each move with rule number, e.g. "Rule 1: promoted <id> to North Star (blocks <ns-id>)">

PHASE GATE QUESTION:
Bucketing looks right? I'll move into granular priority assignment (P0–P4) on your confirmation.

Do NOT proceed until user responds.
```
