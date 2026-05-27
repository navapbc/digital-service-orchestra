# Contract: design-md-additions-payload

- Status: accepted
- Scope: dso:ui-designer agent → preplanning skill (story c1e3-d570-0ecd-4f63)
- Date: 2026-05-27

## Purpose

This document defines the `design_md_additions` nullable field that may be included in the `UI_DESIGNER_PAYLOAD` (see `${CLAUDE_PLUGIN_ROOT}/docs/contracts/ui-designer-payload.md`) returned by the `dso:ui-designer` agent. When present and non-null, this field carries structured content blocks intended to be appended to the story's `CLAUDE.md` design notes section by the preplanning consumer.

This contract extends the parent `UI_DESIGNER_PAYLOAD` schema — it does not replace it. All top-level fields defined in `ui-designer-payload.md` remain required; `design_md_additions` is an additive nullable field.

---

## Parent Schema

This contract extends: `UI_DESIGNER_PAYLOAD` (see `${CLAUDE_PLUGIN_ROOT}/docs/contracts/ui-designer-payload.md`).

The `design_md_additions` field is added as a top-level nullable field alongside the existing `design_artifacts`, `cache_status`, `scope_split_proposals`, `track`, and `error` fields.

---

## Field Schema: design_md_additions

### Top-level addition

| Field | Type | Required | Description |
|---|---|---|---|
| `design_md_additions` | array \| null | yes | List of structured content blocks to append to the story's design notes in `CLAUDE.md`. Null when no additions are warranted (e.g., the agent produced no additional guidance beyond the artifact files). |

### design_md_additions array items

Each item in the `design_md_additions` array is an object with the following fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `section_heading` | string | yes | The markdown heading text for this content block (without the `##` prefix — the consumer is responsible for applying heading syntax). Must not be empty. |
| `content_lines` | array of string | yes | Ordered list of markdown lines that form the body of this section. Each element is a single line of markdown content. Must contain at least one element. |
| `rationale` | string | no | Optional human-readable explanation of why this section was included. Used for debugging and audit purposes; not rendered to `CLAUDE.md`. |

---

## Extended Payload Schema

The full `UI_DESIGNER_PAYLOAD` JSON object with `design_md_additions` present:

| Field | Type | Required | Description |
|---|---|---|---|
| `design_artifacts` | object \| null | yes | See `ui-designer-payload.md` |
| `cache_status` | string (enum) | yes | See `ui-designer-payload.md` |
| `scope_split_proposals` | array \| null | yes | See `ui-designer-payload.md` |
| `track` | string (enum) | yes | See `ui-designer-payload.md` |
| `error` | string \| null | yes | See `ui-designer-payload.md` |
| `design_md_additions` | array \| null | yes | Structured content blocks for CLAUDE.md design notes. Null when no additions are needed. |

---

## Consumer Behavior

When `design_md_additions` is non-null and non-empty, the preplanning consumer MUST:

1. Iterate over each item in the `design_md_additions` array in order.
2. For each item, append a markdown section to the story's design notes using `section_heading` as the heading text and `content_lines` as the body.
3. Not render the `rationale` field to any user-facing file.

When `design_md_additions` is null or an empty array, the consumer MUST skip the design notes append step without error.

If a `design_md_additions` item is missing `section_heading` or `content_lines`, or if `content_lines` is an empty array, the consumer MUST treat that item as malformed and surface a warning before skipping it. The remaining items must still be processed.

---

## Example Payloads

### Example A: Payload with design_md_additions present

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
  "error": null,
  "design_md_additions": [
    {
      "section_heading": "Accessibility Notes",
      "content_lines": [
        "- All interactive controls must meet WCAG 2.1 AA contrast ratios.",
        "- Focus ring must be visible on all form inputs.",
        "- Screen reader labels required on all icon-only buttons."
      ],
      "rationale": "Agent detected icon-only action buttons in the wireframe that require explicit aria-label annotations."
    },
    {
      "section_heading": "Token Constraints",
      "content_lines": [
        "- Use `color.action.primary` for the submit CTA.",
        "- Avoid overriding `spacing.lg` — layout depends on this token for responsive breakpoints."
      ]
    }
  ]
}
```
```

### Example B: Payload with design_md_additions null (no additions)

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
  "scope_split_proposals": null,
  "track": "lite",
  "error": null,
  "design_md_additions": null
}
```
```

---

## Failure Contract

If the `design_md_additions` field is:

- present but not an array (e.g., a string or object),
- or contains an item missing the required `section_heading` or `content_lines` fields,

the consumer MUST surface a warning to the user for each malformed item and skip that item. The overall payload is not treated as fatal. Consumers MUST NOT silently ignore malformed items without a warning.

---

## Versioning

This contract extends `UI_DESIGNER_PAYLOAD` and is versioned alongside it. Breaking changes to `design_md_additions` (field removal, type changes) require updating this document, the parent contract, and all conforming emitters and consumers atomically in the same commit. Additive changes (new optional fields) are backward-compatible.

### Change Log

- **2026-05-27**: Initial version — defines `design_md_additions` nullable field schema as an additive extension to `UI_DESIGNER_PAYLOAD`. Establishes `section_heading` (string, required), `content_lines` (array of string, required), and `rationale` (string, optional) fields with consumer behavior rules and failure contract.
