# Cross-Epic Interaction Scan

This step detects shared-resource conflicts between the new epic being planned and all currently open or in-progress epics. It dispatches haiku-tier classifier agents and collects `CROSS_EPIC_SIGNALS` for the caller.

## Step 2.25a: Fetch Open Epics

Fetch all open and in-progress epics using the ticket CLI:

```bash
.claude/scripts/dso ticket list --type=epic --status=open,in_progress
```

Filter the results to exclude the current epic by ID. The remaining list is the **candidate set**.

If the candidate set is empty (N=0), log the following and skip the rest of this step:

> No open epics — scan skipped.

Set `interaction_signals=[]` and proceed directly to Step 2.5.

## Step 2.25b: Load Epic Details

For each epic in the candidate set, load its full content:

```bash
.claude/scripts/dso ticket show <id>
```

Extract from each epic:
- `approach_summary`: the proposed technical approach (from the Description or Approach section)
- `success_criteria`: the list of success criteria / done definitions

If an epic has no approach or success criteria, use the epic title as a fallback approach summary and set success_criteria to an empty array.

## Step 2.25c: Batch into Groups of 20

Partition the candidate epics into batches of up to 20 epics each. If there are 20 or fewer epics, there is one batch. If there are more than 20, create additional batches until all epics are covered.

## Step 2.25d: Usage-Aware Throttle Check

Before dispatching classifier agents, perform a usage-aware pre-check:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"  # shim-exempt: prompt template — PLUGIN_SCRIPTS derived from CLAUDE_PLUGIN_ROOT by the executing sub-agent, not a hardcoded path
PRE_CHECK_OUTPUT=$(bash "$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh" pre-check 2>/dev/null || echo "MAX_AGENTS: unlimited")  # shim-exempt: prompt template — uses CLAUDE_PLUGIN_ROOT-derived PLUGIN_SCRIPTS
MAX_AGENTS=$(echo "$PRE_CHECK_OUTPUT" | grep "^MAX_AGENTS:" | awk '{print $2}')
MAX_AGENTS="${MAX_AGENTS:-unlimited}"
```

- If `MAX_AGENTS=0` (usage paused), defer the scan entirely. Log:
  > Cross-epic scan deferred — usage at capacity. Proceeding without interaction signals.
  Set `interaction_signals=[]` and proceed to Step 2.5.

- If `MAX_AGENTS=1`, process batches serially (one agent at a time).
- If `MAX_AGENTS` is unlimited or greater than 1, dispatch all batches in parallel up to the cap.

## Step 2.25e: Dispatch Classifier per Batch

For each batch, dispatch `dso:cross-epic-interaction-classifier` (haiku tier) with:

```json
{
  "new_epic": {
    "id": "<current epic ID>",
    "title": "<current epic title>",
    "approach_summary": "<current epic approach>",
    "success_criteria": ["<criterion 1>", "..."]
  },
  "open_epics": [
    {
      "id": "<open epic ID>",
      "title": "<open epic title>",
      "approach_summary": "<open epic approach>",
      "success_criteria": ["<criterion 1>", "..."]
    }
  ]
}
```

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
