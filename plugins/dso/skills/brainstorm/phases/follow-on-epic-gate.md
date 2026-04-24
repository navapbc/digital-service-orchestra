# Phase 3 Step 0 — Follow-on and Derivative Epic Gate

<HARD-GATE>
Do NOT call `ticket create` for any follow-on or derivative epic until the user has explicitly approved that epic's title, description, and success criteria in a separate approval step. Do NOT treat directional approval of the primary epic (Phase 2 Step 4, option a) as approval for any follow-on epic.
</HARD-GATE>

## When This Gate Applies

A follow-on or derivative epic exists whenever:

- The scope reviewer recommended splitting the primary epic and identified a second epic (Epic B).
- The user made a directional statement requesting a future epic (e.g., "we should create a follow-up epic for X").
- You identified a related epic during Phase 1 or Phase 2 that was out of scope for the primary epic.

## Procedure (execute per follow-on, one at a time, BEFORE Step 1)

### State variables (initialize at the start of each follow-on)

- `request_origin`: set to `"scope-split"` if the scope reviewer recommended splitting the primary epic (Part A / Part B pattern); set to `"user"` otherwise (user directional statement or agent-identified related epic).
- `follow_on_depth`: **Always reset to `0` before processing each follow-on epic in this session.** Exception: if this brainstorm session was itself invoked on a follow-on epic (i.e., `/dso:brainstorm` was called from within a follow-on epic context), set `follow_on_depth = parent_depth + 1` instead. Within a single session, every follow-on is a direct follow-on at depth 0 — do NOT carry over the depth value from the previous follow-on you just processed. Default: `follow_on_depth = 0`.

### Depth cap — stub path (`follow_on_depth >= 1`)

If `follow_on_depth >= 1`, do NOT run the scrutiny pipeline. Present the follow-on as a stub:

```
Follow-on epic stub: "[Title]"
Context: [1-2 sentence description]
Proposed success criteria:
- [criterion 1]
- [criterion 2]
Note: This follow-on epic needs `/dso:brainstorm` before implementation (depth-capped stub — scrutiny skipped).
Shall I create this as a ticket stub? (yes / no / let's refine it)
```

Wait for the user's response before calling `ticket create`. If approved, create the epic ticket without running scrutiny. If the user says "no" or requests refinement, update the spec or skip creation accordingly.

### Full scrutiny path (`follow_on_depth == 0`)

1. **Determine `request_origin` and pre-strip Part A artifacts if needed**: If `request_origin` is `"scope-split"`, pre-strip Part A artifact references from the seeding material before drafting the follow-on spec. This prevents the primary epic's (Part A) content from bleeding into the follow-on scope. Exclude or skip Part A content when seeding the follow-on spec — only use Part B and scope-reviewer recommendations.
2. **Draft the follow-on epic spec**: title, 1–2 sentence context, and 2–4 proposed success criteria. Seed from the scope reviewer's recommendation or the user's directional statement — do not invent scope.
3. **Invoke the epic scrutiny pipeline** at `skills/shared/workflows/epic-scrutiny-pipeline.md` on the drafted follow-on epic spec, passing:
   - `{caller_name}` = `brainstorm`
   - `{caller_prompts_dir}` = `skills/brainstorm/prompts`
4. **Present with scrutiny results and wait for explicit approval**:
   ```
   Follow-on epic proposed: "[Title]"
   Context: [1-2 sentence description]
   Proposed success criteria:
   - [criterion 1]
   - [criterion 2]
   Scrutiny results: [summary of gap analysis, scenario analysis findings]
   Shall I create this as a separate epic? (yes / no / let's refine it)
   ```
   Wait for the user's response before calling `ticket create`. If the user says "no" or requests refinement, update the spec or skip creation accordingly.

### Planning-intelligence log entry

After processing each follow-on epic, record:

- `follow_on_scrutiny_depth` = `<follow_on_depth value>` (named state variable for orchestrator/sub-agent inspection)
