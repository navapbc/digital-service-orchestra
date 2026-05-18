# Cross-Epic Interaction Scan

This step detects shared-resource conflicts between the new epic being planned and all currently open or in-progress epics. It dispatches haiku-tier classifier agents and collects `CROSS_EPIC_SIGNALS` for the caller.

## Steps 2.25a–2.25d: Setup (single bash invocation)

The setup pipeline — fetching the candidate epic list, loading each
epic's description, extracting `approach_summary` and
`success_criteria`, partitioning into batches of 5, and the usage-aware
throttle check — is encapsulated in
`${CLAUDE_PLUGIN_ROOT}/scripts/cross-epic-scan-prep.sh` so the
orchestrator does not absorb every candidate epic's content into its
working context (bug e253-f62a).

The orchestrator's setup responsibility collapses to:

1. **Write the `new_epic` payload** distilled from session state to a
   tmp path:

   ```bash
   _NEW_EPIC=$(mktemp /tmp/new-epic.XXXXXX.json)
   cat > "$_NEW_EPIC" <<JSON
   {
     "id": "<current epic ID>",
     "title": "<current epic title>",
     "approach_summary": "<distilled from Phase 1/2>",
     "success_criteria": ["<sc1>", "<sc2>"]
   }
   JSON
   ```

2. **Run the prep script**, which performs all of 2.25a–2.25d in one
   shot:

   ```bash
   _OUT=$(mktemp -d /tmp/cross-epic-scan.XXXXXX)
   PREP_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/cross-epic-scan-prep.sh" \
       --epic-id <current_epic_id> \
       --new-epic-payload "$_NEW_EPIC" \
       --out-dir "$_OUT")
   ```

3. **Parse the result** (key=value lines on stdout):

   - `CANDIDATE_COUNT=<int>` — number of open epics after self-filter
   - `BATCH_COUNT=<int>` — number of `batch_<N>.json` files written
   - `BATCH_FILES=<csv>` — comma-separated paths to dispatch
   - `MAX_AGENTS=<int|unlimited>` — pre-check result for dispatch fan-out
   - `STATUS=ok|skipped:no_candidates|skipped:usage_paused`

4. **Honor STATUS**:

   - `STATUS=skipped:no_candidates` — set `interaction_signals=[]` and
     proceed directly to Step 2.5. Log: `No open epics — scan skipped.`
   - `STATUS=skipped:usage_paused` — set `interaction_signals=[]` and
     proceed to Step 2.5. Log: `Cross-epic scan deferred — usage at
     capacity. Proceeding without interaction signals.`
   - `STATUS=ok` — continue to Step 2.25e.

5. **Honor MAX_AGENTS** when dispatching in Step 2.25e:

   - `MAX_AGENTS=1` → dispatch batches serially (one at a time).
   - `MAX_AGENTS=<int>` or `unlimited` → dispatch up to the cap in
     parallel.

Rationale for the 5-epic batch cap: each haiku-tier dispatch payload (5
× 2–10KB serialized epic content + agent instructions) stays well below
the auto-compaction threshold. The prior cap (20) was observed in
production to trigger mid-run compaction, producing silent JSON loss
and cross-ticket content conflation (bug 4bf1-3198). The cap is the
script's default; override with `--batch-size <N>` only when you have
measured evidence that a different size avoids both compaction and
underutilization.

## Step 2.25e: Dispatch Classifier per Batch

For each path in `BATCH_FILES` (comma-separated, from the prep-script
output), dispatch `dso:cross-epic-interaction-classifier` (haiku tier).
The classifier's input is the path itself — the prep script has already
written the canonical payload shape:

```json
{
  "new_epic":  { "id": "...", "title": "...", "approach_summary": "...", "success_criteria": ["..."] },
  "open_epics": [
    { "id": "...", "title": "...", "approach_summary": "...", "success_criteria": ["..."] }
  ]
}
```

The classifier reads its assigned batch file and returns a
`CROSS_EPIC_SIGNALS` array. The orchestrator does NOT need to inline
this content into its own context — pass the batch path to the agent
and let the agent read it.

**Failure handling**: If a batch dispatch fails or returns unparseable output, log a warning and continue:

> Warning: cross-epic classifier failed for batch [N] — continuing without signals from this batch.

Do not let classifier failures block the brainstorm workflow. Partial signal sets are acceptable.

## Step 2.25f: Merge Signals

After all batches complete, merge the `interaction_signals` arrays from all successful batch responses into a single flat array.

Set `CROSS_EPIC_SIGNALS` to this merged array.

## Step 2.25g: Route by Severity

Route signals based on their severity tier:

| Severity | Action |
|----------|--------|
| **benign** | Log the signal for awareness (include `shared_resource` and `description`); no further action required |
| **consideration** | Carry `CROSS_EPIC_SIGNALS` forward — AC injection handled per story 2629-66cb |
| **ambiguity** | Carry `CROSS_EPIC_SIGNALS` forward — halt/resolution handling per story 3c31-8050 |
| **conflict** | Carry `CROSS_EPIC_SIGNALS` forward — halt/resolution handling per story 3c31-8050 |

If `CROSS_EPIC_SIGNALS` is empty or contains only **benign** signals, proceed directly to Step 2.5 with no further action.

If `CROSS_EPIC_SIGNALS` contains **consideration**, **ambiguity**, or **conflict** signals, pass the array to the caller (the brainstorm orchestrator) before proceeding to Step 2.5. The caller determines how to handle those signals based on the stories referenced above.

## Logging Format

For each benign signal logged, emit:

> [cross-epic-scan] benign: `{shared_resource}` — {description}

For signals carried forward (consideration/ambiguity/conflict), the brainstorm orchestrator handles display to the user.
