# Contract: FEATURE_FLAGS Marker

- Signal Name: FEATURE_FLAGS
- Status: accepted
- Scope: implementation-plan Step 1 (emitter) → task-decomposer story / sprint two-pass-ordering story (consumers)
- Date: 2026-06-02

## Purpose

This document is the **normative single source of truth** for the `FEATURE_FLAGS:` ticket-comment marker contract. It defines the marker JSON shape, the emitting site (the two-hop `resolve-feature-flag-approval.sh` helper), the verdict values, the append-only/last-wins idiom, the safe-default protocol, and the consumer dispatch protocol.

All emitters and consumers MUST conform to this document rather than redefining the shape independently.

---

## Marker JSON Shape

The marker is written as a **single-line JSON object** embedded in a ticket comment using the prefix `FEATURE_FLAGS:`.

```
FEATURE_FLAGS: {"feature-flags":"approved","reason":"tag-found-on-parent-abc123","source":"parent"}
```

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `feature-flags` | `string` | yes | Verdict. One of: `approved`, `prohibited`. |
| `reason` | `string` | yes | Non-empty human-readable explanation. Never a bare empty string. |
| `source` | `string` | yes | Where the approval tag was found (or not). One of: `story`, `parent`, `none`. |

### `feature-flags` Values

| Value | Meaning |
|---|---|
| `approved` | The `rollout:feature-flags-approved` tag is present on the story or its parent epic. The task-decomposer emits a flag-cutover task PAIRED WITH a flag-cleanup task. |
| `prohibited` | The tag is absent on both story and parent (or lookup failed). The task-decomposer emits NO flag pair and records `feature_flags:prohibited` with the marker `reason` in `decomposition_notes`. |

### `reason` Field Contract

The `reason` field MUST be non-empty for every emitted marker — including the `prohibited` path. It explains why the verdict was reached (e.g., `"tag-found-on-story"`, `"tag-found-on-parent-<epic-id>"`, `"tag-absent-on-story-and-parent-<epic-id>"`, `"no-parent-on-story-<story-id>"`, `"story-lookup-failed-for-<story-id>"`). A bare empty `reason` is a contract violation.

### Key Spelling Note

The key `feature-flags` is **hyphenated** (not underscored). Both the emitter and all consumers MUST use the exact spelling `feature-flags` verbatim. A common mistake is `feature_flags` (underscore), which causes silent mismatches in consumers that key on the hyphenated form.

---

## Emitter

**`/dso:implementation-plan` — Step 1 (Feature-Flag Approval Detection step)**

Step 1 invokes `resolve-feature-flag-approval.sh <story-id>` and appends a ticket comment to the story ticket in the form:

```
FEATURE_FLAGS: {<json-object>}
```

This mirrors the `MIGRATION_CLASS:` idiom: a prefix keyword, a colon, a space, and a single-line JSON payload.

---

## Source-of-Truth Helper

**`${CLAUDE_PLUGIN_ROOT}/scripts/implementation-plan/resolve-feature-flag-approval.sh`**

Performs the two-hop story→parent epic tag lookup:

1. `dso ticket show <story_id>` → check story tags for `rollout:feature-flags-approved` → `approved, source=story`
2. If not found and `parent_id` is non-null: `dso ticket show <parent_id>` → check parent tags → `approved, source=parent`
3. Otherwise: `prohibited, source=none` with a descriptive `reason`

The helper **always exits 0** — it never exits non-zero. All failure modes (story lookup failure, null parent, parent lookup failure, tag absent on both) produce a valid `prohibited` JSON payload with a non-empty `reason`. This safe-default contract ensures Step 1 is never halted by a feature-flag lookup failure.

---

## Append-Only / Last-Wins Idiom

Step 1 **appends** a new `FEATURE_FLAGS:` comment each time it runs (re-runs are allowed for re-detection). It does **not** delete or update previous `FEATURE_FLAGS:` comments.

**Consumers MUST read the LAST matching `FEATURE_FLAGS:` comment** on the story ticket, ignoring any earlier ones. This is consistent with how `MIGRATION_CLASS:` comments are consumed.

---

## Safe Default

When no `FEATURE_FLAGS:` comment is present on a story ticket (e.g., older stories planned before this step was introduced), consumers MUST treat the absent marker as an inert no-op — emit no flag pair, and do not halt or surface an error. This preserves backward compatibility for all pre-existing stories.

---

## Consumer Protocol

The task-decomposer (`dso:task-decomposer`) is the primary consumer. It receives the marker as the `{feature-flags-marker}` dispatch argument (constructed by `implementation-plan` Step 3, which reads the **LAST** `FEATURE_FLAGS:` comment and passes the verbatim JSON payload).

**Read-only boundary**: the task-decomposer reads `feature-flags` from the passed-in `{feature-flags-marker}` arg ONLY. It NEVER self-fetches from the ticket, inspects story prose, or performs the two-hop lookup itself. The agent has no tracker access; the orchestrator is the sole lookup agent.

**APPROVED path**: emit a flag-cutover task (`migration-role:flag-cutover`) PAIRED WITH a flag-cleanup task (`migration-role:flag-cleanup`). The flag-cleanup task MUST carry a `depends_on` edge referencing the flag-cutover task's `temp_id` — cleanup is only safe AFTER cutover has been confirmed live. This ordering edge is emitted at task-draft time so the sprint two-pass consumer can enforce it; the ordering edge is NOT added retroactively by the two-pass consumer.

**PROHIBITED path**: emit NO flag pair. Record `feature_flags:prohibited` in `decomposition_notes` with the marker's `reason` (non-empty).

**Independence rule**: the flag-tag axis is INDEPENDENT of the `migration-class` axis. A story that is both `db` AND flag-approved MUST emit BOTH the db three-task unit AND the flag pair — the two axes are separate conditionals, not a mutually-exclusive switch.

---

## Ordering Invariant

The flag-cleanup task depends on the flag-cutover task. The `depends_on` edge is written on the flag-cleanup task draft at emission time (not inferred later). Without this edge, the sprint two-pass consumer could schedule cleanup before cutover, which is unsafe. Document the ordering invariant in any flag-pair emission: flag-cleanup `depends_on` flag-cutover.

---

## Consumers

1. **Task-decomposer story** — active consumer: on `approved`, emits the flag-cutover + flag-cleanup task pair with `migration-role:` tags and `depends_on` ordering edge; on `prohibited`, records `feature_flags:prohibited` with reason and emits no flag pair. Receives the marker as the `{feature-flags-marker}` dispatch arg from `implementation-plan` Step 3.
2. **Sprint two-pass-ordering story** — reads `migration-role:flag-cutover` / `migration-role:flag-cleanup` tags to order flag pair halves within the sprint batch. Does not recompute the classification; reads the emitted `migration-role:` tags and `depends_on` edges only.

---

## Worked Example

After Step 1 runs for a story whose parent epic has `rollout:feature-flags-approved`:

```
FEATURE_FLAGS: {"feature-flags":"approved","reason":"tag-found-on-parent-abc123","source":"parent"}
```

For a story where neither story nor parent has the tag:

```
FEATURE_FLAGS: {"feature-flags":"prohibited","reason":"tag-absent-on-story-and-parent-abc123","source":"none"}
```

For a story with no parent:

```
FEATURE_FLAGS: {"feature-flags":"prohibited","reason":"no-parent-on-story-xyz789","source":"none"}
```

---

## Test Exemption

This contract document is exempt from automated unit testing under unit exemption criterion 3, cited verbatim: "modifies only static assets (Markdown documentation) — no executable behavior to test". The artifact is a contract Markdown document; it introduces no executable code path and therefore has no deterministically-testable behavior or runtime failure mode.
