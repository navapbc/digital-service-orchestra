# Bug Classification Registry

This document is the human-readable companion to the machine-readable source of truth:
[`bug-classification-registry.json`](bug-classification-registry.json).

The registry defines the 27 canonical bug classification slugs used across the DSO plugin.
Each slug identifies a recurring defect archetype, maps to a primary defense layer, and
references a concrete artifact that should prevent or detect bugs of that type.

## Purpose

- **Triage** — when filing a bug ticket, pick the slug that best matches the defect archetype
  and add it as a ticket tag (e.g., `tag:scope-drift`).
- **Retrospective analysis** — run `bug-classification-audit.sh` to see which archetypes
  dominate a sprint or release window.
- **Defense gap detection** — each entry's `defense_artifact_ref` points to the primary
  artifact that is responsible for preventing that class of defect. A cluster of bugs under
  one slug signals a weakness in the linked artifact.

## Slug-Rename Procedure

If a slug is renamed in the JSON, run `bug-classification-audit.sh --check-tags` to detect
in-use tags referencing the old slug before committing. Renaming a slug without updating
ticket tags will cause audit queries to miss historical data.

---

## Group A — Planning & Requirements

Primary defense layer: `planning_review`

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `scope-drift` | Was this change implemented beyond the agreed story scope? | planning_review | `plugin:skills/preplanning/SKILL.md` |
| `unverified-assumption` | Was a major design assumption made without evidence from the codebase or stakeholders? | planning_review | `plugin:skills/brainstorm/SKILL.md` |
| `missing-acceptance-criteria` | Was a required acceptance criterion absent from the ticket when implementation began? | planning_review | `plugin:docs/ACCEPTANCE-CRITERIA-LIBRARY.md` |

---

## Group B — LLM-Behavioral

Primary defense layer: `prose_manifest_test`

Applies to: `agent_orchestration` projects only.

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `skill-guidance-gap` | Did a missing or unclear skill instruction cause the LLM to skip or misperform a required workflow step? | prose_manifest_test | `plugin:skills/fix-bug/SKILL.md` |
| `agent-skips-required-step` | Did an agent omit a mandatory step from its workflow without encountering an explicit gate blocking it? | prose_manifest_test | `plugin:docs/HOOKS-REFERENCE.md` |
| `llm-output-format-drift` | Did LLM output deviate from the required schema, structure, or format contract? | prose_manifest_test | `plugin:docs/REVIEW-SCHEMA.md` |

---

## Group C — Code Quality

Primary defense layer: `code_review`

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `unchecked-exit-code` | Was a shell command's exit code left unhandled, allowing silent continuation after failure? | code_review | `plugin:docs/SOFTWARE-DESIGN-PATTERN-CATALOG.md` |
| `silent-failure` | Did an error occur without emitting a user-visible signal, log line, or non-zero exit? | code_review | `plugin:docs/SOFTWARE-DESIGN-PATTERN-CATALOG.md` |
| `unreachable-error-handler` | Was error-handling code structurally unreachable in the execution flow? | code_review | `plugin:docs/REVIEWER-FILE-CHECKLIST.md` |

---

## Group D — Test & Integration

Primary defense layer: `matrix_ci`

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `test-coverage-gap` | Was a code path exercised in production but not covered by any automated test? | matrix_ci | `plugin:skills/shared/prompts/behavioral-testing-standard.md` |
| `mock-production-divergence` | Did a test mock diverge from the real system's behavior in a way that masked a real defect? | matrix_ci | `plugin:skills/shared/prompts/behavioral-testing-standard.md` |
| `integration-test-missing` | Was an integration boundary between two components left without an integration test? | matrix_ci | `plugin:docs/CI-INTEGRATION.md` |

---

## Group E — Concurrency & State

Primary defense layer: `concurrency_test`

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `race-condition` | Did two concurrent operations create non-deterministic state or data corruption? | concurrency_test | `plugin:docs/FLAKY-TEST-REPORTING.md` |
| `non-atomic-state-update` | Was a multi-step state transition left non-atomic, allowing an inconsistent intermediate state to be observed? | concurrency_test | `plugin:docs/FLAKY-TEST-REPORTING.md` |
| `stale-cache-read` | Was a stale cached value read after the underlying source of truth had changed? | concurrency_test | `plugin:docs/SOFTWARE-DESIGN-PATTERN-CATALOG.md` |

---

## Group F — Failure Paths & Recovery

Primary defense layer: `failure_path_test`

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `missing-rollback` | Was a partial write or destructive operation left without a rollback path? | failure_path_test | `plugin:skills/fix-bug/SKILL.md` |
| `partial-write-no-cleanup` | Did a failure leave behind temp files, partial commits, or other artifacts that were never cleaned up? | failure_path_test | `plugin:skills/fix-bug/SKILL.md` |
| `unhandled-edge-case` | Did an expected edge case (empty input, boundary value, missing field) reach code without a handler? | failure_path_test | `plugin:skills/shared/prompts/behavioral-testing-standard.md` |

---

## Group G — Defense Manifest & Preconditions

Primary defense layer: `defense_manifest_test`

Applies to: `agent_orchestration` projects only.

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `defense-artifact-missing` | Was a required defense artifact (rubric, checklist, reviewer doc) absent from the manifest? | defense_manifest_test | `plugin:docs/REVIEWER-FILE-CHECKLIST.md` |
| `unchecked-precondition` | Was a workflow entry precondition left unvalidated, allowing the workflow to proceed in an invalid state? | defense_manifest_test | `plugin:hooks/lib/preconditions-validator-lib.sh` |
| `unacknowledged-degradation` | Did a graceful-degradation fallthrough occur without a corresponding acknowledgment record? | defense_manifest_test | `plugin:docs/contracts/ack-rationale-rubric.md` |

---

## Group H — Release & E2E

Primary defense layer: `release_e2e`

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `e2e-regression` | Did a change cause a regression visible only in end-to-end or acceptance testing? | release_e2e | `plugin:docs/CI-INTEGRATION.md` |
| `config-drift` | Did environment or runtime configuration diverge from what the code expected, causing a production-only failure? | release_e2e | `plugin:docs/CONFIGURATION-REFERENCE.md` |
| `version-skew` | Did a version mismatch between two components (plugin vs. host, schema vs. reader) cause a runtime failure? | release_e2e | `plugin:docs/CONFIGURATION-REFERENCE.md` |

---

## Group I — Operational & Process

Primary defense layer: `operational_process`

| Slug | Classification Question | Defense Layer | Artifact Ref |
|------|------------------------|---------------|--------------|
| `runbook-missing` | Was there no documented runbook for a failure mode that occurred during an incident? | operational_process | `plugin:docs/INCIDENT-TEMPLATE.md` |
| `alert-threshold-misconfigured` | Was an alert threshold set incorrectly, causing the alert to fire too late or not at all? | operational_process | `plugin:docs/INCIDENT-TEMPLATE.md` |
| `oncall-gap` | Did an incident reveal a gap in on-call coverage, escalation path, or handoff procedure? | operational_process | `plugin:docs/INCIDENT-TEMPLATE.md` |

---

## Machine-Readable Source of Truth

All tooling (`bug-classification-audit.sh`, triage validators, ticket tag linters) reads from
[`bug-classification-registry.json`](bug-classification-registry.json). This markdown file is
generated from that JSON and is intended for human reference only. When the two diverge, the
JSON is authoritative.
