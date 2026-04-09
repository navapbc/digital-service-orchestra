# Claude Code Project Configuration

**Repo root**: Use `REPO_ROOT=$(git rev-parse --show-toplevel)` — all script paths below are relative to the repo root.

## Working Directory & Paths

**ALWAYS run `pwd` first** to confirm your working directory before running commands.

**Worktree sessions**: If in a worktree (`test -f .git`), use `REPO_ROOT=$(git rev-parse --show-toplevel)`. See `plugins/dso/docs/WORKTREE-GUIDE.md`.

## Quick Reference

| Action | Command |
|--------|---------|
| Onboard a new project | `/dso:onboarding` |
| Scaffold enforcement | `/dso:architect-foundation` |
| Run primary tickets end-to-end | `/dso:sprint` |
| Feature ideation to epic spec | `/dso:brainstorm` |
| Epic decomposition into stories | `/dso:preplanning` |
| Story to task breakdown | `/dso:implementation-plan` |
| Fix a bug (TDD-based) | `/dso:fix-bug` |
| Diagnose and fix failures | `/dso:debug-everything` |
| Commit with review gates | `/dso:commit` |
| Code review via sub-agent | `/dso:review` |
| Review plans/designs | `/dso:plan-review` |
| Update project docs | `/dso:update-docs` |
| Approve Figma design for a story | `plugins/dso/scripts/design-approve.sh <story-id>` |
| Clean session close | `/dso:end` |
| Full validation suite | `plugins/dso/scripts/validate.sh --ci` |
| Merge worktree to main | `plugins/dso/scripts/merge-to-main.sh` |
| List ready tickets | `.claude/scripts/dso ticket list` |
| Show ticket details | `.claude/scripts/dso ticket show <id>` |
| Create a ticket | `.claude/scripts/dso ticket create <type> <title> [-d/--description <text>] [--tags <tag>]` |
| Close a ticket | `.claude/scripts/dso ticket transition <id> <current> closed` (bug tickets require `--reason="Fixed: <summary>"`) |
| Link tickets | `.claude/scripts/dso ticket link <src> <tgt> <relation>` |
| Sync with Jira | `.claude/scripts/dso ticket sync` |
| Review event stats | `.claude/scripts/dso review-stats.sh` |
| Run a recipe transform | `.claude/scripts/dso recipe-executor.sh <recipe-name> [--param key=value ...]` |

Less common: `check-skill-refs.sh`, `qualify-skill-refs.sh`.

Priority: 0-4 (0=critical, 4=backlog). Never use "high"/"medium"/"low".

**Ticket type terminology**: `epic` = container for a feature area; `story` = user story (epic children, written as "As a [user], [goal]"); `task` = implementation work item. Ticket titles must be ≤ 255 characters (Jira sync limit).

## Architecture

**Ticket system v3 (event-sourced)**: Orphan branch `tickets` → `.tickets-tracker/`. CLI: `.claude/scripts/dso ticket <subcommand>` (ref: `plugins/dso/docs/ticket-cli-reference.md`). Archived tickets excluded from list/deps by default; `--include-archived` to override. **Jira bridge**: `.claude/scripts/dso ticket sync` (incremental default, `--full` to force, `--check` for dry-run). Requires `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`. The --tags flag sets tags atomically at creation time (comma-separated). The CLI_user tag marks bugs reported explicitly by a human during an interactive session; /dso:fix-bug Gate 1a skips the dso:intent-search dispatch for CLI_user-tagged bugs, setting GATE_1A_RESULT="intent-aligned" directly.
**Hook architecture**: Consolidated dispatchers (`pre-bash.sh` + `post-bash.sh`). All hooks are jq-free — use `parse_json_field`, `json_build`, and `python3` for JSON parsing. See `plugins/dso/hooks/dispatchers/` and `plugins/dso/hooks/lib/`. **Shared merge-state library** (`plugins/dso/hooks/lib/merge-state.sh`): centralizes merge/rebase detection for all enforcement hooks. `ms_` namespace. Fail-open when state is indeterminate. Test injection: set `_MERGE_STATE_GIT_DIR` before sourcing. See file for full API. **Review gate (two-layer)**: Layer 1 — `pre-commit-review-gate.sh` (git hook); Layer 2 — `review-gate.sh` (PreToolUse hook) blocks `--no-verify` and plumbing bypasses. Both layers handle MERGE_HEAD and REBASE_HEAD via `merge-state.sh`. See Never-Do rule 22. **Test gate**: `pre-commit-test-gate.sh` verifies test status per staged file. Centrality-aware (`record-test-status.sh`): high fan-in files trigger full suite. Use `--restart` to clear stale status when the test gate is stuck on a previous failed recording. Config: `test_gate.*` in `dso-config.conf`. `.test-index` maps source → tests; RED marker `[test_name]` tolerates failures at that boundary. **Status values**: `passed`, `failed`, `timeout`, `resource_exhaustion` (distinct from `failed`; written by `record-test-status.sh` when exit 254 + EAGAIN stderr pattern is detected). Severity hierarchy: `timeout > failed > resource_exhaustion > passed`. **EAGAIN retry**: `suite-engine.sh` detects exit 254 + EAGAIN stderr pattern in `_process_completed_test` and retries with `MAX_PARALLEL=1`; retry result is authoritative. `resource_exhaustion` is non-blocking at both fast-path and full-path checkpoints in `pre-commit-test-gate.sh` (emits warning to stderr). **Epic closure**: blocked while any `[marker]` entries remain in `.test-index`. **Brainstorm enforcement gate** (`pre-enterplanmode.sh`): PreToolUse hook blocks EnterPlanMode when no brainstorm sentinel exists (`$ARTIFACTS_DIR/brainstorm-sentinel`). Allowlist bypass via `$ARTIFACTS_DIR/active-skill-context` for non-feature workflows (fix-bug, debug-everything, sprint, implementation-plan, preplanning, resolve-conflicts, architect-foundation, retro). Config: `brainstorm.enforce_entry_gate` (default true). **Test quality gate** (`pre-commit-test-quality-gate.sh`): Pre-commit hook that detects anti-patterns in staged test files (source-file-grepping, tautological tests, change-detector tests, implementation-coupled assertions, existence-only assertions). Scoped to files matching `^tests/`. Config: `test_quality.enabled` (default `true`) and `test_quality.tool` (`bash-grep` | `semgrep` | `disabled`, default `bash-grep`). When `semgrep` is selected, uses rules at `plugins/dso/hooks/semgrep-rules/test-anti-patterns.yaml`. Graceful degradation: if Semgrep is not installed, gate disables rather than blocks. Timeout budget: 15 seconds.
**Review event observability**: Review events are appended as JSONL to `.review-events/` (one file per review session). Schema contract: `plugins/dso/docs/contracts/review-event-schema.md`. Emission scripts: `record-review.sh` (outcome events) and `review-stats.sh` (aggregation/query). Use `/dso:review-stats` to query review metrics.
**Validation gate**: `validate.sh` writes state; hooks block sprint/epic if validation hasn't passed. `--verbose` for real-time progress.
**Portability lint**: `check-portability.sh` (registered as pre-commit hook) blocks commits containing hardcoded `/Users/<name>/` or `/home/<name>/` paths. Inline suppression: append `# portability-ok` to exempt a line. CI validation: `.github/workflows/portability-smoke.yml` validates zero-config shim detection in a clean Ubuntu container.
**Shim enforcement**: `check-shim-refs.sh` (registered as pre-commit hook and in `validate.sh`) blocks instruction files inside `plugins/dso/` from containing direct plugin script references. Three detection patterns: (1) literal `plugins/dso/scripts/` path, (2) PLUGIN_SCRIPTS-prefixed script paths, (3) CLAUDE_PLUGIN_ROOT-prefixed script paths. Use `.claude/scripts/dso <script-name>` shim instead. Inline suppression: append `# shim-exempt: <reason>` to exempt a line.
**Contract schema validation**: `check-contract-schemas.sh` (registered as pre-commit hook and in `validate.sh`) enforces structural conformance on contract markdown files in `plugins/dso/docs/contracts/`. Universal rules: (1) level-1 heading starts with `# Contract:`, (2) `## Purpose` section present with non-empty content. Signal-contract-specific (when file contains `## Signal Format` or `## Signal Name`): (3) `### Canonical parsing prefix` section present. Scans `plugins/dso/docs/contracts/*.md` by default; accepts explicit file args for staged-file mode.
**Referential integrity check**: `check-referential-integrity.sh` (registered as pre-commit hook and in `validate.sh`) verifies that path references in skill/agent/workflow/prompt markdown files point to files that actually exist. Scanned pattern: `plugins/dso/(scripts|agents|docs)/[^\s]+\.(sh|py|md)`. Exclusions: lines with `# shim-exempt:` and paths inside fenced code blocks. Scans `plugins/dso/{skills,agents,docs/workflows,docs/prompts}/**/*.md` plus `CLAUDE.md` by default.
**Recipe registry and executor**: `recipes/recipe-registry.yaml` declares available recipes validated against `recipes/schemas/recipe-registry-schema.json` (JSON Schema Draft 7). CLI: `.claude/scripts/dso recipe-executor.sh <recipe-name> [--param key=value ...]`. Engine adapters live in `plugins/dso/scripts/recipe-adapters/`; supported engines: rope (Python AST), ts-morph (TypeScript AST), isort (Python imports), scaffold (file generation). Parameters are passed via RECIPE_PARAM_* env vars — never shell string interpolation. Transform recipes use git stash rollback on failure; generative recipes (`recipe_type: generative`) track and delete created files on failure.
**Agent routing**: `discover-agents.sh` resolves routing categories to agents via `agent-routing.conf`; all fall back to `general-purpose`. See `plugins/dso/docs/INSTALL.md`. **Named-agent dispatch** (via `subagent_type`, defined in `plugins/dso/agents/`):

| Agent | Model | Dispatched by |
|-------|-------|---------------|
| `dso:complexity-evaluator` | haiku | `/dso:sprint`, `/dso:brainstorm`; read inline by `/dso:fix-bug` |
| `dso:conflict-analyzer` | sonnet | `/dso:resolve-conflicts` |
| `dso:bot-psychologist` | sonnet | `/dso:fix-bug` llm-behavioral path (dispatched or read inline when sub-agent) |
| `dso:doc-writer` | sonnet | `/dso:sprint` (doc stories), `/dso:update-docs` |
| `dso:intent-search` | sonnet | `/dso:fix-bug` Step 1.5 (Gate 1a — pre-investigation intent search; skipped for CLI_user-tagged bugs) |
| `dso:feasibility-reviewer` | sonnet | `/dso:brainstorm` (conditional, on integration signals) |
| `dso:red-team-reviewer` | opus | `/dso:preplanning` Phase 2.5 |
| `dso:blue-team-filter` | sonnet | `/dso:preplanning` Phase 2.5 |
| `dso:completion-verifier` | sonnet | `/dso:sprint` story closure (Step 10a) + epic closure (Phase 7 Step 0.75) |
| `dso:red-test-writer` | sonnet | `/dso:sprint` Phase 5, `/dso:fix-bug` Step 5 |
| `dso:red-test-evaluator` | opus | On red-test-writer rejection (REVISE/REJECT/CONFIRM) |
| `dso:code-reviewer-light` | haiku | `/dso:review` (score 0–2) |
| `dso:code-reviewer-standard` | sonnet | `/dso:review` (score 3–6) |
| `dso:code-reviewer-deep-*` (3 agents) | sonnet | `/dso:review` (score 7+, parallel) |
| `dso:code-reviewer-deep-arch` | opus | `/dso:review` (score 7+, synthesis) |
| `dso:code-reviewer-security-red-team` | opus | `/dso:review` overlay — parallel when classifier flags `security_overlay:true`; serial when tier reviewer flags `security_overlay_warranted:yes` |
| `dso:code-reviewer-security-blue-team` | opus | `/dso:review` overlay — triages red team findings with dismiss/downgrade/sustain; dispatched after red team |
| `dso:code-reviewer-performance` | opus | `/dso:review` overlay — parallel when classifier flags `performance_overlay:true`; serial when tier reviewer flags `performance_overlay_warranted:yes` |
| `dso:code-reviewer-test-quality` | opus | `/dso:review` overlay — parallel when classifier flags `test_quality_overlay:true` (diff touches `tests/`); serial when tier reviewer flags `test_quality_overlay_warranted:yes`; detects 5 test bloat patterns against behavioral testing standard |
| `dso:approach-decision-maker` | opus | `/dso:implementation-plan` proposal resolution loop — evaluates distinct implementation proposals against 5 dimensions; emits `APPROACH_DECISION` signal (contract: `plugins/dso/docs/contracts/approach-decision-output.md`) |

**Agent fallback**: On dispatch failure, read `plugins/dso/agents/<agent-name>.md` inline (strip `dso:` prefix from `subagent_type`).
**Tiered review**: Classifier scores 0–2 → light (haiku), 3–6 → standard (sonnet), 7+ → deep (3×sonnet + opus synthesis). 300+ lines → opus upgrade; 600+ → rejection. Security, performance, and test quality overlays auto-dispatched when classifier flags them. Test quality overlay fires when the diff touches `tests/` files. Review dimensions: `correctness`, `verification`, `hygiene`, `design`, `maintainability`.
**Conflict avoidance** (multi-agent): Static file impact analysis, shared blackboard, agent discovery protocol, semantic conflict check — integrated into `/dso:sprint` and `/dso:debug-everything`.
**Usage-aware throttling** (`check-usage.sh` + `agent-batch-lifecycle.sh`): `check-usage.sh` polls the Claude OAuth usage endpoint, caches results (TTL: 5 min), and returns an exit code reflecting current consumption: `0` = unlimited (below throttle thresholds), `1` = throttled (high usage), `2` = paused (critical usage). `agent-batch-lifecycle.sh`'s `_compute_max_agents()` combines the usage verdict with the `orchestration.max_agents` config cap and `CLAUDE_CONTEXT_WINDOW_USAGE` to emit a `MAX_AGENTS` signal before each batch. Three-tier protocol: unlimited → dispatch up to `orchestration.max_agents` (or no cap when absent); throttled (90%/95% rolling 5hr/7day windows) → `MAX_AGENTS: 1`; paused (95%/98%) → `MAX_AGENTS: 0` (all dispatch halted). `_check_rate_limit_error()` provides error-reactive fallback: rate-limit errors during dispatch trigger an immediate re-evaluation and batch suspension. Config: `orchestration.max_agents` (integer or null; null = no cap).
**scrutiny:pending gate**: epics tagged with `scrutiny:pending` (via `/dso:roadmap` opt-out) are blocked at `/dso:preplanning` and `/dso:implementation-plan` entry until `/dso:brainstorm` is run. **Brainstorm non-epic support**: `/dso:brainstorm` accepts any ticket type; non-epics can convert-to-epic or enrich-in-place. **Epic scrutiny pipeline**: `/dso:brainstorm` Phase 2 invokes the shared scrutiny workflow at `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md` (gap analysis, web research, scenario analysis, fidelity review, prompt-alignment). **Part C (shared artifact impact analysis)**: Scrutiny pipeline Step 1 (Gap Analysis) scans the codebase for all files referencing artifact(s) being created or modified by the epic; triggers when the Success Criteria section references a file with 2+ external consumers; output is raw `(file_path, matching_line, covered_by_SC: true|false)` tuples passed directly to the Scope fidelity reviewer (not summarized by the brainstorm agent). **consumer_completeness fidelity dimension**: The Scope reviewer evaluates a `consumer_completeness` dimension using Part C's raw scan output — a score below 4 blocks the epic, same pass threshold as all other fidelity dimensions; scored N/A when Part C scan was skipped. **Follow-on epic scrutiny**: When brainstorm produces scope-splits, Phase 3 Step 0 invokes the scrutiny pipeline on each follow-on epic (depth cap: 1; follow-on-of-follow-on become ticket stubs). **Feasibility-resolution gate**: Scrutiny emits `FEASIBILITY_GAP` annotation for critical feasibility findings; brainstorm re-enters understanding loop bounded by `brainstorm.max_feasibility_cycles` (default 2); preplanning emits `REPLAN_ESCALATE: brainstorm` for unresolved gaps. **Prompt-alignment step (Step 5)**: Scrutiny pipeline detects LLM-instruction epics via canonical keyword list (skill files, agent definitions, prompt templates, hook behavioral logic); dispatches `dso:bot-psychologist` via Agent tool; doc-only epics excluded. **Value-effort scoring**: `plugins/dso/skills/shared/prompts/value-effort-scorer.md` provides a shared rubric for scoring epic value vs. effort, used by `/dso:roadmap` prioritization. **Prior-art search**: Before writing or modifying code, consult `plugins/dso/skills/shared/prompts/prior-art-search.md`. Tiered protocol: Tier 1 project docs → Tier 2 narrow codebase → Tier 3 broad search → Tier 4 user escalation. Routine exclusions: single-file logic fixes, formatting/lint, test reversions, doc-only edits, config value updates.
**Behavioral testing standard** (`plugins/dso/skills/shared/prompts/behavioral-testing-standard.md`): 5-rule standard consumed by all test-writing agents. Rules: (1) check existing coverage, (2) test observable behavior, (3) execute code and assert outcomes, (4) refactoring litmus test, (5) instruction files — test the structural boundary, not the content.
**Testing mode classification**: Implementation-plan and fix-bug emit `testing_mode` per task (RED: new behavior, GREEN: implementation-only, UPDATE: behavior change with coverage). Sprint routes tasks by testing_mode. Tasks without testing_mode default to RED (backward compatible).
**This repo is the `dso` plugin.** Invocation: `/dso:skill-name` (qualified, required) or `/skill-name` (alias). **Namespace policy**: in-scope files MUST use `/dso:<skill-name>` (enforced by `check-skill-refs.sh`). Host project shim: `.claude/scripts/dso <script-name>`. Config: `.claude/dso-config.conf` (KEY=VALUE; see file for keys).
**Re-invocation guard (implementation-plan)**: When `/dso:implementation-plan` is invoked on a story or epic that already has children, it classifies existing children as closed (read-only), in-progress (flagged for review), or open (candidate for revision) and produces a diff plan (new tasks for uncovered success criteria only) rather than duplicating tasks. Safe to re-invoke mid-implementation. When implementation-plan cannot satisfy success criteria given current codebase state, it emits `REPLAN_ESCALATE: brainstorm` (contract: `plugins/dso/docs/contracts/replan-escalate-signal.md`); the calling orchestrator must route to `/dso:brainstorm`. Cascade protocol: brainstorm revises the epic → preplanning re-runs to revise stories → implementation-plan re-runs to realign tasks; bounded by `sprint.max_replan_cycles` (`dso-config.conf`, default 2). **GAP_CLASSIFICATION** (contract: `plugins/dso/docs/contracts/gap-classification-output.md`): emitted by the gap-classification sub-agent in sprint Phase 7; each failing success criterion receives `intent_gap` (route to brainstorm with user confirmation) or `implementation_gap` (route to Phase 7 Step 1 bug-task creation — `ROUTING: implementation-plan` is a routing signal label, NOT a direct skill invocation) for autonomous remediation routing.
**Proposal generation and resolution loop (implementation-plan)**: Before task drafting, `/dso:implementation-plan` generates 3+ distinct implementation proposals. A distinctness gate verifies proposals differ on at least one structural axis (data layer, control flow, dependency graph, interface boundary). The `dso:approach-decision-maker` agent (opus, timeout: 600000) evaluates proposals and emits an `APPROACH_DECISION` signal (contract: `plugins/dso/docs/contracts/approach-decision-output.md`). Mode `selection` → adopt proposal and proceed to task drafting. Mode `counter_proposal` → incorporate feedback and re-enter proposal generation (max 2 cycles). After 2 cycles without selection, escalate to user.
**Sprint self-healing loop** (epic 9d3e-957d): `/dso:sprint` detects and routes mid-implementation gaps at four checkpoints — (1) **drift detection** (Phase 1 Step 6): `sprint-drift-check.sh` compares git history against story file impact tables; affected stories are re-routed through `implementation-plan` before batch execution; (2) **confidence signal routing** (Phase 5 Step 1a2): task-execution sub-agents emit `CONFIDENT` or `UNCERTAIN:<reason>` per task (contract: `plugins/dso/docs/contracts/confidence-signal.md`); 2+ `UNCERTAIN` signals per story re-invokes `implementation-plan` for re-planning (Phase 3 double-failure detection); (3) **validation failure routing** (Step 10a): all tasks closed but story validation fails → TDD remediation tasks via `implementation-plan`; (4) **out-of-scope review routing** (Steps 7a/13a): `sprint-review-scope-check.sh` identifies review findings for out-of-scope files → new tasks via `implementation-plan`. All re-planning events write `REPLAN_TRIGGER` / `REPLAN_RESOLVED` comments to the epic ticket (contract: `plugins/dso/docs/contracts/replan-observability.md`). Non-interactive mode writes `INTERACTIVITY_DEFERRED: brainstorm` instead of blocking for user input.
**Onboarding** (`/dso:onboarding`): Auto-detects project config before asking questions. Template gate for unknown frameworks (`plugins/dso/config/template-registry.yaml`). Phase 3 installs hooks, initializes ticket system, generates `.test-index`. Existing files show diff before overwrite. See SKILL.md.
**Architect-foundation** (`/dso:architect-foundation`): Reads `.claude/project-understanding.md` from onboarding; presents recommendations one-at-a-time; shows diffs before overwriting existing files.
**Figma design collaboration** (config-gated, `design.figma_collaboration=true`): When enabled, `/dso:design-wireframe` generates Figma-optimized SVG artifacts and tags the story `design:awaiting_import`. A human designer imports the SVG into Figma, exports a PNG, and runs `plugins/dso/scripts/design-approve.sh <story-id>` to record approval and tag the story `design:approved`. `/dso:sprint` filters `design:awaiting_import` stories from batch execution (emits `SKIPPED_DESIGN_AWAITING`) and passes the approved PNG path as `{design_context}` to task-execution sub-agents for pixel-accurate implementation. Stories tagged `design:desync` (exported PNG older than `design.figma_staleness_days`) are blocked at sprint Phase 2 until re-approved.
Config keys (`dso-config.conf`): `ci.workflow_name`, `merge.message_exclusion_pattern` (default `^chore: post-merge cleanup`), `version.file_path` (absent = skip bump), `debug.max_fix_validate_cycles` (default 3), `debug.intent_search_budget` (default 20), `sprint.max_replan_cycles` (default 2, cascade replan limit), `brainstorm.enforce_entry_gate` (default true, disables brainstorm-before-plan-mode enforcement when set to false), `worktree.isolation_enabled` (default true, enables per-sub-agent worktree sandboxing; set to false to fall back to shared-directory behaviour), `design.figma_collaboration` (default false; when true, design-wireframe generates Figma-optimized SVG and tags stories `design:awaiting_import`), `design.figma_staleness_days` (default 7; stories with approved PNG older than this trigger a `design:desync` staleness block), `test_quality.enabled` (default `true`; `false` disables the pre-commit test quality gate entirely), `test_quality.tool` (default `bash-grep`; `semgrep` uses `plugins/dso/hooks/semgrep-rules/test-anti-patterns.yaml`; `disabled` skips all checks), `implementation_plan.approach_resolution` (default `autonomous`; `autonomous` auto-accepts approach-decision-maker selections without user confirmation, `interactive` prompts the user before finalizing the selected approach), `brainstorm.max_feasibility_cycles` (default `2`; maximum re-entry cycles in the feasibility-resolution gate before escalating to the user). Merge-to-main phases: `sync → merge → version_bump → validate → push → archive → ci_trigger`; state file `/tmp/merge-to-main-state-<branch>.json` (4h TTL); `--resume` continues from checkpoint.


**Worktree lifecycle** (`claude-safe`): After Claude exits, `_offer_worktree_cleanup` auto-removes the worktree if: (1) branch is ancestor of main (`is_merged`), AND (2) `git status --porcelain` is empty (`is_clean`). No special filtering — `.tickets-tracker/` files block removal like any other dirty file. `/dso:end` ensures the worktree meets these criteria by: generating technical learnings (Step 2.8) and creating bug tickets (Step 2.85) before commit/merge, and verifying `is_merged` + `is_clean` (Step 4.75) before session summary.
**Worktree isolation** (`worktree.isolation_enabled`, default: true): Sprint, fix-bug, and debug-everything dispatch implementation sub-agents with `isolation: worktree`, giving each agent its own working directory. Orchestrator reviews and commits each worktree serially via `per-worktree-review-commit.md`, then merges into session branch. Auth-file allowlist pattern: orchestrator writes `/tmp/worktree-isolation-authorized-<uuid>` before dispatch; guard validates PID liveness. See `plugins/dso/skills/shared/prompts/worktree-dispatch.md`.

**File placement**: Design documents go in `plugins/dso/docs/designs/` — not bare `designs/` at repo root (review-gate blocks it).
**Browser automation**: Use `@playwright/cli` (`npx @playwright/cli test`) as the browser automation interface for E2E and visual regression tests. Install via `npm install --save-dev @playwright/cli`.

## Critical Rules

### Never Do These
1. **Never close tasks before CI passes** — fix if you broke it; create tracking issue if pre-existing.
2. **Never use `app/` in paths when CWD is `app/`** — use `src/`, `tests/` directly. When CWD is the repo root, `app/` prefix is required. `.claude/` is always at the repo root; plugin scripts are at `plugins/dso/scripts/`.
3. **Never skip issue validation after creating issues or adding deps** — run `validate-issues.sh --quick --terse`.
4. **Never exceed the usage-aware sub-agent cap** — `orchestration.max_agents` (`dso-config.conf`) sets the upper bound; when absent, `MAX_AGENTS` is unlimited. Throttle tiers override: 90%/95% (5hr/7day) usage → `MAX_AGENTS: 1`; 95%/98% → `MAX_AGENTS: 0` (pause all dispatch). Always check the effective cap before launching a batch.
5. **Never launch new sub-agent batch without committing previous batch's results** — #1 cause of lost work.
6. **Never assume sub-agent success without checking Task tool result**.
7. **Never leave issues `in_progress` without progress notes**.
8. **Never skip `git push` between sub-agent batches**.
9. **Never edit main repo files from a worktree session**.
10. **Never continue fixing after 5 cascading failures** — run `/dso:fix-cascade-recovery`.
11. **Never add a risky dependency without user approval** — see `plugins/dso/docs/DEPENDENCY-GUIDANCE.md`.
12. **Never manually call `record-review.sh`** — highest-priority integrity rule. Use `/dso:review`, which dispatches classifier-selected code-reviewer sub-agent(s) that write `reviewer-findings.json` (for deep tier, the opus arch agent is the sole writer of the final file). `record-review.sh` reads directly from that file — no orchestrator-constructed JSON is accepted. Fabrication regardless of intent. Enforced by the git pre-commit review gate (`pre-commit-review-gate.sh`).
13. **Never use raw `git commit`** — use `/dso:commit` or `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md`. Review gate blocks raw commits. **Orchestrators must read and execute `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md` inline — NEVER invoke `/dso:commit` via the Skill tool from within another workflow (sprint, debug-everything, etc.).**
14. **Never present a plan without `/dso:plan-review` first**. Do NOT use `/dso:review` for plans.
15. **Never override reviewer severity** — critical->1-2, important->3. Autonomous resolution via code-visible defense (R5) for up to `review.max_resolution_attempts` (default: 5) attempts; user escalation after. See REVIEW-WORKFLOW.md R1-R5.
16. **Never write/modify/delete `reviewer-findings.json`** — written by code-reviewer sub-agent only. Integrity verified via `--reviewer-hash`.
17. **Never edit `.github/workflows/` files via the GitHub API** — always edit workflow files in the worktree source and commit normally. API calls bypass review, hooks, and leave the worktree out of sync.
18. **Never edit safeguard files without task-level authorization** — protected: `plugins/dso/skills/**`, `plugins/dso/hooks/**`, `plugins/dso/docs/workflows/**`, `plugins/dso/scripts/**`, `CLAUDE.md`, `plugins/dso/hooks/lib/review-gate-allowlist.conf`, `plugins/dso/scripts/review-complexity-classifier.sh`. Task-level instructions that explicitly target a safeguard file ("update CLAUDE.md rule 18", "fix the pre-commit hook", "add step to SKILL.md") constitute authorization for that specific file. General instructions ("fix this bug", "implement this feature") that do not name the safeguard file do not authorize edits to it.
19. **Never autonomously close a bug without a code change** — escalate to the user if no code fix is possible. Use `.claude/scripts/dso ticket comment <id> "note"` to record findings. Only `.claude/scripts/dso ticket transition <id> <current> closed --reason="Fixed: <summary>"` after (a) a code change fixes it, or (b) the user explicitly authorizes closure (use `--reason="Escalated to user: <summary>"`). Bug tickets **require** the `--reason` flag with prefix `Fixed:` or `Escalated to user:` — omitting it causes a silent failure.
20. **Never make changes without a way to validate them** — this project strictly follows TDD. Every code change requires a corresponding test that fails before the change (RED) and passes after (GREEN). For non-code changes (skills, CLAUDE.md, agent guidance), define an eval or validation method before making the change. The `/dso:fix-bug` skill enforces this via the RED-before-fix gate (Step 5.5): no code modification until a RED test confirms the bug. Investigation results must include `hypothesis_tests` with confirmed/disproved/inconclusive verdicts before proceeding to fix implementation.
21. **Resolution sub-agents must NOT dispatch nested Task calls for re-review** — nesting (orchestrator → resolution → re-review) causes `[Tool result missing due to internal error]`. The orchestrator handles all re-review dispatching after the resolution sub-agent returns `RESOLUTION_RESULT`. See `plugins/dso/docs/workflows/prompts/review-fix-dispatch.md` NESTING PROHIBITION.
22. **Never bypass the review gate or use `--no-verify`** without explicit user approval. The review gate is two-layer: Layer 1 (git pre-commit hook) enforces allowlist + review-status + diff hash; Layer 2 (PreToolUse hook `review-gate.sh`) blocks `--no-verify`, `core.hooksPath=` overrides, and git plumbing commands. **`--no-verify` cannot bypass Layer 2** — it is a Claude Code tool-use hook, not a git hook, so `--no-verify` has no effect on it. When blocked, run the full commit workflow (`/dso:commit` or COMMIT-WORKFLOW.md). Rationalizing around it (e.g., "these are just docs", "this is trivial") is exactly the failure mode this gate prevents. Pre-commit hooks include format-check (Ruff) and lint (Ruff/MyPy); if hooks fail: `make format` for formatting, fix lint manually.
23. **Never run `make test-unit-only` or `make test-e2e` as a full-suite validation command** — these broad test commands exceed the ~73s tool timeout ceiling and will be killed mid-run (exit 144), producing spurious failures. Use `plugins/dso/scripts/validate.sh --ci` for full validation instead. Targeted single-test invocations (`poetry run pytest tests/unit/path/test_file.py::test_name`) remain allowed during edit-test iteration.
24. **Never skip `dso:completion-verifier` dispatch or substitute inline verification** — the orchestrator MUST dispatch the verifier sub-agent at story closure (Step 10a) and epic closure (Phase 7 Step 0.75). Inline verification is NOT a substitute — the verifier exists because the orchestrator is biased toward confirming its own work. Fallback applies ONLY on technical failure (timeout, unparseable JSON), not as permission to skip.
25. **Never edit files in the plugin cache** (`~/.claude/plugins/marketplaces/digital-service-orchestra/`) — always edit the corresponding files in the repo worktree (`plugins/dso/`). Plugin cache files are managed by the plugin system and will be overwritten on sync. Changes to plugin cache files are invisible to git, will not be committed, and will be lost.

### Architectural Invariants

These rules protect core structural boundaries. Violating them causes subtle bugs that are hard to trace.

1. **Prefer stdlib/existing dependencies over new packages** — new runtime dependencies require justification. Check `pyproject.toml` first; if equivalent functionality exists in stdlib or an already-imported library, use it. When a new package is genuinely needed, note why in the PR description and get user approval (see rule 11 in Never Do These).
2. **CLAUDE.md is for agent instructions, rules, and command references — not feature descriptions.** Feature and implementation documentation belongs in codebase-overview (consuming projects use `.claude/docs/DOCUMENTATION-GUIDE.md`).

### Always Do These
1. **Use `/dso:sprint` for primary tickets** — it runs `validate.sh --ci` automatically. For bug fixes, use `/dso:fix-bug`.
2. **Formatting runs automatically** via PostToolUse hook on `.py` edits (ruff). If a hook failure is reported, run `make format` manually.
3. **Create tracking issues** for ALL failures discovered, even "infrastructure" ones.
4. **Use the correct review tool:**

| Reviewing a... | Use | NOT this |
|----------------|-----|----------|
| Plan or design | `/dso:plan-review` | `/dso:review` |
| Completed code | `/dso:review` | `/dso:plan-review` |

5. **Use task status updates for step/phase progress — not text headers.** When executing a skill's numbered steps or phases, track progress through `TaskUpdate` (`in_progress` → `completed`) rather than printing headers like `**Step N: Description**` or `**Phase N: Description**` as visible text. Task status updates show in the spinner; narrating step/phase headers is redundant and clutters the user-visible output.
6. **Use WebSearch/WebFetch when facing significant tradeoffs** — before committing to an approach involving meaningful tradeoffs in testing, maintainability, readability, functionality, or usability, use WebSearch or WebFetch to research current best practices. See `plugins/dso/docs/RESEARCH-PATTERN.md` for when and how to apply this.
7. **During edit-test iteration, run targeted tests — not the full suite.** Use `poetry run pytest tests/unit/path/test_file.py::test_name --tb=short -q`. Final validation: `plugins/dso/scripts/validate.sh --ci`.
8. **Parallelize independent tool calls — always.** When issuing Read, Grep, Glob, or Bash calls with no data dependency between them, place them all in the same response so they run concurrently (e.g., two independent Read calls in one response; Grep + Glob for unrelated patterns). Never serialize calls that could be parallel.
9. **When fixing a bug, search for the same anti-pattern elsewhere.** After fixing a bug, search the codebase for other code that follows the same anti-pattern you just fixed. Create a bug ticket (`.claude/scripts/dso ticket create bug "<title>"`) for each occurrence found so they can be tracked and fixed systematically.
10. **Write a failing test to verify your CI/staging bug hypothesis before fixing.** When diagnosing a CI or staging failure, write a unit or integration test that reproduces the suspected root cause FIRST. Run it to confirm it fails (RED). Only then implement the fix and verify the test passes (GREEN). This prevents fixing symptoms instead of causes and guards against the fix being wrong.
11. **Always set `timeout: 600000` on Bash calls expected to exceed 30s AND on all Bash calls during commit/review workflows.** Without it, the timeout ceiling drops from ~73s to ~48s. Known slow commands: `validate.sh --ci`, `make test`, `.claude/scripts/dso ticket sync`. Even fast commands during commit/review can receive SIGURG (exit 144) from tool-call cancellation (see INC-016).
12. **Use `test-batched.sh` for running tests.** Runners: `bash` (test-*.sh), `node` (*.test.js), `pytest`. Prefer `--runner=bash --test-dir=<dir>` for bash suites. Run the printed `RUN:` command in subsequent Bash calls until summary appears. Do NOT use `while` polling loops (killed by ~73s ceiling). See INC-016 in KNOWN-ISSUES.md.
13. **When a user explicitly requests a bug ticket during interactive conversation (e.g., 'create a ticket for this'), include `--tags CLI_user` in the `.claude/scripts/dso ticket create bug` command.** Do NOT use `--tags CLI_user` for autonomously-discovered bugs (anti-pattern scans in Step 7.5, debug-everything discoveries, or any ticket created without explicit user request).
14. **When using external API model IDs, tool versions, or service identifiers, verify against authoritative sources before using them.** Run discovery commands (`--help`, `--list-models`, API endpoints), check official documentation, or search for confirmed working examples. Never guess or hallucinate identifiers — even plausible-looking IDs like `claude-sonnet-4-6-20260320` may not exist. Prior knowledge of model ID formats is unreliable; always verify empirically.
15. **When creating a new `.sh` file, always set the executable bit.** Run `chmod +x <file>` immediately after creating any shell script. The test gate and pre-commit hooks skip non-executable `.sh` files, causing silent test coverage gaps.

## Task Start Workflow

**Worktree session setup**: See `plugins/dso/docs/WORKTREE-GUIDE.md` (Session Setup section).

**Primary tickets**: Use `/dso:sprint` — it runs `plugins/dso/scripts/validate.sh --ci` automatically and blocks until the codebase is healthy.
**Bug fixes**: Use `/dso:fix-bug` — TDD-based; investigates before fixing.
**Docs, research**: Start directly. Validation runs at commit time for code changes (skipped for docs-only commits).
**Before `/dso:debug-everything`**: Run `plugins/dso/scripts/estimate-context-load.sh debug-everything`. If static load >10,000 tokens, trim `MEMORY.md` before starting to avoid premature compaction.
**`/dso:debug-everything` two-mode flow**: When open bug tickets exist, it enters Bug-Fix Mode — reads `/dso:fix-bug` SKILL.md inline at orchestrator level (preserving Agent tool access) and applies it to each open ticket, then runs Validation Mode (inner fix→validate loop, bounded by `debug.max_fix_validate_cycles`, default 3). When no open bugs exist, it runs the diagnostic scan (Phase 1) → triage sub-agent (Phase 2) → fix pipeline. Interactivity is declared at session start; non-interactive mode defers user-blocking gates as `INTERACTIVITY_DEFERRED` ticket comments instead of pausing. Complexity evaluation happens post-investigation in `/dso:fix-bug` (Step 4.5), after the bug is fully understood — not pre-investigation in `/dso:debug-everything`.
**`/dso:fix-bug` Sub-Agent Context Detection** — primary method: Agent tool availability check (if Agent tool is unavailable, skill is in sub-agent context). Fallback: orchestrator signal `You are running as a sub-agent` in dispatch prompt.

## Plan Mode Post-Approval Workflow

After ExitPlanMode approval, do NOT begin implementation. Create a ticket epic (`.claude/scripts/dso ticket create epic "<title>"`), then invoke `/dso:preplanning` on it to decompose into user stories, validate issue health, report the dependency graph, then **STOP and wait**. Do NOT prompt to clear context. See `plugins/dso/docs/PLAN-APPROVAL-WORKFLOW.md`.

## Task Completion Workflow (Orchestrator/main session only — does NOT apply inside sub-agents)

```bash
# 1. /dso:commit — auto-runs /dso:review if needed, then commits. Fix issues and re-run if review fails.
#    Review uses autonomous resolution (review.max_resolution_attempts fix/defend attempts before user escalation, default: 5).
#    On attempt 2+, /dso:oscillation-check runs automatically if same files targeted.
# 2. git push (or plugins/dso/scripts/merge-to-main.sh in worktree sessions — handles .claude/scripts/dso ticket sync + merge + push)
#    Supports --resume (continue from last state file checkpoint).
#    Phases: sync → merge → version_bump → validate → push → archive → ci_trigger
#    State file: /tmp/merge-to-main-state-<branch>.json (expires after 4h); lock file: /tmp/merge-to-main-lock-<hash>
#    On interruption (SIGURG), current phase is saved to state file — re-run with --resume to continue.
# 3. plugins/dso/scripts/ci-status.sh --wait — must return "success"
# 4. .claude/scripts/dso ticket transition <id> <current> closed --reason="Fixed: <summary>"  # bug tickets require --reason
```

**Session close**: Use `/dso:end`.

## Multi-Agent Orchestration

**Sub-agent boundaries**: See `plugins/dso/docs/SUB-AGENT-BOUNDARIES.md` for all sub-agent rules (prohibited/required/permitted actions, checkpoint protocol, report format, model selection, recovery).
**Sub-agent guard pattern**: Skills that require the Agent tool or direct user interaction contain a `<SUB-AGENT-GUARD>` block at the top of their `SKILL.md`. When invoked in sub-agent context (via Task tool), the guard instructs the agent to stop immediately and return an error. Two guard variants exist: (1) **Agent tool check** — for skills that dispatch sub-agents (sprint, debug-everything, brainstorm, preplanning, implementation-plan, design-wireframe, design-review, roadmap, plan-review, review-protocol, resolve-conflicts, architect-foundation, validate-work, retro, ui-discover); (2) **Orchestrator signal check** — for skills that require user interaction (end-session, onboarding). Tests: `tests/hooks/test-sub-agent-guard.sh`.

Orchestrator-level models: `haiku` (structured I/O), `sonnet` (code gen, review), `opus` (architecture, high-blast-radius); escalate on failure. Recovery: `.claude/scripts/dso ticket list` + `.claude/scripts/dso ticket show <id>` to read CHECKPOINT notes → `git log --oneline -5 && git status --short` for git state.

## Context Efficiency

**After editing a file**: Do not re-read the entire file to verify. The Edit tool confirms success. Use `Read` with `offset`/`limit` for surrounding context if needed.
**After reading a workflow file**: If already read earlier in this conversation (and not compacted since), use the version in context.
**Use built-in Grep and Read tools — not Bash equivalents**: Bash `grep`/`cat` only when piping to other commands or in scripts.

## Structural Code Search (ast-grep)

**Prefer `sg` (ast-grep) over text grep for cross-file dependency discovery** — syntax-aware, distinguishes real references from comments. Binary: `sg`. Check availability: `command -v sg`. When unavailable, fall back to Grep tool. Guard pattern: `if command -v sg >/dev/null 2>&1; then sg ...; else grep ...; fi`.

## Common Fixes

See .claude/docs/KNOWN-ISSUES.md for common operational fixes and workarounds.

**Before debugging**: Search the consuming project's `KNOWN-ISSUES.md` first (if available). After solving: add to it (3+ similar incidents → propose CLAUDE.md rule).
