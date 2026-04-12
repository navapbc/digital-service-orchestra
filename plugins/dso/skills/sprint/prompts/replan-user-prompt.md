# Replan User Prompt Templates

These canonical prompt templates are used at multiple call sites in SKILL.md when presenting REPLAN_ESCALATE stories to the user. Substitute placeholders before presenting.

## Placeholders

- `{{story_list}}` — the bulleted list of stories and explanations, e.g.:
  ```
  - Story <story-id-1>: <explanation-1>
  - Story <story-id-2>: <explanation-2>
  ```
- `{{max_replan_cycles}}` — the configured `sprint.max_replan_cycles` value
- `{{replan_cycle_count}}` — the current cascade cycle count
- `{{proceed_label}}` — context-specific label for the "proceed" option (see call site notes below)

### Call site substitutions for `{{proceed_label}}`

| Call site | `{{proceed_label}}` value |
|-----------|--------------------------|
| Phase 2 d-replan-collect (cap-exhausted) | `accept the current plan as-is and continue sprint execution` |
| Phase 2 d-replan-collect (cap-not-exhausted) | `accept the current state and continue sprint with these stories as-is` |
| Step 13a Step 2a (cap-exhausted) | `skip re-planning for these stories and continue sprint execution` |
| Step 13a Step 2a (cap-not-exhausted) | `accept the current state and continue sprint with these stories as-is` |

---

## Cap-Exhausted Prompt

Present when `replan_cycle_count >= max_replan_cycles`:

```
/dso:implementation-plan cannot satisfy success criteria for:
  {{story_list}}

The cascade replan limit (max_replan_cycles={{max_replan_cycles}}) has been reached.
Options:
  (a) Proceed — {{proceed_label}}
  (b) Abort — stop the sprint for this epic; it will remain open for manual adjustment
  (c) Manual adjustment — edit the relevant story or epic tickets manually, then resume the sprint
```

Wait for user input. Act on their choice. Do NOT enter the cascade. See `skills/sprint/docs/cascade-replan-protocol.md` for context.

---

## Cap-Not-Exhausted Prompt

Present when `replan_cycle_count < max_replan_cycles`:

```
/dso:implementation-plan cannot satisfy success criteria for:
  {{story_list}}

Current cascade cycle: {{replan_cycle_count}} of {{max_replan_cycles}}

Options:
  (a) Route to /dso:brainstorm — revise the epic, then re-run preplanning and implementation-plan (cascade replan)
  (b) Proceed — {{proceed_label}}
  (c) Abort — stop the sprint for this epic; it will remain open for manual adjustment
```

Wait for user input.
- **If user selects (b) or (c):** act accordingly — proceed or abort. Do not enter cascade.
- **If user selects (a):** Enter the cascade replan (see call site instructions for cascade steps).
