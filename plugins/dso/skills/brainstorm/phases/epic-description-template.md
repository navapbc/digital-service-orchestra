# Epic Description Template

Canonical template for the epic description written at Phase 3 Step 1 via `ticket create epic` (new epic) or `ticket edit --description` (existing epic). Use this template in both cases — the only difference is the CLI verb.

**Clean-text requirement**: Strip all provenance markers and bold emphasis before writing the description. Provenance annotations (including `injected`) are used only during the approval-gate review phase — the final ticket description must be written as clean plain text with no markup from the provenance tracking step.

## Template

```
## Context
[context narrative]

## Success Criteria
- [criterion 1]
- [criterion 2]

## Closure Checks
- [durable end-state acceptance criterion that would fail the session-infeasibility check but is not transitional work]
(Leave empty if all SCs pass the verifiable-sc-check litmus; populate only for criteria routed here via option (c))

<!--
One-shot-verifiable requirement (enforced at brainstorm time):
Each Closure Check item MUST be one-shot verifiable — phrased as one of:
  (a) a command that produces a deterministic pass/fail (e.g., "grep -n 'X' file.md returns ≥1 match")
  (b) a state check on a named artifact (e.g., "file <path> exists and contains <signal>")
  (c) a reference to a specific named artifact whose presence/absence is the check (e.g., "ADR-NNNN published at docs/adr/")

REJECT items that describe human activity, judgment, or aggregate feedback — e.g.,
"team has reviewed the design", "users find the UI intuitive", "documentation is clear".
These cannot be evaluated one-shot at closure time and must be reframed or removed.
-->

Examples of acceptable Closure Check items:
- "`grep -n 'contract_version' ${CLAUDE_PLUGIN_ROOT}/docs/contracts/end-state-item-validator.md` returns ≥1 match"
- "the file `docs/adr/0042-closure-checks-schema.md` exists and contains an `## Decision` heading"
- "`./scripts/health-check.sh prod` exits 0"

## Dependencies
[dependencies or 'None']

## Approach
[1-2 sentences on the chosen approach from Phase 2]

## Scenario Analysis
{scenario analysis content from scrutiny pipeline, if generated}

### Planning Intelligence Log

- **Gap analysis (Step 1)**: [artifacts checked — N missing | all covered | skipped — no user-named artifacts]
  - Parts executed: [Part A artifact check | Part B technical self-review | Part C shared artifact impact | all parts]
- **Web research (Step 2.6)**: [not triggered | triggered | re-triggered via gate]
  - Bright-line conditions that fired: [list conditions, or "none"]
- **Scenario analysis (Step 2.75)**: [not triggered | triggered | re-triggered via gate]
  - Scenarios surviving blue team filter: [count, or "skipped — ≤2 success criteria"]
- **Practitioner-requested additional cycles**: [none | web research re-run N time(s) | scenario analysis re-run N time(s) | both re-run]
- **Follow-on scrutiny (Step 0)**: [not triggered | triggered — depth: <follow_on_scrutiny_depth>]
- **Feasibility resolution (Step 2.5)**: [not triggered | triggered — cycles: <feasibility_cycle_count>, gap: <triggering gap description>]
- **LLM-instruction signal (Step 5)**: [not triggered | triggered — keyword: <matched_keyword>]
- **Scale context (Step 0)**: [<numeric estimate> | small scale (default) | not applicable (no volume decision) | user-provided: <value>]

<!-- REQUIRED: populate this section from the approval-gate log recorded at Phase 2 Step 4. Do NOT omit this heading — it is a contract signal consumed by ticket-migrate-brainstorm-tags.sh and downstream tooling. -->
```

## Invocation

**New epic** (arrived via Convert-to-Epic or no ticket ID):

```bash
.claude/scripts/dso ticket create epic "<title>" --priority <priority> -d "$(cat <<'DESCRIPTION'
<paste template above, filled in>
DESCRIPTION
)"
```

**Existing epic** (Type Detection Gate identified `ticket_type: epic`):

```bash
.claude/scripts/dso ticket edit <epic-id> --description "$(cat <<'DESCRIPTION'
<paste template above, filled in>
DESCRIPTION
)"
```

## Priority (new epics only)

Before creating the ticket, read and apply the value/effort scorer from `skills/shared/prompts/value-effort-scorer.md`. Assess the epic's value (1–5) and effort (1–5) based on the conversation context, map to the recommended priority via the scorer's matrix, and use that priority with `--priority <priority>`.
