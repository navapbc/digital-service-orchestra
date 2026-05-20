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

The migration is split across **two surfaces** — ticket-body migration (epics/stories) and source-file consumer migration (plugins/, tests/, docs/):

| Script | Surface | Purpose |
|--------|---------|---------|
| `${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-migration.sh` | Ticket bodies | Dry-run audit — lists all epics/stories missing the `## Closure Checks` section; exits non-zero if any are found |
| `${CLAUDE_PLUGIN_ROOT}/scripts/migrate-closure-checks.sh` | Ticket bodies | Bulk migration — adds an empty `## Closure Checks` section to every epic/story that is missing it |
| `${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-source-consumers.sh` | Source files | Source-file consumer audit — scans `.md`/`.sh`/`.py`/`.yaml`/`.yml` under `plugins/`, `tests/`, `docs/` for Closure Checks references; classifies each match into one of six precedence-ordered buckets and emits a JSON artifact for downstream tooling |
| `${CLAUDE_PLUGIN_ROOT}/scripts/apply-bucket-recipes.sh` | Source files | Source-file recipe applier — consumes the bucket JSON and applies the bucket-specific recipe (dry-run by default; see "Dry-run policy" below) |

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
| `${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-migration.sh` | Pre-migration audit (ticket-body surface); lists tickets missing the section |
| `${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-source-consumers.sh` | Pre-migration audit (source-file surface); classifies source-file references into six buckets and emits JSON for the recipe applier and follow-on tooling. Wired into `validate.sh` as a soft check (exit 1 — incomplete reconciliation — does not fail validate) |
| `${CLAUDE_PLUGIN_ROOT}/scripts/apply-bucket-recipes.sh` | Source-file recipe applier; reads the source-audit JSON and applies the bucket-specific recipe. Dry-run by default; `--apply` requires explicit opt-in |
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

---

## Source-file consumer audit

The ticket-body audit (`audit-closure-checks-migration.sh`) covers epic and story descriptions in the ticket tracker. A second surface — source code, tests, and documentation — also references the `## Closure Checks` schema (regex section sweeps, alias mentions, parser-driver imports, user-facing copy). Migrating the ticket bodies in isolation leaves the source-file surface unmanaged.

`${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-source-consumers.sh` closes that gap. It is **read-only**, emits a deterministic JSON artifact at `<host-project>/${CLAUDE_PLUGIN_ROOT}/.audit-output/closure-checks-migration-<timestamp>.json`, and is wired into `validate.sh` as a parallel check.

| Property | Ticket-body audit | Source-file consumer audit |
|----------|-------------------|----------------------------|
| Script | `audit-closure-checks-migration.sh` | `audit-closure-checks-source-consumers.sh` |
| Surface | Epic + story ticket descriptions | `.md`/`.sh`/`.py`/`.yaml`/`.yml` under `plugins/`, `tests/`, `docs/` |
| Output | Stdout list of tickets missing the section | Stdout list of files with at least one match + JSON artifact with bucket counts and per-match metadata |
| Exit codes | Non-zero if any tickets are missing the section | 0 = convergent, 1 = `RECONCILIATION_INCOMPLETE`, 2 = error |
| `validate.sh` integration | Indirect (via `coherence-walk.sh`) | Direct (soft check; exit 1 → PASS, exit 2 → FAIL) |
| Idempotent / reproducible? | Yes | Yes when reconciliation converges; the steady-state full-bucket comparison contract (below) is the verification |

### Steady-state contract

Two consecutive runs against an unchanged tree produce **identical** counts across all 8 numeric fields:

- 6 bucket counts (`migration-in-progress`, `test-asserting-on-structure`, `semantic-consumer`, `user-facing-copy`, `section-name-reference`, `file-path-reference`)
- `unbucketed_matches` count
- `dynamic_load_count`

If two runs disagree on any of those fields the audit MUST set `reconciliation_status: "incomplete"` and emit the `RECONCILIATION_INCOMPLETE` block on stdout. Downstream tooling (the recipe applier, manual review prompts) treats `incomplete` as a non-blocking signal — work continues, but the residual is surfaced for human attention.

The JSON envelope schema is documented in `${CLAUDE_PLUGIN_ROOT}/docs/contracts/closure-checks-source-audit-output.md`.

---

## Bucket recipes

The source-file audit classifies each match into one of six precedence-ordered buckets. Each bucket has a corresponding **recipe** — the bulk migration action that `apply-bucket-recipes.sh` performs when the bucket is targeted. Precedence is top-down (most specific first); a single match lands in exactly one bucket.

| # | Bucket | Recipe (high level) |
|---|--------|--------------------|
| 1 | `migration-in-progress` | File is currently being migrated (file-level `MIGRATION-IN-PROGRESS` marker or `migrate-*.sh` filename). Skip — the migrating tool owns the rewrite. |
| 2 | `test-asserting-on-structure` | Test file asserts on the section's literal presence/absence. Recipe: leave the assertion in place; if the assertion is checking schema-v1.1.0 absence, retarget to the v1.2.0 schema sentinel. |
| 3 | `semantic-consumer` | Code parses/extracts/generates from the section (regex, parser, walker). Recipe: route through a shared helper that respects the v1.2.0 schema and degrades gracefully when the section is absent. |
| 4 | `user-facing-copy` | The literal appears in a user-facing message (`print`/`echo`/`logger.*` calls, or markdown prose with `Error:`/`Note:`/imperative-prefixed lines). Recipe: leave the copy unchanged; humans read it. |
| 5 | `section-name-reference` | A literal `## Closure Checks` heading appears in a markdown file (documentation, ADR, design note). Recipe: leave the heading; update surrounding prose only if it asserts pre-migration state. |
| 6 | `file-path-reference` | A line mentions a known schema-consumer file (`migrate-closure-checks.sh`, `coherence-walk.sh`, etc.) without parsing or asserting. Recipe: validate the path is still correct; rewrite if the file has moved. |

The recipe applier itself (`apply-bucket-recipes.sh`) is created and tested by a **separate parallel task** (T3 of story 7e2c-2f4c-cd95-4e60). This document defines the contract; the implementation lives in that task.

---

## Dry-run policy

Any `validate.sh` integration that invokes a Closure-Checks migration tool MUST default to **dry-run** (read-only / no file mutations). This applies to:

- `audit-closure-checks-source-consumers.sh` — already read-only by design; wired into `validate.sh` as a parallel check.
- `apply-bucket-recipes.sh` — defaults to `--dry-run`; `--apply` is an explicit opt-in that MUST NOT be passed from `validate.sh` or any pre-commit hook.

Rationale: `validate.sh` runs on every commit attempt and inside CI. Auto-applying a bulk migration as part of a routine validation pass would mutate the working tree without an explicit migration ticket and without giving a human the chance to review the bucket assignments. The recipe applier exists for **explicit human-driven migration runs**, not for ambient enforcement.

Enforcement: `tests/scripts/test-validate-source-audit-integration.sh` asserts that `validate.sh` does not contain `apply-bucket-recipes` or a `--apply` flag anywhere in its source.
