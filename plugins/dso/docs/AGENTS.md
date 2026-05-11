# DSO Named-Agent Routing Reference

The full table of named sub-agents, their default model tier, and the workflow that dispatches them. CLAUDE.md keeps only the high-frequency rows; this file is the authoritative reference.

## Dispatch protocol

Agent files live in `${CLAUDE_PLUGIN_ROOT}/agents/`. The `dso:*` labels below are agent file identifiers (strip `dso:` prefix to get the filename).

- Use `subagent_type: "dso:<name>"` directly when the agent is registered in the Agent tool's available types list (check the session's available `subagent_type` list at startup).
- Fall back to `subagent_type: "general-purpose"` with the agent file loaded verbatim only when the named type is not registered.
- See `REVIEW-WORKFLOW.md` Step 4 for the canonical dispatch block.
- `discover-agents.sh` resolves routing categories to agents via `agent-routing.conf`; all fall back to `general-purpose`.

## Agents

| Agent | Model | Dispatched by |
|-------|-------|---------------|
| `dso:complexity-evaluator` | haiku | `/dso:sprint`, `/dso:preplanning`; read inline by `/dso:fix-bug` |
| `dso:conflict-analyzer` | sonnet | `/dso:resolve-conflicts` |
| `dso:cross-epic-interaction-classifier` | haiku | `/dso:brainstorm` (cross-epic scan step — dispatched in batches of 20 open epics via cross-epic-scan.md prompt; emits interaction_signals JSON with 4-tier severity) |
| `dso:bot-psychologist` | sonnet | `/dso:fix-bug` llm-behavioral path (dispatched or read inline when sub-agent) |
| `dso:doc-writer` | sonnet | `/dso:sprint` (doc stories), `/dso:update-docs` |
| `dso:intent-search` | sonnet | `/dso:fix-bug` Phase B Step 1 (Intent Gate — pre-investigation intent search; skipped for CLI_user-tagged bugs); emits INTENT_CONFLICT signal when callers depend on current behavior |
| `dso:scope-drift-reviewer` | sonnet | `/dso:fix-bug` Phase F Step 1 (scope-drift review after fix verification; skipped when `scope_drift.enabled=false`) |
| `dso:feasibility-reviewer` | sonnet | `/dso:brainstorm` (conditional, on integration signals) |
| `dso:red-team-reviewer` | opus | `/dso:preplanning` Phase E |
| `dso:blue-team-filter` | sonnet | `/dso:preplanning` Phase E |
| `dso:completion-verifier` | sonnet | `/dso:sprint` story closure (Step 10a) + epic closure (Phase 7 Step 0.75) |
| `dso:red-test-writer` | sonnet | `/dso:sprint` Phase 5, `/dso:fix-bug` Phase E Step 1 |
| `dso:red-test-evaluator` | opus | On red-test-writer rejection (REVISE/REJECT/CONFIRM) |
| `dso:code-reviewer-light` | haiku | `/dso:review` (score 0–2) |
| `dso:code-reviewer-standard` | sonnet | `/dso:review` (score 3–6) |
| `dso:code-reviewer-deep-*` (3 agents) | sonnet | `/dso:review` (score 7+, parallel) |
| `dso:code-reviewer-deep-arch` | opus | `/dso:review` (score 7+, synthesis) |
| `dso:code-reviewer-security-red-team` | opus | `/dso:review` overlay — parallel when classifier flags `security_overlay:true`; serial when tier reviewer flags `security_overlay_warranted:yes` |
| `dso:code-reviewer-security-blue-team` | opus | `/dso:review` overlay — triages red team findings with dismiss/downgrade/sustain; dispatched after red team |
| `dso:code-reviewer-performance` | opus | `/dso:review` overlay — parallel when classifier flags `performance_overlay:true`; serial when tier reviewer flags `performance_overlay_warranted:yes` |
| `dso:code-reviewer-test-quality` | opus | `/dso:review` overlay — parallel when classifier flags `test_quality_overlay:true` (diff touches `tests/`); serial when tier reviewer flags `test_quality_overlay_warranted:yes`; detects 5 test bloat patterns against behavioral testing standard |
| `dso:approach-decision-maker` | opus | `/dso:implementation-plan` proposal resolution loop — evaluates distinct implementation proposals against 5 dimensions; emits `APPROACH_DECISION` signal (contract: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/approach-decision-output.md`) |
| `dso:ui-designer` | sonnet | `/dso:preplanning` Step 6 — creates design artifacts (spatial layout, SVG wireframe, token overlay, manifest) for UI stories via Agent tool dispatch; returns `UI_DESIGNER_PAYLOAD` (contract: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/ui-designer-payload.md`) |
| `dso:plan-review` | sonnet | `/dso:plan-review` — evaluates implementation plans and design artifacts on feasibility, completeness, YAGNI, and codebase alignment before the user sees them |
| `dso:bloat-blue-team` | opus | `/dso:remediate` — evaluates probabilistic bloat candidates, classifying as CONFIRM/DISMISS/NEEDS_HUMAN with asymmetric error policy (defaults to DISMISS when uncertain) |
| `dso:bloat-resolver` | opus | `/dso:remediate` Path B (auto-resolve) — applies confirmed bloat removals with dependency checks before each deletion |
| `dso:inference-incident-curator` | opus | `/dso:brainstorm` SC4 dogfooding (runnable quarterly) — scans ticket history for inference incidents and emits JSONL corpus records (contract: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/inference-incident-schema.md`) |

## Tiered review summary

Classifier scores 0–2 → light (haiku), 3–6 → standard (sonnet), 7+ → deep (3×sonnet + opus synthesis). 300+ lines → opus upgrade; 600+ lines → SIZE_WARNING (non-blocking, review proceeds); ≥20 files → routed to `REVIEW-WORKFLOW-HUGE.md`. Security, performance, and test quality overlays auto-dispatched when classifier flags them. Test quality overlay fires when the diff touches `tests/` files. Review dimensions: `correctness`, `verification`, `hygiene`, `design`, `maintainability`.

**Finding schema invariants**: each finding requires `cited_lines` (min 1 entry; format `<path>:<line>` or `~<path>:<line>`); severity calibration rubric and NOT-flag auto-downgrade rules defined in `reviewer-base.md`; CI dispatches prepend `REVIEW_CONTEXT: ci` to the user message.
