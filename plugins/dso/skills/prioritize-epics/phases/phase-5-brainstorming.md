# Phase 5: Brainstorming Follow-Up

**Goal**: Surface any newly P0 or P1 epic that lacks the `brainstorm:complete` tag, and offer to brainstorm it now.

## Step 1 — Identify candidates

After Phase 4, list every epic whose final priority is P0 or P1 and whose tags do NOT include `brainstorm:complete`:

```bash
.claude/scripts/dso ticket list --type=epic --status=open,in_progress --format=llm
```

Filter the JSONL output to lines where `"pr":0` or `"pr":1` AND `"tg"` does not include `"brainstorm:complete"`. (The `--format=llm` mode emits shortened keys: `pr` for priority, `tg` for tags. See `${CLAUDE_PLUGIN_ROOT}/docs/ticket-cli-reference.md` "Key mapping" table.)

If the resulting list is empty, emit:

```
=== Phase 5 Complete ===

All P0/P1 epics already have brainstorm:complete. Prioritization complete.

Next steps:
- Decompose epics with `/dso:preplanning <epic-id>`
- Start implementation with `/dso:sprint <epic-id>`
```

And exit the skill.

## Step 2 — Present and offer

Otherwise, display:

```
Brainstorm gap — these top-priority epics are not yet brainstormed:

  P0:
    <id>  <title>
    <id>  <title>
  P1:
    <id>  <title>
    ...

Want to brainstorm any of them now? Reply with the epic IDs you'd like to brainstorm,
"all" to brainstorm every P0 then every P1 in order, or "skip" to finish here.
```

## Step 3 — Dispatch to /dso:brainstorm

Based on the user's reply:

- **"skip"** (or any clear decline): emit the Phase 5 completion summary (below) and exit.
- **Specific IDs**: for each ID, invoke `/dso:brainstorm <id>` one at a time, waiting for each to complete before starting the next. (Reason: brainstorm is itself an interactive Socratic skill; serializing keeps the user's attention coherent.)
- **"all"**: same as above but iterate the full P0 list, then the full P1 list, in current order.

After every dispatched brainstorm, re-check the epic for the `brainstorm:complete` tag. If the user exited brainstorm without completing the canonical pipeline (no tag written), note it in the final summary as still-pending — do not retry automatically.

## Phase 5 Output

```
=== Phase 5 Complete ===

Prioritization session complete.

- Epics re-prioritized: <total>
- Epics newly brainstormed this session: <list of IDs that gained brainstorm:complete>
- P0/P1 epics still lacking brainstorm:complete: <list, or "(none)">

Next steps:
- Decompose epics with `/dso:preplanning <epic-id>`
- Start implementation with `/dso:sprint <epic-id>`
```
