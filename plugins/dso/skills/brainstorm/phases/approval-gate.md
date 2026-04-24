# Phase 2 Step 4 — Approval Gate

<HARD-GATE>
Do NOT present this gate unless ALL of the following have completed or gracefully degraded with a logged rationale:
- Step 2.5: Gap analysis (self-review)
- Step 2.6: Web research phase (run OR skipped with a logged rationale per Step 2.6 graceful degradation rules)
- Step 2.75: Scenario analysis (run OR skipped because ≤2 success criteria)
- SC Gap Check: scenario-to-SC coverage verified; SCs revised if gaps found, or skip logged
- Step 3: Fidelity review (all three core reviewers completed or escalated to user)
- Structural-change re-review: if the spec was structurally changed AFTER the fidelity review completed — including an epic split, a SC count change of more than 2, or scope migration between epics — the full fidelity review pipeline (Step 3) MUST be re-run on the revised spec before this gate is presented. Prior review scores are invalidated by structural changes and do not satisfy this checklist item.
- FEASIBILITY_GAP: if a `## FEASIBILITY_GAP` section is present in the spec at this point, it MUST be surfaced explicitly in the approval gate presentation as an unresolved prerequisite — do NOT silently omit it. The user must explicitly acknowledge the gap when selecting option (a).

If any of the above has NOT completed, stop and execute it before presenting this gate. The user's ability to request a re-run via option (b) or (c) is for second-pass cycles only — it does not substitute for a mandatory first pass.
</HARD-GATE>

## External Dependencies Contradiction Gate

When `planning.external_dependency_block_enabled` is on (source: `planning-config.sh`):

1. Read the `## External Dependencies` block from the current epic spec.
2. Scan each entry for contradictions: an entry where `handling: claude_auto` AND `claude_has_access` is `no` or `unknown`.
3. If any contradiction is found:
   - Do NOT present approval gate options.
   - Emit a diagnostic naming the contradicting entry:
     ```
     Approval gate blocked: External Dependency "<name>" is declared handling=claude_auto but claude_has_access=<no|unknown>.
     Resolve this contradiction before the gate can open:
     - Option 1: Set handling=user_manual (mark as manual step for sprint)
     - Option 2: Confirm claude_has_access=yes if you have verified access
     ```
   - Wait for the practitioner to resolve the contradiction, then re-run this gate check.
4. For each entry where `verification_command` is omitted and `confirmation_token_required` is not already set:
   - Add `confirmation_token_required: true` to the entry if the entry is `handling: user_manual`.
   - This `confirmation_token_required` marker is consumed by sprint at pause-handshake time.
5. If `planning.external_dependency_block_enabled` is off: skip this gate entirely and proceed to approval gate presentation.

## Gate Presentation

Present the validated spec to the user using **AskUserQuestion** with 4 options. Use **"Spec Review"** as the question header (do NOT use "Approval" — it primes misinterpretation of non-approving options as approval).

Label options (b) and (c) based on whether this is a first run or a re-run (the scrutiny pipeline must complete before this gate; these labels apply only to gate-triggered re-runs):

- **If web research (Step 2.6) ran during the mandatory pipeline pass**: label (c) as "Re-run web research phase"
- **If web research was skipped via graceful degradation (no bright-line triggers fired)**: label (c) as "Perform additional web research" (note: this is a first-time run, not a re-run)
- **If scenario analysis (Step 2.75) ran during the mandatory pipeline pass**: label (b) as "Re-run red/blue team review cycle"
- **If scenario analysis was skipped via graceful degradation (≤2 success criteria)**: label (b) as "Perform red/blue team review cycle" (note: this epic has ≤2 success criteria — consider adding more before running scenario analysis)

### Provenance Annotation Rendering

Before presenting success criteria, render each criterion with a bold/normal annotation based on its provenance:

- **inferred** or **researched** criteria → render in **bold** (visually prominent — these require user review)
- **injected** criteria → render in **bold** (same as inferred/researched — requires practitioner awareness)
- **explicit** or **confirmed-via-gap-question** criteria → render in normal text (user already confirmed these)

Immediately before the option list, include an annotation summary line:

```
N of M criteria confirmed; K inferred requiring review; J injected from cross-epic scan
```

where N = count of explicit + confirmed-via-gap-question criteria, M = total criteria count, K = count of inferred + researched criteria, J = count of injected criteria. This provenance summary line appears before the (a)/(b)/(c)/(d) options.

Note: summary confirmation (Phase 1 Gate Step 1) does NOT collapse with gap analysis (Phase 1 Gate Step 2) — they are always presented as separate steps.

### Gate Template

```
=== Epic Spec Ready for Review ===

**[Epic Title]**

## Context
[narrative]

## Success Criteria
- **[inferred or researched criterion — bold because it requires user review]**
- [explicit or confirmed criterion — plain text]

## Scenario Analysis
[if ran]

## Dependencies
[...]

_N of M criteria confirmed; K inferred requiring review_

Please choose how to proceed:

(a) Approve — advance to Phase 3 Step 0 (Follow-on Epic Gate), then Step 1 (Ticket Creation)
(b) [Perform / Re-run] red/blue team review cycle — re-runs scenario analysis (Step 2.75) and re-presents this gate
(c) [Perform / Re-run] additional web research — re-runs web research phase (Step 2.6) and re-presents this gate
(d) Let's discuss more — pause for conversational review before re-presenting this gate
```

<HARD-GATE>
Do NOT advance to Phase 3 unless the user explicitly selects option **(a) Approve** at this gate. Options (b), (c), and (d) are non-approving — they loop back to this gate after their respective actions complete. After option (d) discussion ends, you MUST re-present this gate in full (all 4 options) and wait for the user to select (a) before proceeding. A user saying "ready to proceed" or "looks good" during discussion is NOT equivalent to selecting (a) — re-present the gate and let them choose.
</HARD-GATE>

## Option Behaviors

- **(a) Approve**: Record the planning-intelligence log entry (see `epic-description-template.md`), then advance to Phase 3 (Ticket Integration). The log captures which bright-line trigger conditions fired (or "none"), whether scenario analysis ran and how many scenarios survived the blue team filter, and whether the practitioner requested additional cycles via this gate. State vocabulary: "not triggered" / "triggered" / "re-triggered via gate".
- **(b) Re-run scenario analysis**: Re-execute Step 2.75 (Scenario Analysis) with the current spec. Update the Scenario Analysis section in the spec with new results. Re-present this gate. On re-presentation, label (b) as "Re-run red/blue team review cycle" (scenario analysis already ran).
- **(c) Re-run web research**: Re-execute Step 2.6 (Web Research Phase) with the current spec. Update the Research Findings section. Re-present this gate. On re-presentation, label (c) as "Re-run web research phase" (research already ran).
- **(d) Discuss more**: Pause skill execution and engage in open conversational review with the user. When the user indicates they are ready to proceed, you MUST re-present this full gate (all 4 options with the `=== Epic Spec Ready for Review ===` block) and wait for the user to select an option. Do NOT interpret conversational signals ("looks good", "let's move on", "ready") as implicit approval — the user must select option (a) at the re-presented gate to advance.

If changes are requested during discussion or after any re-run, revise the spec and re-run affected fidelity reviewers before re-presenting this gate.
