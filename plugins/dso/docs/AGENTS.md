# DSO Named-Agent Routing Reference

The full table of named sub-agents, their default model tier, and the workflow that dispatches them. CLAUDE.md keeps only the high-frequency rows; this file is the authoritative reference.

## Dispatch protocol

Agent files live in `${CLAUDE_PLUGIN_ROOT}/agents/` (with a parallel CI-variant tree at `${CLAUDE_PLUGIN_ROOT}/agents/ci/` for the 10 code-reviewer agents — see the "Dual-variant code-reviewer agents" section below for the full mechanism). The `dso:*` labels below are agent file identifiers (strip `dso:` prefix to get the filename).

- Use `subagent_type: "dso:<name>"` directly when the agent is registered in the Agent tool's available types list (check the session's available `subagent_type` list at startup).
- Fall back to `subagent_type: "general-purpose"` with the agent file loaded verbatim only when the named type is not registered.
- See `REVIEW-WORKFLOW.md` Step 4 for the canonical dispatch block.
- `discover-agents.sh` resolves routing categories to agents via `agent-routing.conf`; all fall back to `general-purpose`.

### Dual-variant code-reviewer agents (bug 4a30)

The 10 `dso:code-reviewer-*` agents in the table below (light, standard, deep-{arch,correctness,verification,hygiene}, security-{red,blue}-team, performance, test-quality) are composed in **two variants** by `build-review-agents.sh`:

- **Orchestrator variant** (`agents/code-reviewer-<tier>.md`) — used by Claude Code's Agent tool dispatch. Instructs the model to invoke Bash/Read/Grep/Glob and to run `write-reviewer-findings.sh`, returning a `REVIEWER_HASH` envelope.
- **CI variant** (`agents/ci/code-reviewer-<tier>.md`) — used by `scripts/dso_ci_review/dispatch.py` (the `litellm.completion` toolless path). Instructs the model to return findings as a single JSON object directly in the message body — no tool-use markup, no script invocation, no `REVIEWER_HASH` envelope.

Both variants are generated from a single canonical source: `docs/workflows/prompts/reviewer-base.md` (shared content) plus per-tier `reviewer-delta-<tier>.md` files. The base file uses `<!-- DISPATCH:orchestrator -->` / `<!-- DISPATCH:ci -->` HTML-comment markers; `reviewer-meta.sh::_meta_substitute_base` reads `DISPATCH_VARIANT={orchestrator|ci}` and strips the opposing block. `build-review-agents.sh` invokes the composer twice — once per variant — writing to `agents/` and `agents/ci/` respectively. See `docs/contracts/dispatch-split-architecture.md` for the full architectural overview.

**`dispatch.py` resolution** (`_load_agent_prompt`): tries `agents/ci/<agent_id>.md` first, falls back to `agents/<agent_id>.md`. Code-reviewer agents resolve through `agents/ci/`; agents without a CI variant (`code-reviewer-arbiter`, `code-reviewer-verifier`, `schema-correction`, etc.) resolve through `agents/`.

**Not in scope for the split**: `huge-diff-reviewer-{light,standard}` are orchestrator-only (CI uses Strategy E region-split via `region_split.py`, never dispatches huge-diff). Arbiter and verifier do not compose `reviewer-base.md` and have no tool-use instructions — confirmed safe by the bug 4a30 sweep.

## Agents

| Agent | Model | Dispatched by |
|-------|-------|---------------|
| `dso:complexity-evaluator` | haiku | `/dso:sprint`, `/dso:preplanning`; read inline by `/dso:fix-bug` |
| `dso:conflict-analyzer` | sonnet | `/dso:resolve-conflicts` |
| `dso:cross-epic-interaction-classifier` | haiku | `/dso:brainstorm` (cross-epic scan step — dispatched in batches of 5 open epics via cross-epic-scan.md prompt; emits interaction_signals JSON with 4-tier severity) |
| `dso:bot-psychologist` | sonnet | `/dso:fix-bug` llm-behavioral path (dispatched or read inline when sub-agent) |
| `dso:doc-writer` | sonnet | `/dso:sprint` (doc stories), `/dso:update-docs` |
| `dso:gov-copy-writer` | sonnet | `/dso:sprint` (copy stories — government UI copy generation from Copy Needs section; emits gov-copy-artifact YAML) |
| `dso:intent-search` | sonnet | `/dso:fix-bug` Phase B Step 1 (Intent Gate — pre-investigation intent search; skipped for CLI_user-tagged bugs); emits INTENT_CONFLICT signal when callers depend on current behavior |
| `dso:scope-drift-reviewer` | sonnet | `/dso:fix-bug` Phase F Step 1 (scope-drift review after fix verification; skipped when `scope_drift.enabled=false`) |
| `dso:feasibility-reviewer` | sonnet | `/dso:brainstorm` (conditional, on integration signals) |
| `dso:story-decomposer` | opus | `/dso:preplanning` Story Decomposition phase (between Phase B and Phase C) — drafts new vertical-slice stories with SC-tied Done Definitions; replaces inline orchestrator drafting |
| `dso:red-team-reviewer` | opus | `/dso:preplanning` Phase E |
| `dso:blue-team-filter` | sonnet | `/dso:preplanning` Phase E |
| `dso:completion-verifier` | sonnet | `/dso:sprint` story closure (Step 10a) + epic closure (Phase 7 Step 0.75) |
| `dso:red-test-writer` | sonnet | `/dso:sprint` Phase 5, `/dso:fix-bug` Phase E Step 1 |
| `dso:red-test-evaluator` | opus | On red-test-writer rejection (REVISE/REJECT/CONFIRM) |
| `dso:code-reviewer-light` | haiku | `/dso:review` (score 0–2) |
| `dso:code-reviewer-standard` | sonnet | `/dso:review` (score 3–6) |
| `dso:code-reviewer-deep-correctness` | sonnet | `/dso:review` (score 7+, deep-tier specialist — edge cases, error handling, security, efficiency) |
| `dso:code-reviewer-deep-hygiene` | sonnet | `/dso:review` (score 7+, deep-tier specialist — hygiene, design, maintainability) |
| `dso:code-reviewer-deep-verification` | sonnet | `/dso:review` (score 7+, deep-tier specialist — test presence/quality/coverage, mock correctness) |
| `dso:code-reviewer-deep-arch` | opus | `/dso:review` (score 7+, synthesis — unifies the 3 deep specialists' findings into a verdict) |
| `dso:code-reviewer-security-red-team` | opus | `/dso:review` overlay — parallel when classifier flags `security_overlay:true`; serial when tier reviewer flags `security_overlay_warranted:yes` |
| `dso:code-reviewer-security-blue-team` | opus | `/dso:review` overlay — triages red team findings with dismiss/downgrade/sustain; dispatched after red team |
| `dso:code-reviewer-performance` | opus | `/dso:review` overlay — parallel when classifier flags `performance_overlay:true`; serial when tier reviewer flags `performance_overlay_warranted:yes` |
| `dso:code-reviewer-test-quality` | opus | `/dso:review` overlay — parallel when classifier flags `test_quality_overlay:true` (diff touches `tests/`); serial when tier reviewer flags `test_quality_overlay_warranted:yes`; detects 5 test bloat patterns against behavioral testing standard |
| `dso:approach-decision-maker` | opus | `/dso:implementation-plan` proposal resolution loop — evaluates distinct implementation proposals against 5 dimensions; emits `APPROACH_DECISION` signal (contract: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/approach-decision-output.md`) |
| `dso:approach-proposer` | opus | `/dso:implementation-plan` Step 1 Proposal Generation — generates ≥3 distinct implementation proposals with explicit complexity-gate and four-axis distinctness-gate audit trails; output is the input to `dso:approach-decision-maker`; replaces inline orchestrator drafting |
| `dso:task-decomposer` | opus | `/dso:implementation-plan` Step 3 Atomic Task Drafting — decomposes story + selected approach into atomic TDD-driven tasks with full ACs, DD partition map, dependency edges, retry budget; replaces inline orchestrator drafting |
| `dso:ui-designer` | sonnet | `/dso:preplanning` Step 6 — creates design artifacts (spatial layout, SVG wireframe, token overlay, manifest) for UI stories via Agent tool dispatch; returns `UI_DESIGNER_PAYLOAD` (contract: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/ui-designer-payload.md`) |
| `dso:visual-evaluator` | sonnet | `/dso:sprint` post-batch visual evaluation (Integration B) + inline per-task iteration loop (Integration A) — evaluates rendered UI screenshots against design manifests; emits structured JSON findings with pixel-observable spatial quality scores (5 dimensions, 1-5) and attribution routing (implementation_drift/design_flaw/mixed/uncertain); params from `${CLAUDE_PLUGIN_ROOT}/config/visual-evaluator-params.yaml` |
| `dso:verification-remediation-planner` | opus | `/dso:sprint` story/epic closure (after `dso:completion-verifier` returns `P1=FAIL`) — classifies verifier failures via 4-branch ordered decision tree (replan_story/new_tasks_in_story/new_story_in_epic/replan_epic) with short-circuit semantics; emits structured `{scope, target_id, decomposer_context, escalation_upstream, confidence}` envelope for remediation routing |
| `dso:plan-review` | sonnet | `/dso:plan-review` — evaluates implementation plans and design artifacts on feasibility, completeness, YAGNI, and codebase alignment before the user sees them |
| `dso:bloat-blue-team` | opus | _Pending epic `w21-bsnz` implementation (consumed by `bc7f-1a0d`, `2687-3d0d-e817-4721`)._ Evaluates probabilistic bloat candidates, classifying as CONFIRM/DISMISS/NEEDS_HUMAN with asymmetric error policy (defaults to DISMISS when uncertain). Orchestrator skill (`/dso:remediate` for bloat detection) is not yet implemented. |
| `dso:bloat-resolver` | opus | _Pending epic `w21-bsnz` implementation (consumed by `bc7f-1a0d`, `2687-3d0d-e817-4721`)._ Path B auto-resolve — applies confirmed bloat removals with dependency checks before each deletion. Same orchestrator-pending status as `bloat-blue-team`. |
| `dso:inference-incident-curator` | opus | `/dso:retro` (quarterly append step; wired 2026-05-19 per project-audit Q2) — scans ticket history for inference incidents and emits JSONL corpus records consumed by `inference-recall-replay.sh` (contract: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/inference-incident-schema.md`). |
| `dso:second-source-verifier` | sonnet | Read-only post-closure audit of epic story closures (confirms typed-enum verifier P1, `render-closure-narrative.sh`, `check-story-handoff.sh` were actually used). **Manual-invocation only.** Dispatch via Agent tool with `subagent_type="dso:second-source-verifier"` and the target `epic_id` in the prompt; consume the structured report via `.claude/scripts/dso check-second-source-report.sh`. Automated wire-up into the sprint closure flow is deferred pending (a) formal closure of epic `a03c-d55e-1393-4f27` (Closure Checks schema migration — 9/10 stories closed as of 2026-05-19; one docs-only story remains), (b) decision on advisory-vs-blocking verdict semantics, (c) refinement of the "benefit-of-doubt PASS" path in Step 2c for linear-dependency stories. Tracked by bug `842f-9f11-b075-4b34`. |

## Specialty agents

Execution-tier specialists dispatched by specific phase blocks in larger workflows. The main "Agents" table covers orchestration-tier routing; this subsection enumerates the agents that fire from inside a workflow's body rather than from a top-level skill dispatch.

| Agent | Model | Dispatched by |
|-------|-------|---------------|
| `dso:investigator-basic` | sonnet | `/dso:fix-bug` Phase D — BASIC tier (single-pass localization, five-whys, single proposed fix for low-complexity bugs) |
| `dso:investigator-intermediate` | opus | `/dso:fix-bug` Phase D — INTERMEDIATE primary (dependency-ordered reading, ≥2 ranked fixes with tradeoffs) |
| `dso:investigator-intermediate-fallback` | opus | `/dso:fix-bug` Phase D — INTERMEDIATE fallback when `error-detective` is unavailable |
| `dso:investigator-advanced-code-tracer` | opus | `/dso:fix-bug` Phase D — ADVANCED Code Tracer lens (execution path tracing, intermediate variable tracking; concurrent with Historical) |
| `dso:investigator-advanced-historical` | opus | `/dso:fix-bug` Phase D — ADVANCED Historical lens (timeline reconstruction, fault-tree, git bisect; concurrent with Code Tracer) |
| `dso:investigator-escalated-web` | opus | `/dso:fix-bug` Phase D — ESCALATED Web Researcher (error pattern analysis, dependency changelogs, upstream issue correlation) |
| `dso:investigator-escalated-history` | opus | `/dso:fix-bug` Phase D — ESCALATED History Analyst (deep timeline reconstruction beyond ADVANCED depth) |
| `dso:investigator-escalated-code-tracer` | opus | `/dso:fix-bug` Phase D — ESCALATED Code Tracer (deep execution-path tracing, dependency-ordered analysis, state/concurrency inspection) |
| `dso:investigator-escalated-empirical` | opus | `/dso:fix-bug` Phase D — ESCALATED Empirical Agent (authorized to add temporary logging; veto authority over theoretical consensus) |
| `dso:huge-diff-reviewer-light` | opus | `REVIEW-WORKFLOW-HUGE.md` — large-refactor light tier (orchestrator path only; CI runner uses Strategy E region-split — see bug `7c1e-05b6-8f3a-418e` for the divergence) |
| `dso:huge-diff-reviewer-standard` | opus | `REVIEW-WORKFLOW-HUGE.md` — large-refactor standard tier (same orchestrator-only caveat as above) |
| `dso:huge-diff-refactor-anomaly` | opus | `REVIEW-WORKFLOW-HUGE.md` — anomalous-file conformance sweep when ≥5 of 7 sampled files share an identical transformation pattern (CONFIRMED_REFACTOR mode); same orchestrator-only caveat |
| `dso:code-reviewer-arbiter` | opus | `REVIEW-WORKFLOW.md` cycle-end + `arbiter_processor.py` — adjudicates severity disputes between reviewer and defense; trinary ruling (binding, no partial accepts) |
| `dso:code-reviewer-verifier` | opus | `REVIEW-WORKFLOW.md` — post-review absence-claim verification |
| `dso:architectural-probe` | opus | `/dso:brainstorm` — invoked via `scripts/run-architectural-probe.sh` for pattern probing |
| `dso:bug-classifier-haiku` | haiku | `/dso:debug-everything`, `/dso:fix-bug`, `/dso:brainstorm`, `/dso:sprint`, `/dso:end-session`, `/dso:onboarding` — bug type classification |
| `dso:schema-correction` | haiku | `dso_ci_review/runner.py:1974-2009` Step 7.5 — schema-fail recovery (corrects a reviewer's findings JSON to validate-clean) |

## Tiered review summary

Classifier scores 0–2 → light (haiku), 3–6 → standard (sonnet), 7+ → deep (3×sonnet + opus synthesis). 300+ lines → opus upgrade; 600+ lines → SIZE_WARNING (non-blocking, review proceeds); ≥20 files → routed to `REVIEW-WORKFLOW-HUGE.md`. Security, performance, and test quality overlays auto-dispatched when classifier flags them. Test quality overlay fires when the diff touches `tests/` files. Review dimensions: `correctness`, `verification`, `hygiene`, `design`, `maintainability`.

**Finding schema invariants**: each finding requires `cited_lines` (min 1 entry; format `<path>:<line>` or `~<path>:<line>`); severity calibration rubric and NOT-flag auto-downgrade rules defined in `reviewer-base.md`; CI dispatches prepend `REVIEW_CONTEXT: ci` to the user message.
