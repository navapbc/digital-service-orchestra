# ui-designer Dispatch Protocol

Inline orchestration protocol for `/dso:preplanning` Step 6. When dispatching
`dso:ui-designer` for a UI story, follow the six sections below in order.

---

## 1. Input Payload Construction

Before dispatching the agent, assemble the following fields:

| Field | Source |
|-------|--------|
| `story_id` | The current story being processed in Step 6 |
| `epic_context` | Loaded from the `PREPLANNING_CONTEXT` comment on the epic ticket (the last comment whose `body` starts with `PREPLANNING_CONTEXT:`). If no cached comment exists or it is older than 7 days, re-fetch via `.claude/scripts/dso ticket show <epic-id>` and re-parse. |
| `sibling_designs` | The `siblingDesigns` array from `/tmp/wireframe-session-<epic-id>.json`, if the session file exists. Pass an empty array `[]` if the file does not exist or this is the first story in the session. |
| `session_file_path` | The absolute path `/tmp/wireframe-session-<epic-id>.json`. Always set after the pre-check below — never null at dispatch time (the MISSING branch initializes the file first). |

**Session file pre-check**: Before constructing the payload, verify whether
`/tmp/wireframe-session-<epic-id>.json` exists:
```bash
test -f /tmp/wireframe-session-<epic-id>.json && echo "EXISTS" || echo "MISSING"
```
If `EXISTS`, read it with the Read tool and extract `siblingDesigns` and
`processedStories` for the payload.

If `MISSING`, this is the first story — initialize the session file before
dispatching (matching the canonical lifecycle in preplanning SKILL.md lines
769-783):

1. Use the Read tool to attempt to read `.claude/design-notes.md`. Note whether
   the file exists and capture its full content (or `null` if missing).
2. Write `/tmp/wireframe-session-<epic-id>.json`. Use the appropriate
   `designNotes` form based on what step 1 found:

   **If `.claude/design-notes.md` exists** (content captured in step 1):
   ```json
   {
     "version": 1,
     "epicId": "<epic-id>",
     "createdAt": "<ISO-8601 timestamp>",
     "designNotes": {
       "exists": true,
       "content": "<full content read in step 1>"
     },
     "processedStories": [],
     "siblingDesigns": []
   }
   ```

   **If `.claude/design-notes.md` is missing**:
   ```json
   {
     "version": 1,
     "epicId": "<epic-id>",
     "createdAt": "<ISO-8601 timestamp>",
     "designNotes": {
       "exists": false,
       "content": null
     },
     "processedStories": [],
     "siblingDesigns": []
   }
   ```
3. Log: `"Created wireframe session file for epic <epic-id>."`
4. Set `session_file_path` to `/tmp/wireframe-session-<epic-id>.json` and both
   `sibling_designs` and `processedStories` to `[]` for the initial dispatch.

---

## 2. Agent Dispatch

**NESTING PROHIBITION**: Dispatch `dso:ui-designer` via the **Agent tool only**.
Never invoke it via the Skill tool — doing so creates illegal two-level nesting
(preplanning orchestrator → Skill → ui-designer sub-agent) which causes
`[Tool result missing due to internal error]` failures. The Agent tool is the
correct dispatch mechanism at this level.

Dispatch `dso:ui-designer` with `subagent_type: "dso:ui-designer"` and pass:

```
story_id: <story-id>
epic_context: <PREPLANNING_CONTEXT payload object>
sibling_designs: <siblingDesigns array from session file, or []>
session_file_path: <absolute path to session file, or null>
```

The agent will:
1. Check the UI Discovery Cache (`.ui-discovery-cache/manifest.json`).
2. Classify the story (Lite or Full track).
3. Produce design artifacts in `plugins/dso/docs/designs/<uuid>/`.
4. Return a `UI_DESIGNER_PAYLOAD` JSON block.

Parse the returned output for the `UI_DESIGNER_PAYLOAD:` prefix and extract the
JSON object that follows. All subsequent routing decisions are based on the
fields of this object.

---

## 3. CACHE_MISSING Retry Loop

When the returned payload contains `"cache_status": "CACHE_MISSING"`, the UI
Discovery Cache is absent or corrupt. The orchestrator must refresh it before
re-dispatching.

**Retry procedure**:

1. Invoke `/dso:ui-discover <story-id>` at orchestrator level via the Skill tool.
   This is a Skill tool call from the preplanning orchestrator — it is NOT
   dispatched from inside `dso:ui-designer`, so it is a two-level call
   (orchestrator → ui-discover), which is acceptable.
2. After `/dso:ui-discover` completes successfully, update the session file's
   `discoveryCache` field to record the refresh:
   - Read the session file (if it exists).
   - Add or update:
     ```json
     "discoveryCache": {
       "refreshedAt": "<ISO-8601 timestamp>",
       "triggeredBy": "CACHE_MISSING on story <story-id>"
     }
     ```
   - Write the updated session file back.
3. Re-dispatch `dso:ui-designer` via the Agent tool with the same payload as
   the initial attempt (sibling_designs and session_file_path may be updated).

**Retry cap**: Maximum **2** retry attempts per story (meaning up to 3 total
`CACHE_MISSING` returns before the cap is exceeded).

- After the **1st** `CACHE_MISSING` return: run ui-discover (retry attempt 1), then re-dispatch.
- After the **2nd** `CACHE_MISSING` return: run ui-discover again (retry attempt 2 —
  in case of a transient write failure), then re-dispatch one final time.
- After the **3rd** `CACHE_MISSING` return (both retry attempts exhausted):
  - **Non-interactive mode**: Write the following comment to the epic ticket and
    skip this story:
    ```
    .claude/scripts/dso ticket comment <epic-id> "INTERACTIVITY_DEFERRED: CACHE_MISSING <story-id> — UI Discovery Cache could not be populated after 2 refresh attempts. Manual intervention required: run /dso:ui-discover <story-id> and re-trigger preplanning Step 6."
    ```
    Continue processing remaining UI stories.
  - **Interactive mode**: Escalate to the user with the following message:
    > "The UI Discovery Cache could not be populated for story `<story-id>` after
    > 2 refresh attempts. Please run `/dso:ui-discover <story-id>` manually and
    > confirm when complete, then we will re-dispatch the designer."
    Pause and wait for user confirmation before re-dispatching.

---

## 4. Review Loop (Orchestrator-Managed)

After receiving a successful payload (non-null `design_artifacts`, no error),
run an orchestrator-managed design review loop before proceeding to Section 5.

**State variables** (initialize before the loop):
```
review_cycle_count = 0
max_review_cycles = 3
review_feedback = null
```

**Loop**:

1. Invoke `/dso:review-protocol` via the Skill tool, passing the design
   artifacts produced by `dso:ui-designer` as the review subject:
   - `artifact`: the full content of the design manifest at `design_artifacts.manifest`
     (read it with the Read tool and pass the content inline, not just the path)
   - `subject`: the manifest path from `design_artifacts.manifest` in the payload
   - `caller`: `ui-designer`
   - `perspectives`: `["Product Management", "Design Systems", "Accessibility", "Frontend Engineering"]`
   - If `review_feedback` is non-null (cycle 2+), include it as context for
     the reviewer so they can evaluate whether prior findings were addressed.

2. Parse the `/dso:review-protocol` output for the result signal:
   - **`REVIEW_PASS`** (all perspectives approved, no blocking findings):
     - Log: `"Design review passed for story <story-id> (cycle <review_cycle_count + 1>)."`
     - Break out of the loop and proceed to Section 5.
   - **`REVIEW_FAIL`** (one or more blocking findings remain):
     - Increment `review_cycle_count` by 1.
     - Capture the consolidated feedback from the review output as
       `review_feedback` (the list of blocking findings and recommendations).
     - **If `review_cycle_count < max_review_cycles`**:
       - Log: `"Design review cycle <review_cycle_count> failed for story <story-id>. Re-dispatching dso:ui-designer with feedback."`
       - Re-dispatch `dso:ui-designer` via the Agent tool (Section 2),
         appending `review_feedback` to the payload as a `revision_notes` field
         so the designer can address the findings.
       - After receiving the updated payload, return to step 1 of this loop.
     - **If `review_cycle_count >= max_review_cycles`** (max cycles exhausted):
       - **Interactive mode**: Use `AskUserQuestion` to escalate:
         > "Design review for story `<story-id>` has not passed after
         > `<max_review_cycles>` cycles. Blocking findings:
         > `<review_feedback>`
         >
         > Options:
         > 1. Accept the current design and proceed (tag design:approved)
         > 2. Abandon design artifacts for this story (tag design:pending_review)
         > 3. Re-dispatch the designer with additional manual guidance"
         Apply the user's chosen action and continue to Section 5.
       - **Non-interactive mode**: Write a comment to the epic ticket and tag
         the story `design:pending_review`, then continue to Section 5:
         ```bash
         .claude/scripts/dso ticket comment <epic-id> "INTERACTIVITY_DEFERRED: design review for story <story-id> did not pass after <max_review_cycles> cycles. Blocking findings: <review_feedback>. Manual review required: run /dso:review-protocol on <design_artifacts.manifest> and resolve findings before sprint."
         EXISTING_TAGS=$(.claude/scripts/dso ticket show <story-id> | python3 -c "import sys,json; t=json.load(sys.stdin).get('tags',[]); print(','.join(t))")
         NEW_TAGS="${EXISTING_TAGS:+${EXISTING_TAGS},}design:pending_review"
         .claude/scripts/dso ticket edit <story-id> "--tags=${NEW_TAGS}"
         ```

**REVIEW_PASS path** — tag the story `design:approved` after the loop exits:
```bash
EXISTING_TAGS=$(.claude/scripts/dso ticket show <story-id> | python3 -c "import sys,json; t=json.load(sys.stdin).get('tags',[]); print(','.join(t))")
NEW_TAGS="${EXISTING_TAGS:+${EXISTING_TAGS},}design:approved"
.claude/scripts/dso ticket edit <story-id> "--tags=${NEW_TAGS}"
```
Log: `"Design artifacts approved for story <story-id> after <review_cycle_count + 1> review cycle(s)."`

**Important**: The `REVIEW_DECISION` signal referenced in earlier design-wireframe
documentation does NOT apply here. The ui-designer agent does not emit
`REVIEW_DECISION`. Any mention of `REVIEW_DECISION` in legacy prompts refers to
the old Phase 5 that was removed from the agent.

---

## 5. Scope-Split Handling

### splitRole Guard (precedence check — evaluate FIRST)

Before processing any `scope_split_proposals` from the agent payload, check
whether preplanning has **already split this story**. Preplanning's
Foundation/Enhancement split is **authoritative**; agent scope-split proposals
are only evaluated when preplanning has NOT already split the story.

**How to detect a preplanning split**: The story's description or metadata
contains a `splitRole` marker — specifically `splitRole: Foundation` or
`splitRole: Enhancement` — added by preplanning Phase 3 when it performed its
own story split.

```
Check story description/metadata for: splitRole: Foundation  OR  splitRole: Enhancement
```

**If `splitRole` is present** (preplanning already split this story):
- Skip the agent `scope_split_proposals` entirely.
- Log: `"splitRole guard: preplanning already split story <story-id> (role: <splitRole value>). Agent scope-split proposals skipped — preplanning split is authoritative."`
- Proceed directly to Section 6 (Session File Updates).

**If `splitRole` is absent** (preplanning did NOT split this story):
- Continue below and process the agent's `scope_split_proposals` normally.

---

When the returned payload contains a non-null `scope_split_proposals` array, the
agent's Pragmatic Scope Splitter (Phase 3 Step 10) determined the story should be
split into Foundation and Enhancement stories.

**Interactive mode**:

1. Present each proposal to the user:
   > "The designer proposes splitting story `<story-id>` into:
   > - **Foundation**: `<proposal[0].title>` — `<proposal[0].description>`
   >   Rationale: `<proposal[0].rationale>`
   > - **Enhancement**: `<proposal[1].title>` — `<proposal[1].description>`
   >   Rationale: `<proposal[1].rationale>`
   >
   > Approve this split?"

2. For each **approved** proposal, create the child story:
   ```
   .claude/scripts/dso ticket create story "<proposal.title>" -d "<proposal.description>"
   ```
3. Link each child story to the parent epic:
   ```
   .claude/scripts/dso ticket link <child-story-id> <epic-id> child_of
   ```
4. Record the rationale from the proposal in a comment on the child story:
   ```
   .claude/scripts/dso ticket comment <child-story-id> "Scope split rationale: <proposal.rationale>"
   ```
5. Log: `"Created scope-split stories: <child-story-ids>. Linked to epic <epic-id>."`

**Non-interactive mode** (INTERACTIVITY_DEFERRED):

Write a comment to the epic ticket describing the proposed split:
```
.claude/scripts/dso ticket comment <epic-id> "INTERACTIVITY_DEFERRED: scope_split_proposals for story <story-id> — Foundation: '<proposal[0].title>'; Enhancement: '<proposal[1].title>'. User approval required before creating child stories."
```
Continue preplanning flow without creating the split stories.

**After scope splits are handled** (whether created or deferred), continue the
preplanning flow normally. Scope splits do not block subsequent story processing
or session file updates.

---

## 6. Session File Updates

After receiving a successful payload (non-null `design_artifacts`, `error` is
null), update the session file at `/tmp/wireframe-session-<epic-id>.json`.

The session file was created in Section 1 (if it did not previously exist), so
it always exists by this point. Read the current session file, append entries,
then write it back.

**Append to `processedStories`**:
```json
{
  "storyId": "<story-id>",
  "designManifestPath": "<design_artifacts.manifest from payload>",
  "completedAt": "<ISO-8601 timestamp>"
}
```

**Append to `siblingDesigns`**: Add the manifest path as a string (not an object):
```json
"<design_artifacts.manifest from payload>"
```

Write the updated session file using the Write tool.

**Purpose**: The `siblingDesigns` array is passed to subsequent `dso:ui-designer`
dispatches so each story's designer can see existing sibling designs and maintain
cross-story coherence (shared components, consistent layout patterns). The
`processedStories` array prevents re-processing and enables resume after
interruption.

**Log**: `"Session file updated: story <story-id> added to processedStories and siblingDesigns. Session now has <N> processed stories."`
