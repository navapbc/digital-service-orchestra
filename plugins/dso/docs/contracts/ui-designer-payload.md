# Contract: ui-designer-payload

- Status: accepted
- Scope: dso:ui-designer agent → preplanning skill (story 2932-51a6)
- Date: 2026-04-08

## Purpose

This document defines the return payload emitted by the `dso:ui-designer` agent when it completes a design generation run. The `/dso:preplanning` skill (and any other consumer that dispatches the ui-designer agent) uses this payload to determine whether design artifacts were successfully produced, inspect the cache state, detect triggered scope splits, and handle agent errors.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the emitter and consumer stay in sync.

---

## Emitter

`plugins/dso/agents/ui-designer.md` — Named agent dispatched by `/dso:preplanning` to generate design artifacts for a user story. # shim-exempt: internal implementation path reference
<!-- REVIEW-DEFENSE: plugins/dso/agents/ui-designer.md does not exist at the time this contract is created. This contract is the first artifact in a two-task chain: task ffca-cee2 creates this contract, and task 97c1-15bc (which depends on ffca-cee2) creates the agent file. Forward-looking emitter references are intentional in contract-first development — the contract documents the emitter path before the emitter exists, giving the implementer the definitive path. This is not a broken reference; it is a documented future obligation. -->

The emitter receives a story ID and the current UI discovery cache path. It evaluates the cache state, optionally runs Playwright-based discovery, generates design artifacts to a `designs/<uuid>/` directory, and returns the structured payload defined here. On any unrecoverable error the emitter sets `error` to a human-readable message and returns the partial payload with nulled artifact fields.

---

## Consumer

`plugins/dso/skills/preplanning/SKILL.md` — Preplanning skill that dispatches `dso:ui-designer` and reads the returned payload to decide whether to attach design artifacts to the story or surface a scope split for user review. # shim-exempt: internal implementation path reference

The consumer MUST check `cache_status` before acting on `design_artifacts`. When `cache_status` is `CACHE_MISSING`, the consumer must follow the actionable instructions embedded in the payload and re-invoke the design flow after cache population. When `error` is non-null, the consumer must surface the error to the user and skip artifact attachment.

---

## Payload Schema

The agent returns a single JSON object with the following top-level fields.

### Top-level fields

| Field | Type | Required | Description |
|---|---|---|---|
| `design_artifacts` | object \| null | yes | Container for all generated artifact file paths. Null when `cache_status` is `CACHE_MISSING` or `error` is non-null. |
| `cache_status` | string (enum) | yes | UI discovery cache state at the time of invocation. See Cache Status Values. |
| `scope_split_proposals` | array \| null | yes | List of story split proposals when the pragmatic scope splitter triggered. Null when no scope split was triggered. |
| `track` | string (enum) | yes | Design track used for this run: `"lite"` or `"full"`. |
| `error` | string \| null | yes | Null on success. Human-readable error message on failure (e.g., story not found, Playwright unavailable). When non-null, `design_artifacts` MUST be null. |

### design_artifacts object

Present only when `cache_status` is not `CACHE_MISSING` and `error` is null.

| Field | Type | Required | Description |
|---|---|---|---|
| `design_uuid` | string | yes | UUID string identifying the design session. Used as the directory name under `designs/`. |
| `spatial_layout` | string | yes | Relative path to the spatial layout JSON file (e.g., `designs/<uuid>/spatial-layout.json`). |
| `wireframe_svg` | string | yes | Relative path to the SVG wireframe file (e.g., `designs/<uuid>/wireframe.svg`). |
| `token_overlay` | string | yes | Relative path to the design token overlay markdown file (e.g., `designs/<uuid>/tokens.md`). |
| `manifest` | string | yes | Relative path to the design manifest markdown file (e.g., `designs/<uuid>/manifest.md`). |
| `brief` | string \| null | yes | Relative path to the Design Brief markdown file — present for Lite track only (e.g., `designs/<uuid>/brief.md`). Null for Full track. |

### Cache Status Values

| Value | Meaning |
|---|---|
| `CACHE_MISSING` | The UI discovery cache is absent or has been confirmed stale. The agent returns this status with actionable instructions in the `error` field describing how to populate the cache before retrying. `design_artifacts` is null when this status is returned. |
| `CACHE_VALID` | The UI discovery cache is present and fresh. The agent proceeds with design generation using the cached component inventory. |
| `CACHE_STALE` | The UI discovery cache exists but is stale. The agent proceeds with design generation and includes a staleness warning note in the manifest artifact. |

### scope_split_proposals array items

Each item in the `scope_split_proposals` array is an object with the following fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `title` | string | yes | Short title for the proposed child story (≤ 255 characters to satisfy Jira sync limit). |
| `description` | string | yes | User story description for the proposed split (written as "As a [user], [goal]"). |
| `rationale` | string | yes | Human-readable explanation of why this scope split was proposed. Must reference the specific complexity or scope concern that triggered the split. Must not be empty. |

---

## Output Format

The emitter outputs a single JSON object wrapped in a fenced code block:

```
UI_DESIGNER_PAYLOAD:
```json
{ ... }
```
```

The consumer MUST scan for the `UI_DESIGNER_PAYLOAD:` prefix line, then read the JSON block that follows on the next line.

---

## Example Payloads

### Example A: Successful Full-track run with valid cache

```
UI_DESIGNER_PAYLOAD:
```json
{
  "design_artifacts": {
    "design_uuid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "spatial_layout": "designs/a1b2c3d4-e5f6-7890-abcd-ef1234567890/spatial-layout.json",
    "wireframe_svg": "designs/a1b2c3d4-e5f6-7890-abcd-ef1234567890/wireframe.svg",
    "token_overlay": "designs/a1b2c3d4-e5f6-7890-abcd-ef1234567890/tokens.md",
    "manifest": "designs/a1b2c3d4-e5f6-7890-abcd-ef1234567890/manifest.md",
    "brief": null
  },
  "cache_status": "CACHE_VALID",
  "scope_split_proposals": null,
  "track": "full",
  "error": null
}
```
```

### Example B: Successful Lite-track run with stale cache and scope split

```
UI_DESIGNER_PAYLOAD:
```json
{
  "design_artifacts": {
    "design_uuid": "f9e8d7c6-b5a4-3210-fedc-ba9876543210",
    "spatial_layout": "designs/f9e8d7c6-b5a4-3210-fedc-ba9876543210/spatial-layout.json",
    "wireframe_svg": "designs/f9e8d7c6-b5a4-3210-fedc-ba9876543210/wireframe.svg",
    "token_overlay": "designs/f9e8d7c6-b5a4-3210-fedc-ba9876543210/tokens.md",
    "manifest": "designs/f9e8d7c6-b5a4-3210-fedc-ba9876543210/manifest.md",
    "brief": "designs/f9e8d7c6-b5a4-3210-fedc-ba9876543210/brief.md"
  },
  "cache_status": "CACHE_STALE",
  "scope_split_proposals": [
    {
      "title": "Display user notification preferences panel",
      "description": "As a user, I want to view my notification preferences so that I can see what alerts are currently enabled.",
      "rationale": "The original story combines read and write flows for notification preferences. The read-only view panel is independently shippable and estimated at 3 story points; the write flow adds 5 more. Splitting improves delivery granularity."
    },
    {
      "title": "Edit user notification preferences",
      "description": "As a user, I want to update my notification preferences so that I can control which alerts I receive.",
      "rationale": "Write flow depends on the read panel (scope split proposal 0) being complete. Decoupling allows the read panel to ship first while the form validation and persistence layer are built in parallel."
    }
  ],
  "track": "lite",
  "error": null
}
```
```

### Example C: Cache missing — design_artifacts null

```
UI_DESIGNER_PAYLOAD:
```json
{
  "design_artifacts": null,
  "cache_status": "CACHE_MISSING",
  "scope_split_proposals": null,
  "track": "lite",
  "error": "UI discovery cache is absent. Run /dso:ui-discover to populate the cache before invoking the ui-designer agent."
}
```
```

### Example D: Agent error — story not found

```
UI_DESIGNER_PAYLOAD:
```json
{
  "design_artifacts": null,
  "cache_status": "CACHE_VALID",
  "scope_split_proposals": null,
  "track": "lite",
  "error": "Story 2932-51a6 not found in the ticket system. Verify the story ID and try again."
}
```
```

---

## Failure Contract

If the `dso:ui-designer` agent output is:

- absent (agent timed out, returned non-zero exit, or produced no output),
- malformed (missing `UI_DESIGNER_PAYLOAD:` prefix, invalid JSON, missing required top-level fields),
- or contains an unrecognized `cache_status` value,

then the consumer MUST treat the run as failed, surface the raw output to the user for inspection, and skip all design artifact attachment and scope split processing. Autonomous retry is prohibited without user confirmation.

When `cache_status` is `CACHE_MISSING`, the consumer MUST NOT treat this as a fatal error. It MUST display the actionable instructions from the `error` field to the user and offer to invoke `/dso:ui-discover` before retrying the design step.

---

## Consumers

The following components emit or consume this payload:

| Component | Role | Notes |
|---|---|---|
| `plugins/dso/agents/ui-designer.md` | Emitter | Named agent dispatched during preplanning design generation (story 2932-51a6) # shim-exempt: internal implementation path reference |
| `plugins/dso/skills/preplanning/SKILL.md` | Consumer | Reads payload to attach design artifacts and surface scope splits (story 2932-51a6) # shim-exempt: internal implementation path reference |

All implementors must read this contract before writing the emitter agent or consumer logic. Changes to the payload schema require updating all conforming emitters and consumers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (field removal, type changes, enum value changes) require updating both all emitters and consumers and this document atomically in the same commit. Additive changes that do not remove or rename existing required fields are backward-compatible.

### Change Log

- **2026-04-08**: Initial version — defines ui-designer-payload return schema for dso:ui-designer agent → preplanning skill. Establishes design_artifacts object, cache_status enum (CACHE_MISSING/CACHE_VALID/CACHE_STALE), scope_split_proposals array, track enum, error field, and failure contract.
