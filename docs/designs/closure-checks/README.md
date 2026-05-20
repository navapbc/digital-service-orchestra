# Closure Checks Design Document

## Overview

`## Closure Checks` is a dedicated markdown section in epic and story ticket descriptions that captures **durable end-state intent** — conditions that must hold permanently, not just at milestone completion. Each item is a statement about what the system *will be* (not what it *will do*) once the feature has shipped and stabilized.

---

## Schema Specification

### Section shape

The section appears in epic and story ticket descriptions, placed after `## Success Criteria`:

```markdown
## Closure Checks

- <durable invariant statement 1>
- <durable invariant statement 2>
```

Each item MUST:

- Be written as a present-tense invariant ("Users can…", "The system returns…", "All endpoints are…")
- Describe an observable end-state, not a transitional process
- Be falsifiable — there must be a clear way to observe that the condition is true or false

Each item MUST NOT:

- Use transitional language ("currently", "pending", "until X is done", "as of this sprint")
- Restate a `## Success Criteria` item verbatim — if the content is identical, it belongs in exactly one section
- Reference internal implementation details that may change (specific file names, commit SHAs, temporary workarounds)

### Section placement

Sections appear in this order in the ticket description:

1. `## Description`
2. `## Success Criteria`
3. `## Closure Checks`
4. *(other sections)*

---

## Rationale: Why Separate End-State from Transitional Success Criteria

### The coherence drift problem

`## Success Criteria` items are measurable done-conditions scoped to a sprint or story. They may intentionally use transitional language:

> "Users see the new onboarding flow (replacing the legacy wizard, which remains available via feature flag until migration is complete)"

This is valid during the sprint — the legacy path exists, the flag controls rollout, the migration is in progress. But six months later, when the migration is complete and the flag is gone, this item becomes misleading. If the ticket remains open or is referenced in an audit, the "legacy wizard still available via feature flag" clause is factually wrong.

`## Closure Checks` solves this by capturing the invariants that must be true *after all transitional work is done*:

> "Users complete onboarding through the new flow only — the legacy wizard is not accessible"

This item remains accurate indefinitely.

### Decision table

| Question | Use `## Success Criteria` | Use `## Closure Checks` |
|----------|--------------------------|------------------------|
| Will this be true during the sprint? | Yes | Not required |
| Will this still be true in 12 months? | Maybe | Yes |
| Does this reference a temporary state or flag? | OK | No |
| Is this a measurable exit criterion for the story? | Yes | No |
| Is this a permanent observable invariant? | Optionally | Yes |

A single piece of intent can appear in both sections if it is both a measurable sprint exit condition AND a permanent invariant. In that case, write it as a durable statement in `## Closure Checks` and optionally include the sprint-scoped framing in `## Success Criteria`.

---

## Migration Path

### Background

The `## Closure Checks` section was introduced in ticket schema v1.2.0. All existing epics and stories were created under v1.1.0, which does not include the section.

### Migration tooling

Two scripts handle the migration:

| Script | Purpose |
|--------|---------|
| `${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-migration.sh` | Dry-run audit — lists all epics/stories missing the `## Closure Checks` section; exits non-zero if any are found |
| `${CLAUDE_PLUGIN_ROOT}/scripts/migrate-closure-checks.sh` | Bulk migration — adds an empty `## Closure Checks` section to every epic/story that is missing it |

### Migration procedure

1. Run the audit to confirm scope: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-migration.sh`
2. Review the list — confirm no ticket needs a hand-crafted migration (empty section is always safe)
3. Run the bulk migration: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-closure-checks.sh`
4. The migration script writes the v1.2.0 schema sentinel to the ticket tracker
5. Re-run the audit — it should exit 0 (no tickets missing the section)
6. Commit the tickets branch changes

### Schema sentinel

After migration, the ticket tracker's schema version is updated to `1.2.0`. The sentinel is stored in the ticket tracker index and checked by `validate.sh` during the coherence-walk gate. Tools that depend on the `## Closure Checks` section being present check this sentinel before failing on absence.

---

## Backward-Compatibility Contract

### Invariants

1. **`## Success Criteria` content is never touched by migration tooling.** No item is moved, modified, or deleted. The migration is strictly additive.
2. **An absent `## Closure Checks` section is not an error at runtime.** The completion-verifier's Step 2.5 skips silently when the section is absent or empty. Coherence-walk similarly tolerates pre-migration tickets.
3. **All tools that read `## Success Criteria` continue to work unchanged.** SC coverage prompts, story-point estimators, and completion-verifier SC gates are not affected by the new section.
4. **The schema sentinel gates tooling only, not correctness.** If a ticket tracker has not been migrated to v1.2.0, the completion-verifier logs a warning and continues rather than failing hard.

### Coherence-walk gate behavior

`validate.sh` runs the coherence-walk gate, which flags two drift patterns:

| Pattern | Gate behavior |
|---------|--------------|
| A `## Success Criteria` item and a `## Closure Checks` item are textually identical (exact duplicate) | Warning — suggests the SC item may be transitional and should be reviewed |
| A `## Success Criteria` item contains transitional language markers (`currently`, `pending`, `until`, `temporary`, `feature flag`, `as of`) | Advisory — not a hard gate failure; surfaced for human review |

Neither pattern is a hard failure — they are advisory signals that flag tickets for human review during sprint retrospectives or audits.

---

## Tool Integration

The following tools produce or consume the `## Closure Checks` section:

### Producers

| Tool | Role |
|------|------|
| `dso:preplanning` SKILL.md (Phase H) | Writes `## Closure Checks` items with `← Validates Closure Check:` annotation linking each item to its corresponding SC |
| `${CLAUDE_PLUGIN_ROOT}/scripts/migrate-closure-checks.sh` | Bulk migration — adds empty section to all epics/stories lacking it |

### Consumers

| Tool | Role |
|------|------|
| `dso:completion-verifier` agent (Step 2.5) | Reads items and evaluates each; skips silently when section is absent or empty; invokes `project_closure_hooks` if configured |
| `${CLAUDE_PLUGIN_ROOT}/scripts/coherence-walk.sh` | Gate in `validate.sh`; flags duplicate content and transitional language markers |
| `${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-migration.sh` | Pre-migration audit; lists tickets missing the section |
| SC coverage prompts (`sc-coverage-haiku.md`, `sc-coverage-sonnet.md`, `sc-coverage-opus.md`) | Scoping rule: prompts stop at the `## Closure Checks` heading and do not evaluate its items as success criteria |

### Boundary rule for SC coverage prompts

The SC coverage prompts treat `## Closure Checks` as a hard stop:

> When scanning a ticket description for `## Success Criteria` items, stop reading at the first `## Closure Checks` heading. Do not evaluate any content under `## Closure Checks` as a success criterion.

This prevents the SC coverage gate from double-counting or incorrectly penalizing tickets where the Closure Checks items use different language than the SC items.

---

## Hook Contract Reference

When `project_closure_hooks` is configured in `.claude/dso-config.conf`, the completion-verifier invokes each listed hook for every item in `## Closure Checks`. The hook contract is defined at `${CLAUDE_PLUGIN_ROOT}/docs/contracts/end-state-item-validator.md`.

Hook environment variables:

| Variable | Value |
|----------|-------|
| `ITEM_TEXT` | The full text of the Closure Check item |
| `ITEM_SOURCE_TICKET_ID` | The ticket ID the item came from |
| `CLOSURE_TIMESTAMP` | ISO-8601 timestamp of the closure event |

Hook output (stdout): `{ "valid": true|false, "reason": "<string>", "severity": "PASS|FAIL|WARN" }`
