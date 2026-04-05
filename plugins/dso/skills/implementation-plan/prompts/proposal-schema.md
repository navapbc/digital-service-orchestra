# Proposal Schema

This file is the single source of truth for the structured proposal format used by the implementation-plan skill and the decision-maker agent. Both consumers read this file directly — do NOT duplicate these definitions inline.

---

## Proposal Format

Each proposal MUST include all six fields below. Omitting any field is a schema violation.

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | A concise name for the approach (≤ 80 characters). Should distinguish this proposal from alternatives at a glance. |
| `description` | string | A clear explanation of what the approach does, how it works, and why it is viable. Include key design decisions and how they address the story's success criteria. |
| `files` | list of strings | File paths likely touched by this approach. Include files to create, modify, or delete. This list informs the distinctness check and helps detect file-level conflicts. |
| `pros` | list of strings | Concrete advantages of this approach relative to the story's success criteria. Each item must be specific and traceable to a design decision — not generic praise. |
| `cons` | list of strings | Concrete drawbacks, limitations, or risks of this approach. Each item must be specific. Do not omit known tradeoffs. |
| `risk` | string | One of: `low`, `medium`, `high`. See Risk Profile Categories below. |

### Example Proposal

```json
{
  "title": "Event-sourced state machine via Postgres LISTEN/NOTIFY",
  "description": "Persist job state transitions as append-only events in a Postgres events table. The worker subscribes via LISTEN/NOTIFY and applies transitions via a state machine. History is always available; rollback is a read-only query.",
  "files": [
    "app/models/job_event.py",
    "app/workers/job_state_machine.py",
    "migrations/0012_add_job_events_table.py",
    "tests/unit/workers/test_job_state_machine.py"
  ],
  "pros": [
    "Full audit trail: every transition is recorded with timestamp and actor",
    "Rollback is non-destructive: replaying events restores any prior state",
    "LISTEN/NOTIFY avoids polling overhead and reduces DB load"
  ],
  "cons": [
    "Event table grows unbounded without a compaction or archival strategy",
    "LISTEN/NOTIFY requires a persistent connection per worker — adds connection pool pressure"
  ],
  "risk": "medium"
}
```

---

## Risk Profile Categories

Assign exactly one of the three risk levels. Use the criteria below to determine the correct level.

### Low

All of the following apply:
- Change is confined to a single layer (e.g., presentation only, or data model only — no cross-layer side effects)
- No new external dependencies or network calls introduced
- Existing tests cover the modified paths
- Rollback requires only reverting a single file or migration

### Medium

One or more of the following apply:
- Change spans two or more layers (e.g., touches both the data layer and a service/controller layer)
- Introduces a new dependency or integrates with an existing external service in a new way
- Requires new test coverage for previously untested paths
- Rollback requires coordinated steps across multiple files or a migration revert

### High

One or more of the following apply:
- Architectural change: modifies load-bearing abstractions, interfaces shared across modules, or the dependency graph at the module/package level
- Introduces a new external runtime dependency or replaces a core infrastructure component
- Any data migration that is destructive or irreversible
- Failure mode is difficult to detect (silent data corruption, race condition, partial write)
- Rollback requires a coordinated multi-step procedure or is not safely possible without downtime

---

## Distinctness Criteria

Proposals are only useful if they represent genuinely different approaches. A set of proposals that all differ only in naming or surface details gives the decision-maker no real choice.

### Structural Axes

Proposals MUST differ on at least one of the four structural axes below:

| Axis | What it means | Example of difference |
|------|---------------|----------------------|
| **Data layer** | How and where state is stored or retrieved | In-memory cache vs. Postgres table vs. Redis |
| **Control flow** | The execution path or orchestration strategy | Synchronous request/response vs. async event queue vs. polling loop |
| **Dependency graph** | Which modules, packages, or services are introduced or removed | Adding a new library vs. using an existing stdlib module vs. calling an existing internal service |
| **Interface boundary** | Where the public contract is drawn and what it exposes | REST endpoint vs. internal function call vs. CLI flag |

### Distinctness Validation Gate

Before finalizing a proposal set, verify that every pair of proposals differs on at least one axis:

1. For each pair `(A, B)`, compare the proposals on all four axes.
2. If all four axes are identical for a pair, the proposals are structurally equivalent — **reject one and replace it** with a genuinely different approach.
3. A pair passes the gate if they differ on at least one axis, even if they are similar on the others.

Axis comparison is structural, not textual. Two proposals may use different words but still be equivalent (e.g., "store in a dictionary" and "use a hash map" are the same data-layer choice). Conversely, two proposals that look similar may still pass if they differ on control flow or interface boundary.

**A proposal set with any equivalent pair MUST NOT be presented to the decision-maker.**

---

## Usage Notes

- This schema is consumed by the implementation-plan skill (proposal generation) and the decision-maker agent (proposal evaluation and selection).
- Neither consumer may relax or extend the schema unilaterally. Changes to this file require updating both consumers.
- The `files` field is advisory — it supports distinctness checking and conflict detection but is not a binding contract on implementation.
- The `pros` and `cons` fields must be balanced: every proposal must have at least one of each.
