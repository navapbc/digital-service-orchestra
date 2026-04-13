## Phase 7: Remediation Loop (/dso:sprint)

When validation score < 5:

### Reversion Detection

Before creating remediation tasks, invoke `/dso:oscillation-check` as a sub-agent
(`subagent_type="general-purpose"`, `model="sonnet"`) with:
- `files_targeted`: files inferred from the REMEDIATION output
- `context`: remediation
- `epic_id`: the current epic

If it returns OSCILLATION: flag the specific items to the user before creating tasks.
Report which remediation items target files already modified by completed remediation.
If it returns CLEAR: proceed to create tasks normally.

### Gap Classification Step (/dso:sprint)

**User confirmation required before any intent_gap SC is routed to brainstorm — autonomous brainstorm invocation is prohibited.**

For each failing success criterion (SC) identified in Phase 6 validation, dispatch the gap-classification sub-agent to classify it before creating remediation tasks.

**Dispatch** (`subagent_type="general-purpose"`, `model="sonnet"`) with the prompt from `skills/sprint/prompts/gap-classification.md` and the following context for each failing SC: # shim-exempt: internal prompt path reference
- The exact failing SC criterion text from the completion-verifier output
- The completion-verifier failure explanation for the SC
- Relevant code snippets or file paths from the validation context

**Parse output**: Scan all lines prefixed with `GAP_CLASSIFICATION: ` and extract:
- Classification value: `intent_gap` or `implementation_gap`
- Routing value: `brainstorm` or `implementation-plan`
- Explanation text

**REPLAN_ESCALATE override**: If a previous `/dso:implementation-plan` invocation returned `REPLAN_ESCALATE` for this SC, override any `implementation_gap` classification to `intent_gap` before routing. Log that the re-classification was triggered by REPLAN_ESCALATE, not the original gap-classification output.

**Failure contract**: If the gap-classification sub-agent output is absent, malformed (missing `ROUTING:` or `EXPLANATION:` fields, empty explanation), or contains an unrecognized classification value, treat all affected failing SCs as `intent_gap` (fallback to intent_gap — the safer default). Log a warning so silent degradation is detectable in debug output.

**Routing rules**:

- `intent_gap` + `ROUTING: brainstorm` — REQUIRE user confirmation before proceeding. Do NOT autonomously invoke `/dso:brainstorm`. Present the failing SC text and classification explanation to the user. Ask the user to confirm that brainstorm re-examination is desired. Proceed to `/dso:brainstorm` only after explicit user approval. If the user declines, mark the SC as deferred and continue to the next SC.

- `implementation_gap` + `ROUTING: implementation-plan` — autonomous remediation is permitted. Proceed directly to **Step 1 (Create Remediation Tasks)** below without requiring user confirmation. **Important**: `ROUTING: implementation-plan` is a routing signal label — it does NOT mean invoking `/dso:implementation-plan` as a separate skill. The action for `implementation_gap` is bug-task creation via the Phase 7 Step 1 remediation flow (`.claude/scripts/dso ticket create bug`), which creates targeted implementation tasks under the epic. This is the correct and intended behavior for filling a clear implementation gap.

### Step 1: Create Remediation Tasks (/dso:sprint)

For each item in the validation agent's FAIL/REMEDIATION output:

```bash
# Title format: [Component]: [Condition] -> [Observed Result]
# Follow ${CLAUDE_PLUGIN_ROOT}/skills/create-bug/SKILL.md for description format
.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" --priority 1 --parent=<epic-id> -d "## Incident Overview ..."
```

### Step 2: Validate Ticket Health (/dso:sprint)

```bash
.claude/scripts/dso validate-issues.sh
```

### Step 3: Return to Phase 3 (/dso:sprint)

Re-enter the batch planning loop with the new remediation tasks. These tasks will be picked up as ready work and executed in the next batch.

### Safety Bounds

```
Remediation loop: Score<5 → Create fix tasks → P3 (Batch) → P4 (Execute) → P6 (Re-validate)
  → [score=5] P8 (Complete)
  → [score<5] → Create fix tasks (loop)
  → [context compaction] P8 (Shutdown)
```
