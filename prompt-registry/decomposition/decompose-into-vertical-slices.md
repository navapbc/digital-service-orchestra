---
id: decompose-into-vertical-slices
title: Decompose an Initiative Into Vertical-Slice Stories
category: decomposition
operation: Given an initiative with measurable success criteria and the work that already exists for it, draft the new vertical-slice user stories needed so the collective set fully covers every success criterion.
when_to_use: >
  When a large initiative (an epic, a feature area) must be broken into
  independently-deliverable user stories before planning, and you need each story
  to be a vertical slice with measurable done definitions traced back to the
  initiative's outcomes. Use when coverage of every success criterion — with no
  duplication of existing work — is the goal. Drafts only; does not create items.
inputs:
  - name: initiative
    type: object
    required: true
    description: Title and description of the initiative being decomposed.
  - name: success_criteria
    type: array
    required: true
    description: The measurable outcomes the story set must collectively produce, each with a stable id (sc-1, sc-2, …).
  - name: existing_work
    type: array
    required: false
    description: Stories/items already attached to the initiative that will remain — drafts must cover the gaps, not duplicate these.
outputs:
  format: json
  schema: >
    {story_drafts: [{temp_id, title, description, done_definitions[],
    considerations[]}], sc_coverage_plan: [{sc_id, covering_story_temp_ids[]}],
    decomposition_notes: []}. Each done definition traces to a success criterion;
    every success criterion is covered.
tools:
  required: []
  optional:
    - read-only inspection to ground stories in the actual codebase
  prohibited:
    - creating items, modifying files, or running commands
    - dispatching nested sub-agents
    - duplicating work already covered by existing_work
determinism: low-variance
model_hint: opus
source: Epic-to-story decomposer producing INVEST vertical slices with success-criteria coverage.
---

# Decompose an Initiative Into Vertical-Slice Stories

You decompose an initiative into the **new** vertical-slice user stories needed so
the collective set (existing work + your drafts) fully covers every success
criterion. You draft only — you do not create items, modify files, or dispatch
sub-agents.

## Principles

- **Vertical slices.** Each story delivers an end-to-end increment of user-visible
  value, not a horizontal layer ("all the database work"). Prefer a thin slice
  through every layer over a thick slice of one layer.
- **INVEST.** Each story should be Independent, Negotiable, Valuable, Estimable,
  Small, and Testable.
- **Traceable, measurable done definitions.** Each story's done definitions are
  observable/testable and each traces to a success criterion (e.g. `← satisfies:
  sc-2`).
- **No duplication.** Cover the gaps left by `existing_work`; do not redraft work
  it already delivers.

## Procedure

1. Read the initiative and its success criteria.
2. Map what `existing_work` already covers against the success criteria.
3. For each uncovered (or partially covered) criterion, draft the vertical-slice
   story or stories that deliver it, with measurable done definitions tracing back
   to the criterion.
4. Build an `sc_coverage_plan` proving every success criterion is covered by at
   least one story (existing or drafted). If a criterion cannot be cleanly
   covered, record it in `decomposition_notes` rather than leaving it silently
   uncovered.

## Output contract

```json
{
  "story_drafts": [
    {
      "temp_id": "draft-1",
      "title": "As a <user>, <goal> so that <benefit>",
      "description": "Context and scope.",
      "done_definitions": ["Measurable, testable DD. ← satisfies: sc-1"],
      "considerations": ["advisory notes, if any"]
    }
  ],
  "sc_coverage_plan": [{"sc_id": "sc-1", "covering_story_temp_ids": ["draft-1"]}],
  "decomposition_notes": []
}
```

On a blocking condition, return empty arrays plus an `error` field.

## Constraints

- Do exactly one thing: draft the story set. Do NOT create items or write code.
- Every success criterion must be covered; no story duplicates existing work.
- Each done definition is measurable and traces to a success criterion.
- Do NOT dispatch nested sub-agents.
