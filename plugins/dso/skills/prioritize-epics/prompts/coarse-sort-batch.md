# Sub-Agent Prompt: Coarse-Sort Batch Evaluator (Phase 3 Step 1)

## Dispatch payload

The orchestrator dispatches this sub-agent with a JSON payload of the form:

```json
{
  "directive": "<the full Directive section below, passed verbatim by the orchestrator>",
  "ticket_command_syntax": "Read each epic with: .claude/scripts/dso ticket show <id>",
  "epic_ids": ["<id1>", "<id2>", "..."],
  "avoid_risk": true | false,
  "north_star": "<North Star definition from Phase 2>",
  "out_of_scope_definition": "<Out of Scope definition from Phase 2>"
}
```

The orchestrator MUST include every field. The list of `epic_ids` MUST contain at most 10 IDs.

## Directive (passed to the sub-agent)

> You are an evaluator tasked with sorting epics into 4 groups: **North Star**, **optional additions**, **out of scope**, and **needs review**. Read each epic in full. Compare the epic against the North Star and Out of Scope definitions provided. Sort high confidence matches as North Star or Out of Scope respectively. Sort low confidence matches as "needs review". Sort everything else as "optional additions". If the user indicated a desire to avoid risk, downgrade high risk epics from "optional additions" to "out of scope" and from North Star to "needs review".

## Procedure

1. For each ID in `epic_ids`, read the full epic:
   ```bash
   .claude/scripts/dso ticket show <id>
   ```
   You may dispatch up to 5 of these in parallel.

2. For each epic:
   - Compare its purpose against the supplied `north_star`. If it directly advances the North Star, it is a high-confidence North Star match.
   - Compare it against the supplied `out_of_scope_definition`. If it directly falls under what the user has placed out of scope, it is a high-confidence out-of-scope match.
   - If both checks are ambiguous (the epic could plausibly be either, or it advances something adjacent to but not in the North Star), mark it `needs_review`.
   - Otherwise, it is an `optional_additions` epic — in scope, but not a top-priority driver of the North Star.

3. Assess **risk** for each epic. An epic is "high risk" if it has one or more of:
   - Touches an area the description itself calls out as fragile, legacy, or in-flight migration.
   - Requires significant infrastructure, vendor, or external-dependency change.
   - Cross-cutting effect on many subsystems, suggested by phrases like "across all", "every", "platform-wide", or by the size of the success-criteria list.
   - Explicit "risks" / "open questions" / "unknowns" section in the epic description.

   Set `risk_flag = true` for high-risk epics, `false` otherwise.

4. Apply the `avoid_risk` downgrade rule (only if the orchestrator passed `avoid_risk: true`):
   - Epic classified as `optional_additions` AND `risk_flag: true` → downgrade to `out_of_scope`.
   - Epic classified as `north_star` AND `risk_flag: true` → downgrade to `needs_review`.

   If `avoid_risk: false`, do NOT downgrade — risk is informational only.

## Output

Return ONLY this JSON object — no narration, no markdown fence:

```json
{
  "assignments": [
    {
      "id": "<epic-id>",
      "bucket": "north_star" | "optional_additions" | "out_of_scope" | "needs_review",
      "rationale": "<1 sentence — why this bucket, citing the alignment evidence>",
      "risk_flag": true | false
    }
  ]
}
```

Every ID in the input `epic_ids` MUST appear exactly once in `assignments`.

## Calibration

- **High-confidence** means a sober reader would agree on the bucket without needing to ask follow-up questions. If you find yourself wanting to ask the user "did you mean X or Y?" — that's a `needs_review` signal, not a forced choice.
- **Do NOT bias toward North Star.** Many epics in a healthy backlog are "in scope but not strategic" — that's exactly what `optional_additions` is for. The North Star bucket should be the strict subset that directly drives the user's stated single-most-important value.
- **Do NOT use child counts, completion percentage, or last-modified date as bucket signals.** Those are work-readiness signals, not prioritization signals.
- **Keep rationales to a single sentence.** Cite the specific phrase in the North Star or Out of Scope definition that drove the decision.
