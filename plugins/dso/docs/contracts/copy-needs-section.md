# Contract: Copy Needs Section

- Signal Name: Copy Needs Section
- Status: accepted
- Scope: brainstorm, preplanning, implementation-plan skills → UX copy tracking phase
- Date: 2026-05-24

## Purpose

This document defines the schema for the `## Copy Needs` section used by planning and review skills to enumerate user-visible strings that require UX copywriting review or approval. Each entry in the section describes one piece of copy — a label, heading, error message, or instructional text — along with where it appears, what type it is, and what validation rule applies.

Skills that emit or consume this section must conform to this schema to ensure consistent copy tracking across the planning pipeline.

---

## Copy Needs

```
schema_version: 1
```

Each `## Copy Needs` section must begin with the literal line `schema_version: 1` (bare key form, exact match, no leading `#` comment, no surrounding whitespace) as the first non-blank line after the heading, before any copy items are listed. The validator (`${CLAUDE_PLUGIN_ROOT}/scripts/check-copy-needs-schema.sh`) enforces this exact form.

---

## Schema Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `stable_id` | string | yes | A stable, kebab-case identifier for this copy item that does not change across revisions (e.g., `"eligibility-header"`, `"upload-error-too-large"`). Must be unique within the document. Changing a `stable_id` is a breaking change and requires a new entry. |
| `type` | enum | yes | The category of copy. See accepted values below. |
| `location` | string | yes | Human-readable description of where this copy appears in the UI (e.g., `"H1 heading above the eligibility question list"`, `"inline error below the file upload input"`). Should be precise enough for a designer or copywriter to locate it without consulting the codebase. |
| `page` | enum | yes | The page or screen where this copy lives. Must be a value from the controlled vocabulary below. |
| `validation_rule` | string | yes | The rule that determines whether this copy is acceptable (e.g., `"Must be ≤ 60 characters"`, `"Must not use legal jargon"`, `"Must match the approved tone-of-voice guide"`). Skills reject entries with a blank or missing `validation_rule`. |

---

## Field: `type` — Accepted Values

| Value | Meaning |
|---|---|
| `heading` | A section or page-level heading (`h1`–`h6`). |
| `label` | A form field label, input hint, or UI control label. |
| `button` | The text of an interactive button or link rendered as a button. |
| `error` | An error message shown to the user when an action fails or input is invalid. |
| `helper_text` | Instructional or contextual text that supplements a form field or UI element. |
| `body` | General paragraph or prose copy that is not a heading, label, or error. |
| `status` | A status indicator string (e.g., `"Submitted"`, `"In Review"`, `"Approved"`). |
| `confirmation` | Copy shown on a confirmation screen or in a confirmation modal. |

---

## Field: `page` — Page Vocabulary

### Controlled Page Identifiers

The `page` field must be one of the following identifiers:

| Identifier | Description |
|---|---|
| `application_form` | The main multi-step or single-page form where users submit an application. |
| `eligibility_screen` | The screen where users answer eligibility questions before beginning the application. |
| `document_upload` | The screen or section where users upload supporting documents or files. |
| `status_page` | The page showing the current status of a submitted application or request. |
| `confirmation_page` | The page shown after a successful submission or action, confirming the outcome. |
| `login` | The login / sign-in screen. |
| `signup` | The account creation / sign-up screen. |
| `error_page` | A full-page error screen (e.g., 404, 500, session-expired). |
| `dashboard` | A personalized landing page listing applications, tasks, or notifications. |
| `review_screen` | A read-only review screen where users check their answers before submitting. |

### Vocabulary Extension Procedure

To add a new page identifier:

1. Open a pull request that modifies this file and adds the new identifier to the table above.
2. The PR must include a description field explaining the new page's role and confirming it is not a specialization of an existing identifier.
3. The PR requires at least one reviewer approval from a team member with UX or product authority before merge.
4. Once merged, the new identifier is immediately valid for use in `## Copy Needs` sections. No schema version bump is required for additive identifier additions.

Using an identifier not listed above is a schema violation and causes the skill to reject the entry with `UNKNOWN_PAGE_IDENTIFIER`.

---

## Passing Example

The following is a conforming `## Copy Needs` section:

```markdown
## Copy Needs

schema_version: 1

- stable_id: eligibility-header
  type: heading
  location: H1 heading at the top of the eligibility questions screen
  page: eligibility_screen
  validation_rule: Must be ≤ 60 characters and must not use the word "qualify"

- stable_id: upload-error-too-large
  type: error
  location: Inline error message displayed below the file upload input when the selected file exceeds the size limit
  page: document_upload
  validation_rule: Must be ≤ 120 characters; must state the size limit explicitly; must offer a corrective action

- stable_id: submit-button
  type: button
  location: Primary CTA button at the bottom of the review screen
  page: review_screen
  validation_rule: Must be ≤ 30 characters; must use active voice; must not use the word "submit" — prefer "Send application"
```

This example passes because:
- All five required fields are present on every item.
- All `page` values (`eligibility_screen`, `document_upload`, `review_screen`) are in the controlled vocabulary.
- All `type` values (`heading`, `error`, `button`) are in the controlled `type` enum.
- All `validation_rule` values are non-empty strings.
- All `stable_id` values are unique within the document.

---

## Failing Examples

### Failing Example 1: Missing required field `validation_rule`

```markdown
## Copy Needs

schema_version: 1

- stable_id: confirmation-message
  type: confirmation
  location: Body text on the confirmation page after successful submission
  page: confirmation_page
```

**Rejection reason**: `validation_rule` is required but absent. Skills must reject this entry with `MISSING_REQUIRED_FIELD: validation_rule` and refuse to process the section until the field is added.

---

### Failing Example 2: Unknown page identifier

```markdown
## Copy Needs

schema_version: 1

- stable_id: payment-label
  type: label
  location: Label for the payment amount input field
  page: payment_screen
  validation_rule: Must be ≤ 40 characters
```

**Rejection reason**: `page: payment_screen` is not in the controlled page vocabulary. Skills must reject this entry with `UNKNOWN_PAGE_IDENTIFIER: payment_screen`. The author must either use an existing identifier or follow the Vocabulary Extension Procedure to add `payment_screen` before submitting.

---

## Notes

1. **`schema_version` is required**: A `## Copy Needs` section without `schema_version: 1` immediately after the heading is malformed. Skills must reject malformed sections and surface `MISSING_SCHEMA_VERSION`.
2. **`stable_id` uniqueness**: Duplicate `stable_id` values within a single document are a schema violation. Skills must surface `DUPLICATE_STABLE_ID: <id>` and reject the section.
3. **Empty `validation_rule`**: A present-but-empty `validation_rule` (whitespace only) is treated as absent. Skills must reject it with `MISSING_REQUIRED_FIELD: validation_rule`.
4. **Copy changes vs. stable_id changes**: When the copy text changes, the entry is updated in place. When the *purpose* of the copy changes (e.g., a label becomes a heading), a new `stable_id` must be assigned and the old entry deprecated with a `deprecated: true` note.
5. **Multi-page copy**: If the same copy string appears on more than one page, create a separate entry per page with distinct `stable_id` values. Do not list multiple `page` values on a single entry.

---

## Consumers

The following skills emit or consume the Copy Needs section:

| Skill | Role | Notes |
|---|---|---|
| `skills/preplanning/SKILL.md` | Emitter | Identifies copy items during story decomposition; populates initial section with per-screen copy requirements |
| `skills/implementation-plan/SKILL.md` | Consumer | Reads section to surface copy items as acceptance criteria on relevant tasks |
| `skills/sprint/SKILL.md` | Consumer | Validates copy items are addressed during story closure; emits `COPY_NEEDS_UNRESOLVED` if any item lacks approval |

All implementors must read this contract before modifying any skill that emits or parses `## Copy Needs` sections. Changes to field names, enum values, or required/optional status require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (field renames, enum removals, required→optional promotions) increment the version. Additive changes (new optional fields, new page identifiers) are backward-compatible and do not require a version bump.

### Change Log

- **2026-05-24**: Initial version — defines Copy Needs section schema. Establishes `stable_id`, `type`, `location`, `page`, and `validation_rule` fields; controlled `page` vocabulary with 10 identifiers; `type` enum with 8 values; vocabulary extension procedure; and pass/fail examples.
