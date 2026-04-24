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

## Dependencies
[dependencies or 'None']

## Approach
[1-2 sentences on the chosen approach from Phase 2]

## Scenario Analysis
{scenario analysis content from scrutiny pipeline, if generated}

### Planning Intelligence Log

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
