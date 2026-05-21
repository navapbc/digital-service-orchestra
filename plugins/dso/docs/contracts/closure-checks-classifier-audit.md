# Contract: closure-checks-classifier-audit

- Signal Name: closure-checks-classifier-audit
- Status: accepted
- contract_version: 1
- Scope: `scripts/migrate-closure-checks.sh --classify` ↔ ticket comment audit trail on every migrated `brainstorm:complete`-tagged epic
- Date: 2026-05-20

## Purpose

This contract defines the JSON shape of the audit comment that `scripts/migrate-closure-checks.sh --classify` appends to every ticket whose SC/DoD/AC items were evaluated by the haiku classifier. The audit comment is the durable record of what the migration did, why it did it, and what the user decided when items required interactive escalation. Without a stable schema, the audit trail would be unparseable for post-migration review and re-migration validation.

Consumers:

- `scripts/migrate-closure-checks.sh --classify` (writer) — appends one comment per migrated ticket with the JSON body specified below.
- Post-migration review tooling and the operational migration run summary on epic a03c-d55e-1393-4f27.
- Re-classification audits if the migration is ever re-run (the `migration_run_id` distinguishes runs).

Direct consumer: epic a03c-d55e-1393-4f27 (Closure Checks schema migration) Phase 4 cutover.

---

## §1. Audit comment JSON schema

Each migrated ticket receives exactly one audit comment from each `--classify` run. The comment body is a JSON object:

```json
{
  "schema_version": 1,
  "migration_run_id": "<uuid4>",
  "snapshot_timestamp": "<ISO-8601 timestamp at snapshot-capture time>",
  "ticket_id": "<the ticket this comment is attached to>",
  "items": [
    {
      "original_text": "<verbatim pre-migration item text>",
      "original_section": "SC",
      "classification": {
        "label": "transitional",
        "ranking": 4,
        "rationale": "<one-paragraph haiku-emitted rationale>"
      },
      "user_decision": "accept",
      "post_migration_section": "CC"
    }
  ]
}
```

### Top-level field definitions

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `schema_version` | int | yes | Always `1` for this contract version. Future bumps require migration of consumers. |
| `migration_run_id` | string (UUID4) | yes | Unique identifier for this `--classify` invocation. Multiple ticket audit comments from the same run share this ID. Used to reconstruct a full migration run across the ticket store. |
| `snapshot_timestamp` | string (ISO-8601) | yes | The timestamp at which the script captured the ticket's pre-migration snapshot (see `--classify` DD6 snapshot semantics). Distinct from the comment write timestamp (which the ticket store records separately). |
| `ticket_id` | string | yes | The ticket this comment is attached to. Redundant with the comment's location but included for self-contained parsing. |
| `items` | array | yes | One element per SC/DoD/AC item evaluated by the classifier. May be empty if the ticket had no items to classify (in which case the comment exists as a no-op audit record). |

### Per-item field definitions

| Field | Type | Allowed values | Notes |
|-------|------|----------------|-------|
| `original_text` | string | n/a | Verbatim text of the item as it appeared in the ticket's pre-migration description. Quotes/markdown preserved. |
| `original_section` | string | `"SC"`, `"DD"`, `"AC"` | The section the item was extracted from. `SC` = Success Criteria, `DD` = Done Definitions, `AC` = Acceptance Criteria. |
| `classification.label` | string | `"end-state"`, `"transitional"`, `"uncertain"` | Haiku-emitted label per the classifier prompt. |
| `classification.ranking` | int | `1`–`5` | Haiku-emitted ranking. Higher = more confident in the label. |
| `classification.rationale` | string | n/a | Haiku-emitted rationale, single paragraph. |
| `user_decision` | string | `"accept"`, `"reject"`, `"defer"`, `"auto"` | What was decided for this item. See decision-semantics below. |
| `post_migration_section` | string | `"SC"`, `"CC"` | Where the item ends up after the migration applies the decision. `SC` = stays in Success Criteria, `CC` = moved to Closure Checks. |

### Decision semantics

The `user_decision` field captures who made the decision and what they decided:

| `user_decision` | Meaning | When it applies |
|-----------------|---------|----------------|
| `auto` | The classifier returned a verdict at high enough confidence that no user prompt fired. Three sub-cases exist per the DD4 amendment (story ad70-f38a-7684-4e00 §6 — `commit:ce2ec1a65c`). See "auto sub-cases" table below. | High-confidence classifier verdicts. |
| `accept` | The user explicitly accepted the proposed migration via the per-item ack UX (`[a]ccept`). The proposed section change (if any) is applied. | All non-`auto` items where the user typed `a`. |
| `reject` | The user explicitly rejected the proposed migration (`[r]eject`). The item stays in its original section regardless of the classifier label. | All non-`auto` items where the user typed `r`. |
| `defer` | The user deferred the decision (`[d]efer`) OR the script ran in non-TTY mode and could not prompt. The item stays in its original section AND the audit comment records `user_decision: defer` so the next run sees it as untouched and re-classifies. | All non-`auto` items where the user typed `d` or where stdin was not a TTY. |

### Auto sub-cases (DD4 amendment)

The classifier's verdict drives auto-apply behavior only in these three configurations:

| `classification.label` | `classification.ranking` | `post_migration_section` | Rationale |
|------------------------|--------------------------|--------------------------|-----------|
| `end-state` | `>= 4` | `SC` | Classifier is confident the item describes a durable system property; item stays in Success Criteria. |
| `transitional` | `== 5` | `CC` | Classifier is maximally confident the item is a one-time transition; auto-route to Closure Checks. |
| `uncertain` | `== 5` | `SC` | Classifier is confident in indecision (rare); preserve item in original section pending future re-classification. |

All other label/ranking combinations require explicit user ack via the `accept`/`reject`/`defer` flow (no `auto`). This includes `transitional ranking 1-4` and `uncertain ranking 1-4`.

### Post-migration section semantics

The `post_migration_section` field encodes the FINAL location after the user's decision is applied:

- `user_decision: auto` AND `classification.label: end-state` → `post_migration_section: SC` (high-confidence end-state stays in original section)
- `user_decision: auto` AND `classification.label: transitional` AND `classification.ranking: 5` → `post_migration_section: CC` (max-confidence transitional auto-moves SC→CC)
- `user_decision: auto` AND `classification.label: uncertain` → `post_migration_section: SC` (uncertain auto stays in SC)
- `user_decision: accept` AND `classification.label: transitional` → `post_migration_section: CC` (transitional items move SC→CC on accept)
- `user_decision: accept` AND `classification.label` in `{end-state, uncertain}` → `post_migration_section: SC` (end-state and uncertain items stay in SC on accept)
- `user_decision: accept` AND `override_target: <value>` → `post_migration_section: <override_target>` (explicit user override of the classifier's proposed_target; overrides take precedence over label-derived defaults)
- `user_decision: reject` → `post_migration_section: SC` (item stays in original section regardless of label)
- `user_decision: defer` → `post_migration_section: SC` (item stays untouched pending future re-classification)

---

## §2. Resolution-path examples

### Example 1 — high-confidence end-state, no prompt

```json
{
  "original_text": "the system supports OAuth login",
  "original_section": "SC",
  "classification": {"label": "end-state", "ranking": 5, "rationale": "durable system capability phrased as ongoing behavior"},
  "user_decision": "auto",
  "post_migration_section": "SC"
}
```

### Example 2 — high-confidence transitional, user accepted move to CC

```json
{
  "original_text": "OAuth has been migrated from the legacy adapter",
  "original_section": "SC",
  "classification": {"label": "transitional", "ranking": 5, "rationale": "past-tense one-time migration; not a durable system property"},
  "user_decision": "accept",
  "post_migration_section": "CC"
}
```

### Example 3 — uncertain, user deferred

```json
{
  "original_text": "the migration is observable",
  "original_section": "SC",
  "classification": {"label": "uncertain", "ranking": 3, "rationale": "ambiguous between durable observability property and one-time setup task"},
  "user_decision": "defer",
  "post_migration_section": "SC"
}
```

---

## §3. Schema versioning policy

This contract is `contract_version: 1`. The audit comment JSON includes `schema_version: 1` so consumers can detect schema drift over time.

- Adding optional fields → backward-compatible; remains `schema_version: 1`.
- Adding required fields, removing fields, changing enum values, or restructuring `items` → requires `schema_version: 2` and a migration plan for any consumer that pins `schema_version: 1`.

`schema_version: 1` is retired only via formal version bump to v2 with a documented migration plan. Mirrors the versioned-contract retire policy used by `end-state-item-validator` and `coherence-walkthrough-chunk-output`.
