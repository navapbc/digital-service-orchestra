---
name: prioritize-epics
description: Use when the user wants to (re)prioritize an existing backlog of epics — assigns P0–P4 priorities across all open epics based on a stakeholder-defined North Star, risk tolerance, tradeoffs, and out-of-scope criteria. Runs a 5-phase pipeline that (1) assesses each epic's clarity, distills the overall vision, compares it to current state, and maps risk hotspots; (2) interviews the stakeholder via Socratic dialogue to capture the prioritization rubric; (3) coarse-sorts epics into North Star / optional additions / out of scope using batched sub-agent evaluation; (4) granular-sorts within each bucket into P0–P4; (5) offers to brainstorm any P0/P1 epics that lack the `brainstorm:complete` tag. Trigger phrases include 'prioritize the epics', 'reprioritize the backlog', 'set epic priorities', 'sort the backlog', 'rank the epics', 'what should we work on next at the epic level'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:prioritize-epics requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Prioritize Epics

Act as a Senior Product Manager. Assign P0–P4 priorities across an existing backlog of open epics using a stakeholder-defined rubric. This skill prioritizes existing epics; it does **not** create new ones. Use `/dso:roadmap` or `/dso:brainstorm` to create epics.

## Usage

```
/dso:prioritize-epics
```

Interactive. Walks through 5 phases with explicit user confirmation between each. Supports dryrun mode via `/dso:dryrun /dso:prioritize-epics`.

## Scope

- **In scope**: assigning priorities (P0–P4) to existing open epics; adding clarifying comments to epics that lacked enough information; offering to brainstorm any P0/P1 epic that is not yet brainstormed.
- **Out of scope**: creating new epics, modifying epic descriptions or success criteria (beyond appending a Phase 1 clarification comment), decomposing epics into stories/tasks.

## Layout

This skill's logic is split across phase files. Load each on demand:

| File | When to read |
|------|--------------|
| `phases/phase-1-assessment.md` | Phase 1 — project assessment |
| `phases/phase-2-stakeholder.md` | Phase 2 — stakeholder interview |
| `phases/phase-3-coarse-sort.md` | Phase 3 — coarse sorting |
| `phases/phase-4-granular-sort.md` | Phase 4 — granular sorting |
| `phases/phase-5-brainstorming.md` | Phase 5 — brainstorming follow-up |
| `prompts/epic-clarity-review.md` | Phase 1 Step 1 sub-agent prompt |
| `prompts/vision-summary.md` | Phase 1 Step 3 sub-agent prompt |
| `prompts/vision-gap.md` | Phase 1 Step 4 sub-agent prompt |
| `prompts/risk-hotspots.md` | Phase 1 Step 5 sub-agent prompt |
| `prompts/coarse-sort-batch.md` | Phase 3 Step 1 sub-agent prompt |

## Session State

Maintain these variables across phases:

| Variable | Set in | Used by |
|----------|--------|---------|
| `OUT_OF_SCOPE_IDS` | Phase 1 Step 2 (epics the user said are out of scope) | Phase 3 (excluded from batch sort) |
| `CLARIFIED_IDS` | Phase 1 Step 2 (epics that got a clarification comment) | Logging only |
| `VISION_SUMMARY` | Phase 1 Step 3 | Phase 2 framing, Phase 3 subagent prompt |
| `STATE_VS_VISION_GAP` | Phase 1 Step 4 | Phase 2 framing |
| `RISK_HOTSPOTS` | Phase 1 Step 5 | Phase 2 framing, risk-tolerance discussion |
| `NORTH_STAR` | Phase 2 Step 2 (approved) | Phase 3, 4 |
| `RISK_TOLERANCE` | Phase 2 Step 2 (approved) | Phase 3, 4 |
| `TRADEOFFS` | Phase 2 Step 2 (approved) | Phase 4 |
| `OUT_OF_SCOPE_DEFINITION` | Phase 2 Step 2 (approved) | Phase 3, 4 |
| `AVOID_RISK` | Phase 2 Step 2 (boolean derived from RISK_TOLERANCE) | Phase 3 subagent prompt, Phase 3 Step 2 |
| `BUCKETS` | Phase 3 (after dependency adjustments) | Phase 4 |

## Phase Gate Pattern

After each phase, emit:

```
=== Phase [N] Complete ===

[Summary of what was accomplished in this phase]

PHASE GATE QUESTION:
[Specific confirmation question from the phase]

Do NOT proceed until user responds.
```

## Execution Framework

Read each phase file in order. Do NOT skip phases. Do NOT proceed to the next phase without the user clearing the phase gate.

1. Read `phases/phase-1-assessment.md` and execute it.
2. Read `phases/phase-2-stakeholder.md` and execute it.
3. Read `phases/phase-3-coarse-sort.md` and execute it.
4. Read `phases/phase-4-granular-sort.md` and execute it.
5. Read `phases/phase-5-brainstorming.md` and execute it.

## Guardrails

- **One question at a time.** All Socratic dialogue loops (Phase 1 Step 2, Phase 2 Step 1) ask exactly one question per turn. Never batch multiple questions.
- **Never re-ask answered questions.** Before each question, review prior turns for semantic duplicates.
- **Never assign a priority without an approved rubric.** Phase 2 Step 3 (approval gate) must clear before any priority is written.
- **Never modify epic priorities mid-process.** Priorities are written only in Phase 4 — except the Phase 1 Step 2 P4 assignment for user-declared out-of-scope epics, which is the explicit exception.
- **Never write priorities to closed or archived epics.** Filter all epic lists by `--status=open,in_progress`.
- **Never create or decompose epics.** This skill only re-prioritizes. If the user asks to create or decompose, point them at `/dso:roadmap`, `/dso:brainstorm`, or `/dso:preplanning`.
- **Always use `.claude/scripts/dso ticket edit <id> --priority=<n>`** to set priorities. Priorities are integers 0–4.

## Ticket CLI Quick Reference

| Action | Command |
|--------|---------|
| List open epics | `.claude/scripts/dso ticket list --type=epic --status=open,in_progress --format=llm` |
| Show one epic | `.claude/scripts/dso ticket show <id>` |
| Add a comment | `.claude/scripts/dso ticket comment <id> "<body>"` |
| Set priority | `.claude/scripts/dso ticket edit <id> --priority=<0-4>` |
| Dependency graph | `.claude/scripts/dso ticket deps <id>` |
| Check tag | inspect `tags` field in `.claude/scripts/dso ticket show <id>` |

Always verify exact syntax via `${CLAUDE_PLUGIN_ROOT}/docs/ticket-cli-reference.md` before invoking ticket commands.
