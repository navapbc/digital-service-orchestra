# Phase 2: Stakeholder Interview

**Goal**: Capture, in the user's own framing, a prioritization rubric that Phase 3 and Phase 4 can apply mechanically.

The rubric has four pillars. By the end of Phase 2 you must be able to answer ALL of these with high confidence:

| Pillar | Driving questions |
|--------|-------------------|
| **North Star** | What is the single most important value the project will deliver? What does success look like? Are there any immovable constraints, hard deadlines, or absolute dealbreakers coming up that trump everything else? |
| **Risk Tolerance** | Should we pull risk forward to derisk future work, or push risk back to deliver a reliable release on time? How much of our effort should go toward 'quick wins' (low effort / moderate value) vs. 'major strategic bets' (high effort / high value) vs. 'housekeeping' (tech debt / bugs)? |
| **Tradeoffs** | When everything else is equal, which user archetype or golden path should be prioritized above the others? Is it more important to deliver more functionality or higher quality? |
| **Out of Scope** | What is out of scope for now? |

## Step 1 — Socratic dialogue loop

Open the phase by sharing Phase 1 outputs as framing (do not re-display verbatim; reference them):

> *"From Phase 1, here's how I see the landscape: \[1-sentence vision summary]. The biggest gap between today's code and that vision is \[1-sentence gap]. The riskiest area right now appears to be \[1-sentence risk]. Let me ask a few questions to set the prioritization rubric."*

Then enter a loop asking **exactly one question per turn**. Rules:

- One question per turn. No batching.
- Never re-ask anything the user has already answered (including paraphrases).
- Anchor questions in Phase 1 context wherever possible (e.g., *"Phase 1 surfaced \<hotspot\> as a risk area — does that change how aggressively you want to invest in stabilization?"*).
- Cover all four pillars before declaring high confidence. If the user volunteers two pillars in one answer, don't re-ask them — just check the remaining pillars.
- If the user gives a vague answer to a pillar, probe once for sharpness. Don't probe a third time on the same pillar — accept whatever the user lands on.

**Stop the loop** when you can write a 1–2 sentence answer for each of the four pillars **without hedging**.

## Step 2 — Understanding gate

Compose a summary in this exact shape:

```
Prioritization Rubric (draft for approval):

**North Star**
<1–3 sentences. Include the single most important value, what success looks like, and any hard deadlines or dealbreakers.>

**Risk Tolerance**
<1–3 sentences. Cover risk-forward vs. risk-back AND the rough split between quick wins / strategic bets / housekeeping.>

**Tradeoffs**
<1–3 sentences. Cover user-archetype / golden-path priority AND functionality-vs-quality bias.>

**Out of Scope**
<1–3 sentences listing themes, areas, or specific epics the user has placed out of scope. Include the IDs from Phase 1's OUT_OF_SCOPE_IDS if any.>
```

Present this summary verbatim. Then ask:

> *"Does this capture your prioritization rubric? Approve as-is, or tell me what to adjust."*

## Step 3 — Approval gate

- **If the user approves**: store the rubric as `NORTH_STAR`, `RISK_TOLERANCE`, `TRADEOFFS`, `OUT_OF_SCOPE_DEFINITION`. Derive `AVOID_RISK` (boolean) from `RISK_TOLERANCE`:
  - `AVOID_RISK = true` if the user expressed a preference for stability, on-time delivery, deferring risk, or minimizing scope changes.
  - `AVOID_RISK = false` otherwise (including explicit risk-tolerant framing, or no clear signal either way).
  - If the signal is ambiguous, ask one disambiguating question rather than guessing.

- **If the user does NOT approve**: return to Step 1. Probe the specific pillars the user flagged. Re-draft the rubric and re-present. Repeat until approved.

## Phase 2 Output

Once the rubric is approved, emit:

```
=== Phase 2 Complete ===

Rubric locked in:
- North Star: <1-line summary>
- Risk Tolerance: <1-line summary>; AVOID_RISK=<true|false>
- Tradeoffs: <1-line summary>
- Out of Scope: <1-line summary>

PHASE GATE QUESTION:
Ready to coarse-sort the backlog into North Star / optional additions / out of scope?

Do NOT proceed until user responds.
```
