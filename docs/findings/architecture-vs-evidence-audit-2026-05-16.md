# Architecture-vs-Evidence Audit — 2026-05-16

**Audit scope**: all open or in-progress epics carrying the `brainstorm:complete` tag (N=39) as of 2026-05-16.
**Auditor**: 8 opus-tier sub-agents, batched 5 epics/agent (last batch 4), each applying 6 probes.
**Probe source**: `docs/findings/d076-postmortem-analysis.md` §6 — the amendment surface for /dso:brainstorm, /dso:preplanning, /dso:implementation-plan, /dso:sprint, /dso:completion-verifier, /dso:end-session.
**Raw data**: `docs/findings/architecture-vs-evidence-audit-2026-05-16.json` (per-epic records, structured).
**Per-epic remediation**: invoke `/dso:remediate-arch-evidence <epic-id>` in a fresh session per impacted epic.

---

## Executive summary

**28 of 39 (72%) brainstorm-complete epics flag HIGH severity.** The post-mortem's diagnosis is systemic, not isolated to the f61f→d076 incident — this project's planning history has been silently producing architecture-vs-evidence gaps at scale.

Severity distribution:

| Severity | Count | Definition |
|---|---|---|
| HIGH | 28 | 2+ probes flagged, OR probe 1 alone (self-use), OR probe 5 alone (spec-phase coverage) |
| MEDIUM | 6 | exactly 1 other probe flagged |
| NONE | 5 | zero probes flagged |

Probe-flag frequencies (out of 39 epics audited):

| # | Probe | Frequency | % |
|---|---|---|---|
| 1 | Architectural-class self-use | 23 | 58% |
| 3 | Shared-state-variable lifecycle | 21 | 53% |
| 6 | External-outcome SC capture | 16 | 41% |
| 5 | Spec-phase coverage | 5 | 12% |
| 4 | Bypass governance pairing | 4 | 10% |
| 2 | Workflow-trigger audit | 1 | 2% |

**Pattern**: probes 1 / 3 / 6 dominate. The systemic failures are (a) shipping orchestration changes without requiring the epic's own sprint to use them (self-use), (b) introducing shared state without naming UPDATE/RETIRE owners (lifecycle), (c) carrying external dependencies in prose rather than structured blocks (external-outcome). Probe 2 (workflow-trigger audit) flagged only once because the f61f-class ref-pattern introduction is rare. Probes 4 (bypass governance) and 5 (spec-phase coverage) flagged in narrower cases that are easier to address per epic.

---

## Probe definitions (recap)

For each probe, FLAG means the amended /dso:brainstorm would have raised a gap question that the original brainstorm did not.

1. **Architectural-class self-use** — Does the epic ship orchestration changes (CI workflow files, `.claude/**` content, git hooks, installed plugin skill/agent/hook files) without requiring its own sprint to USE the architecture it builds?
2. **Workflow-trigger audit** — Does the epic introduce a new git ref pattern without enumerating the trigger filters of every CI workflow file that should fire on the new pattern?
3. **Shared-state-variable lifecycle** — Does the epic introduce a shared state variable without naming the owner for each of CREATE / UPDATE / CONSUME / RETIRE?
4. **Bypass governance pairing** — Does the epic introduce a bypass mechanism (env var, CLI flag, escape hatch) without pairing it with audit logging + required justification + abuse-detection?
5. **Spec-phase coverage** — Does the epic name ordered phases that are absent from the story/task breakdown?
6. **External-outcome SC capture** — Does the epic have an SC whose verification depends on external state (operator-manual, repo-level, third-party) without a structured External Dependencies block?

Severity rules:
- HIGH: 2+ probes flagged, OR probe 1 flagged alone, OR probe 5 flagged alone.
- MEDIUM: exactly 1 other probe flagged.
- NONE: zero probes flagged.

---

## HIGH severity (28 epics)

Each row: epic id, flagged probes, one-line title. Suggested remediation lives in the JSON sidecar's `suggested_remediation` field; the remediate-arch-evidence skill consumes it.

| Epic | Probes | Title |
|---|---|---|
| 0cbc-4bbb-e2f6-4da0 | 3, 5, 6 | External-integration verification gate for /dso:fix-bug |
| 136b-6758-ba12-47fc | 1, 3 | Consolidate project-setup skills into resume-aware /dso:onboarding |
| 3e9b-afee | 1, 3 | Kudos system: infrastructure and primary triggers |
| 411b-a047-18de-4516 | 1, 2, 3, 5, 6 | Test creation calibration (d): mutation-testing infrastructure |
| 4911-c7ba | 1 | Bug-classification coverage registry + audit + fix-bug tagging |
| 6add-c1fc | 1, 3, 6 | Integrate Semgrep with mandatory security rulesets into CI pipeline |
| 71df-5bd8 | 1 | Kudos system: detection triggers and agent behavioral improvements |
| 7510-0198-3e2b-4ca5 | 1, 3 | DSO orphan story/task prevention: literal --parent injection + CI enforce |
| 7f42-e41f-a501-4007 | 3, 6 | Test creation calibration (b): suite growth tracks behavioral coverage |
| 8623-8d6a-0bc1-4c6e | 1, 3 | /dso:onboarding Strata awareness (detection + posture + silent config) |
| 87e9-0bc8 | 1, 3 | Polyglot Test Gate: stack-agnostic test runner config and gate scripts |
| 88d2-6756 | 1, 3, 6 | Required CodeQL + code-quality scanning gates: CI emission and rulesets |
| 8d21-3aa8 | 1, 3, 4 | Wire recipe library into implementation planning and sprint execution |
| 94ed-f55c-51f5-45f6 | 3, 5 | Plan-time intent allocation: owner_ticket + test_artifact per end-state |
| a03c-d55e-1393-4f27 | 3, 5 | Closure Checks schema migration: end-state intent vs transitional work |
| a34c-b345-1e63-4ae3 | 1, 3, 6 | Calibration program observability: rollup metrics + trend tracking |
| a524-fded | 1, 3, 4, 6 | Migrate test execution to background primitive; remove test-batched |
| af26-dd5a-df6d-4f81 | 1, 3, 4 | Make forbidden-action HARD-GATEs in brainstorm/sprint/fix-bug/impl-plan |
| b575-ac1c-f720-4839 | 1, 3 | Cycle-end arbiter + workflow unification (in_progress) |
| c13f-6196 | 1, 5 | Test gate observability: detect irrelevant test→source mappings |
| c206-5acb-9c69-4612 | 1, 3, 6 | Strata SDK planning context for brainstorm/preplanning/impl-plan |
| c2cc-e3c4 | 1 | Directory size monitor: advisory session-start hook with auto-ticketing |
| d2f9-ee1a-48ab-4bf6 | 1, 6 | Code review telemetry infrastructure: ingest endpoint + schema + stats |
| d765-a3b6-84bd-4816 | 4, 6 | Strata-aware create-dso-app.sh rewrite (Rails+SDK+USWDS default) |
| e471-dda3 | 1, 6 | Reference libraries for agents: Confluence integration + URL fetch |
| f27a-3c6a-1a4e-48ae | 1, 6 | External reviewer integration (CodeRabbit/Gitar/Copilot) + auto-resolve |
| f7d5-59e4 | 1 | Implementation-plan citation annotation with local-first reference merging |
| w21-bsnz | 1 | Create a process to remediate legacy code |

---

## MEDIUM severity (6 epics)

| Epic | Probes | Title |
|---|---|---|
| 01f5-28c1 | 3 | Polyglot Kudos Triggers: language-agnostic T7/T9/T12/T13/T4 replacements |
| 188c-47e4-5abe-4b9c | 3 | Migrate stack detection from singular value to namespaced array schema |
| 4f8e-a7a6 | 3, 6 | Figma design collaboration: Pull validation via perceptual diff |
| 53ef-d6fd-5ca5-4d62 | 6 | DSO cross-session PR ownership: PreToolUse wrapper + Session-Id trailer |
| 69e8-af39-7886-4ee9 | 6 | Test creation calibration (c): feedback loop from production bugs |
| da4e-4e9a-250b-4a8b | 6 | Telemetry adapter framework + first-party emitters + language starter pack |

---

## NONE severity (5 epics; no remediation needed)

| Epic | Title | Why no flag |
|---|---|---|
| 0b7c-d811 | Add searchable UI/UX design knowledge base | No orchestration surface, no shared state, no bypass, no external-outcome |
| 5018-64ce | Evaluate and resolve current TODO/FIXME comments | Bounded triage epic; no new orchestration |
| 70d5-37ee | Java First-Class Language Support | Java-stack-scoped; not self-applicable to DSO's Python repo |
| bc7f-1a0d | Cross-file static bloat detectors | Detector-path only; no load-bearing surface |
| d566-afa6-1aa3-4293 | Test creation calibration (a) | Already pairs prompt/agent changes with explicit dogfood SC |

---

## Recommended next steps

1. **Tag every impacted epic** (HIGH + MEDIUM = 34 epics) with `arch-evidence:remediation-needed`. Already done by this brainstorm session.
2. **Remediate one epic at a time, in fresh sessions, using `/dso:remediate-arch-evidence <epic-id>`.** The skill reads this report's JSON sidecar, surfaces the flagged probes, and walks the user through structured remediation per probe. Single-epic scope per invocation — to remediate multiple, invoke the skill once per epic.
3. **Block all new epic brainstorms until the remediation epic this audit informs has shipped and closed.** Once the amended /dso:brainstorm probes are live, future epics will surface these gaps at planning rather than accumulating them as a backlog.
4. **Do not auto-file 34 P3 remediation bugs.** The tags are the discovery mechanism; bugs would be backlog noise. Owners (or the next maintainer to touch a flagged epic) re-brainstorm or apply `/dso:remediate-arch-evidence`.

---

## Tag-application caveat

`w21-bsnz` (HIGH severity, single probe-1 flag) was not tagged: `ticket tag` rejects the non-standard bridge-ID form with `not found` even though `ticket list` returns the ticket. CLI inconsistency on bridge IDs — out of this session's scope; tag manually once resolved.

## Methodological notes

- **Classifier blind spot**: `classify-sc-shape.sh` returned `pure-code` for SCs containing operator-manual phrasing ("the operator runs `/reload-plugins`"). This is a real blind spot in the keyword set — the classifier should be enhanced to recognize operator-manual triggers as external-outcome.
- **Audit confidence**: each probe was applied against concrete textual evidence in the epic spec; the classifier was instructed to flag only when evidence is present, not on speculation. False-positive rate is expected low; false-negative rate (gaps the probes don't catch) is unknown and bounded by the probe definition.
- **Audit scope limit**: only `brainstorm:complete`-tagged epics were audited. Open epics without `brainstorm:complete` are by definition pre-decomposition and outside the audit's frame. The remediation epic's amended probes will apply to those when they brainstorm.
- **Audit replay**: re-running the audit after the remediation epic ships should show probe-flag frequencies drop materially on newly-brainstormed epics. The audit doc + JSON serve as the empirical baseline.
