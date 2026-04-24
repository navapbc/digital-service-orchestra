# Claude Code Project Configuration

You are a Principal Software Developer at a company like Google or USDS. You are a steward of this codebase; you are invested in the overall quality of the codebase, not just your changes. TAKE YOUR TIME and FIX PREEXISTING ISSUES you encounter.

**Repo root**: Use `REPO_ROOT=$(git rev-parse --show-toplevel)` — all script paths below are relative to the repo root.

## Working Directory & Paths

**Worktree sessions**: If in a worktree (`test -f .git`), use `REPO_ROOT=$(git rev-parse --show-toplevel)`. See `plugins/dso/docs/WORKTREE-GUIDE.md`.

## Quick Reference

| Action | Command |
|--------|---------|
| Run primary tickets end-to-end | `/dso:sprint` |
| Feature ideation to epic spec | `/dso:brainstorm` |
| Epic decomposition into stories | `/dso:preplanning` |
| Story to task breakdown | `/dso:implementation-plan` |
| Fix a bug (TDD-based) | `/dso:fix-bug` |
| Diagnose and fix failures | `/dso:debug-everything` |
| Commit with review gates | `/dso:commit` |
| Code review via sub-agent | `/dso:review` |
| Update project docs | `/dso:update-docs` |
| Approve Figma design for a story | `.claude/scripts/dso design-approve.sh <story-id>` |
| Re-sync Figma design to manifest (pull-back) | `python3 plugins/dso/scripts/figma-resync.py <ticket-id> [--non-interactive]` |
| Clean session close | `/dso:end-session` |
| Full validation suite | `.claude/scripts/dso validate.sh [--ci]` |
| Merge worktree to main | `.claude/scripts/dso merge-to-main.sh [--resume]` |
| Harvest worktree to session | `.claude/scripts/dso harvest-worktree <branch> <artifacts-dir>` |
| List ready tickets | `.claude/scripts/dso ticket list` |
| Show ticket details | `.claude/scripts/dso ticket show <id>` |
| Create a ticket | `.claude/scripts/dso ticket create <type> <title> [--description <text>] [--tags <tag>] [--parent <parent>] [--priority <priority>]` |
| Close a ticket | `.claude/scripts/dso ticket transition <id> <current-status> closed` (bug tickets require `--reason="Fixed: <summary>"`) |
| Link tickets | `.claude/scripts/dso ticket link <src> <tgt> <relation>` |
| Add tag to a ticket | `.claude/scripts/dso ticket tag <id> <tag>` |
| Remove tag from a ticket | `.claude/scripts/dso ticket untag <id> <tag>` |
| Review event stats | `.claude/scripts/dso review-stats.sh` |
| Run a recipe transform | `.claude/scripts/dso recipe-executor.sh <recipe-name> [--param key=value ...]` |
| Sync stale host-project artifacts to current plugin version | `.claude/scripts/dso update-artifacts` |
| Cut a plugin release (stable channel) | `scripts/release.sh` |

Less common: `check-skill-refs.sh`, `qualify-skill-refs.sh`.

Priority: 0-4 (0=critical, 4=backlog). Never use "high"/"medium"/"low".

**Ticket type terminology**: `epic` = container for a feature area; `story` = user story (epic children, written as "As a [user], [goal]"); `task` = implementation work item. Ticket titles must be ≤ 255 characters (Jira sync limit).

## Architecture

**DSO NextJS template repo**: `navapbc/digital-service-orchestra-nextjs-template` is the live template the `scripts/create-dso-app.sh` installer clones. Apache-2.0 attribution to upstream `navapbc/template-application-nextjs` is preserved in the template's NOTICE file. Real-URL e2e validation lives at `tests/scripts/test-create-dso-app-real-url.sh` (opt-in via `RUN_REAL_URL_E2E=1`; runs daily in CI). Interface contract: `docs/designs/create-dso-app-template-contract.md`.

**Ticket system v3 (event-sourced)**: Orphan branch `tickets` → `.tickets-tracker/`. CLI: `.claude/scripts/dso ticket <subcommand>` (ref: `plugins/dso/docs/ticket-cli-reference.md`). Archived tickets excluded from list/deps by default; `--include-archived` to override. The --tags flag sets tags atomically at creation time (comma-separated). The CLI_user tag marks bugs reported explicitly by a human during an interactive session; See `plugins/dso/docs/ticket-cli-reference.md` for full rules and examples. The dispatcher routes all subcommand calls through `ticket-lib-api.sh` (bash-native sourced library) by default; set `DSO_TICKET_LEGACY=1` to roll back to legacy per-op `.sh` subprocess scripts (debugging/rollback only).
**Suggestion capture**: `suggestion-record.sh` records agent friction/suggestions as immutable JSON files to `.tickets-tracker/.suggestions/`; fields include `source`, `observation`, `recommendation`, `skill_name`, `affected_file`, and `metrics`. 
**Review gate (two-layer)**: Layer 1 — `pre-commit-review-gate.sh` (git hook); Layer 2 — `review-gate.sh` (PreToolUse hook) blocks `--no-verify` and plumbing bypasses. Both layers handle MERGE_HEAD and REBASE_HEAD via `merge-state.sh`. 
**Test gate**: `pre-commit-test-gate.sh` verifies test status per staged file. Centrality-aware (`record-test-status.sh`): high fan-in files trigger full suite. Use `--restart` to clear stale status when the test gate is stuck on a previous failed recording. Config: `test_gate.*` in `dso-config.conf`. `.test-index` maps source → tests; RED marker format: `tests/foo.sh [test_name]` (space before bracket required) tolerates intentionally failing RED tests at/after that boundary. **Test gate Status values**: `passed`, `failed`, `timeout`, `resource_exhaustion` (distinct from `failed`; written by `record-test-status.sh` when exit 254 + EAGAIN stderr pattern is detected). Severity hierarchy: `timeout > failed > resource_exhaustion > passed`. 
**Test quality gate** (`pre-commit-test-quality-gate.sh`): Pre-commit hook that detects anti-patterns in staged test files (source-file-grepping, tautological tests, change-detector tests, implementation-coupled assertions, existence-only assertions). Scoped to files matching `^tests/`. Config: `test_quality.enabled` (default `true`) and `test_quality.tool` (`bash-grep` | `semgrep` | `disabled`, default `bash-grep`). When `semgrep` is selected, uses rules at `plugins/dso/hooks/semgrep-rules/test-anti-patterns.yaml`. Timeout budget: 15 seconds.
**Pre-commit hooks** (self-enforcing — print errors with fix instructions): `check-portability.sh` (hardcoded paths; suppress: `# portability-ok`), `check-shim-refs.sh` (direct plugin script refs; suppress: `# shim-exempt: <reason>`; use `.claude/scripts/dso <script-name>` shim instead), `check-contract-schemas.sh` (contract markdown structure), `check-referential-integrity.sh` (dead path references in instruction files), `check-plugin-self-ref.sh` (blocks all `plugins/dso/` literal paths in plugin scripts — no suppression annotation exists; use `_PLUGIN_ROOT` / `_PLUGIN_GIT_PATH` instead).
**Hook error handler** (`plugins/dso/hooks/lib/hook-error-handler.sh`): Shared ERR/EXIT trap library for non-enforcement hooks. Usage: source with a fail-open guard, then call `_dso_register_hook_err_handler "hook-name.sh"`. Errors are logged to `~/.claude/logs/dso-hook-errors.jsonl` (fail-open: handler always exits 0, never blocks hook execution). Enforcement hooks (annotated `# hook-boundary: enforcement`) MUST NOT source this library — `pre-commit-enforcement-boundary-check.sh` enforces this boundary at commit time.
**Agent routing**: `discover-agents.sh` resolves routing categories to agents via `agent-routing.conf`; all fall back to `general-purpose`. See `INSTALL.md`. **Named-agent dispatch** (agent files in `plugins/dso/agents/`): the `dso:*` labels below are **agent file identifiers** (strip `dso:` prefix to get filename). They are NOT valid `subagent_type` values — the Agent tool only accepts built-in types (`general-purpose`, `Explore`, `Plan`). Dispatch pattern: use `subagent_type: "general-purpose"`, load `plugins/dso/agents/<name>.md` verbatim as the prompt, and use the `model:` from that file's frontmatter. See REVIEW-WORKFLOW.md Step 4 for the canonical dispatch block.

| Agent | Model | Dispatched by |
|-------|-------|---------------|
| `dso:complexity-evaluator` | haiku | `/dso:sprint`, `/dso:brainstorm`; read inline by `/dso:fix-bug` |
| `dso:conflict-analyzer` | sonnet | `/dso:resolve-conflicts` |
| `dso:cross-epic-interaction-classifier` | haiku | `/dso:brainstorm` (cross-epic scan step — dispatched in batches of 20 open epics via cross-epic-scan.md prompt; emits interaction_signals JSON with 4-tier severity) |
| `dso:bot-psychologist` | sonnet | `/dso:fix-bug` llm-behavioral path (dispatched or read inline when sub-agent) |
| `dso:doc-writer` | sonnet | `/dso:sprint` (doc stories), `/dso:update-docs` |
| `dso:intent-search` | sonnet | `/dso:fix-bug` Step 1.5 (Gate 1a — pre-investigation intent search; skipped for CLI_user-tagged bugs); emits INTENT_CONFLICT signal when callers depend on current behavior |
| `dso:scope-drift-reviewer` | sonnet | `/dso:fix-bug` Step 7.1 (scope-drift review after fix verification; skipped when `scope_drift.enabled=false`) |
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
| `dso:ui-designer` | sonnet | `/dso:preplanning` Step 6 — creates design artifacts (spatial layout, SVG wireframe, token overlay, manifest) for UI stories via Agent tool dispatch; returns `UI_DESIGNER_PAYLOAD` (contract: `plugins/dso/docs/contracts/ui-designer-payload.md`) |
| `dso:plan-review` | sonnet | `/dso:plan-review` — evaluates implementation plans and design artifacts on feasibility, completeness, YAGNI, and codebase alignment before the user sees them |
| `dso:bloat-blue-team` | opus | `/dso:remediate` — evaluates probabilistic bloat candidates, classifying as CONFIRM/DISMISS/NEEDS_HUMAN with asymmetric error policy (defaults to DISMISS when uncertain) |
| `dso:bloat-resolver` | opus | `/dso:remediate` Path B (auto-resolve) — applies confirmed bloat removals with dependency checks before each deletion |

**Tiered review**: Classifier scores 0–2 → light (haiku), 3–6 → standard (sonnet), 7+ → deep (3×sonnet + opus synthesis). 300+ lines → opus upgrade; 600+ lines → SIZE_WARNING (non-blocking, review proceeds); ≥20 files → routed to REVIEW-WORKFLOW-HUGE.md. Security, performance, and test quality overlays auto-dispatched when classifier flags them. Test quality overlay fires when the diff touches `tests/` files. Review dimensions: `correctness`, `verification`, `hygiene`, `design`, `maintainability`.
**Conflict avoidance** (multi-agent): Static file impact analysis, shared blackboard, agent discovery protocol, semantic conflict check — integrated into `/dso:sprint` and `/dso:debug-everything`.
**Usage-aware throttling** (`check-usage.sh` + `agent-batch-lifecycle.sh`): `check-usage.sh` polls the Claude OAuth usage endpoint, caches results (TTL: 5 min), and returns an exit code reflecting current consumption: `0` = unlimited (below throttle thresholds), `1` = throttled (high usage), `2` = paused (critical usage). `agent-batch-lifecycle.sh`'s `_compute_max_agents()` combines the usage verdict with the `orchestration.max_agents` config cap and `CLAUDE_CONTEXT_WINDOW_USAGE` to emit a `MAX_AGENTS` signal before each batch. Three-tier protocol: unlimited → dispatch up to `orchestration.max_agents` (or no cap when absent); throttled (90%/95% rolling 5hr/7day windows) → `MAX_AGENTS: 1`; paused (95%/98%) → `MAX_AGENTS: 0` (all dispatch halted). `_check_rate_limit_error()` provides error-reactive fallback: rate-limit errors during dispatch trigger an immediate re-evaluation and batch suspension. Config: `orchestration.max_agents` (integer or null; null = no cap).
**scrutiny:pending gate**: epics tagged with `scrutiny:pending` (via `/dso:roadmap` opt-out) are blocked at `/dso:preplanning` and `/dso:implementation-plan` entry until `/dso:brainstorm` is run. 
**Brainstorm non-epic support**: `/dso:brainstorm` accepts any ticket type; non-epics can convert-to-epic or enrich-in-place. 
**Epic scrutiny pipeline**: See brainstorm SKILL.md and `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md`. Scrutiny emits `FEASIBILITY_GAP` for critical findings; preplanning emits `REPLAN_ESCALATE: brainstorm` for unresolved gaps. 
**Value-effort scoring**: `plugins/dso/skills/shared/prompts/value-effort-scorer.md` — shared rubric for epic value vs. effort, used by `/dso:roadmap`.
**Prior-art search**: Before writing or modifying code, consult `plugins/dso/skills/shared/prompts/prior-art-search.md`. Routine exclusions: single-file logic fixes, formatting/lint, test reversions, doc-only edits, config value updates.
**Behavioral testing standard** (`plugins/dso/skills/shared/prompts/behavioral-testing-standard.md`): 5-rule standard consumed by all test-writing agents. Rules: (1) check existing coverage, (2) test observable behavior, (3) execute code and assert outcomes, (4) refactoring litmus test, (5) instruction files — test the structural boundary, not the content.
**Testing mode classification**: Implementation-plan and fix-bug emit `testing_mode` per task (RED: new behavior, GREEN: implementation-only, UPDATE: behavior change with coverage). Sprint routes tasks by testing_mode. Tasks without testing_mode default to RED (backward compatible).
**Namespace policy**: in-scope files MUST use `/dso:<skill-name>` (enforced by `check-skill-refs.sh`). Host project shim: `.claude/scripts/dso <script-name>`. Config: `.claude/dso-config.conf` (KEY=VALUE; see file for keys).
**Plugin path pattern**: All plugin scripts use `_PLUGIN_ROOT` (resolved via `BASH_SOURCE` / `readlink`) for filesystem access (sourcing libs, reading config). For git commands that need repo-relative paths, derive `_PLUGIN_GIT_PATH` from `_PLUGIN_ROOT` relative to `git rev-parse --show-toplevel`. Never hardcode `plugins/dso/` in scripts — use these variables so the plugin works in any install location.
**GAP_CLASSIFICATION** (contract: `plugins/dso/docs/contracts/gap-classification-output.md`): `intent_gap` → brainstorm (with user confirmation), `implementation_gap` → remediation (`ROUTING: implementation-plan` is a signal label, NOT a direct skill invocation).
**Figma design collaboration** (config-gated, `design.figma_collaboration`; default false): Sprint filters `design:awaiting_import` stories from batch execution. See sprint SKILL.md and preplanning SKILL.md for details. **Pull-back workflow**: when a story has `design:awaiting_review`, run `figma-resync.py <ticket-id>` to pull Figma changes via REST API (requires `design.figma_pat` or `FIGMA_PAT` env var), merge visual updates into the 3-artifact manifest (spatial-layout.json, wireframe.svg, tokens.md) while preserving behavioral specs, confirm with the designer, then swap tag to `design:approved`. Use `--non-interactive` in CI. The merge uses an advisory file lock (30-min TTL, stale-lock auto-cleanup) to prevent concurrent re-syncs on the same ticket. Schema fields added by pull-back: `designer_added` (boolean) and `behavioral_spec_status` (COMPLETE/INCOMPLETE/PENDING) on each component in spatial-layout.json. **Manual review tag**: `manual:awaiting_user` marks stories blocked on human input outside the Figma workflow (e.g., access credentials, stakeholder decisions).
**External Dependencies planning** (config-gated, `planning.external_dependency_block_enabled`; default off): When enabled, `/dso:brainstorm` Phase 1 runs an External Dependencies shape heuristic and classification dialogue; Phase 2 approval gate checks for contradiction resolution. Stories with `handling=user_manual` become `manual:awaiting_user`-tagged stories handled via the Phase 3.5 manual-pause handshake in sprint. Contract: `plugins/dso/docs/contracts/external-dependencies-block.md`. Config: `planning.verification_command_timeout_seconds` (default 30s).
**Stack-agnostic gate pipeline**: `validate.sh`, `gate-2b`, `gate-2d`, and `auto-format.sh` read `commands.lint`, `commands.format`, and `commands.format_check` from config — replacing hardcoded Python/ruff calls. When a key is absent, each script emits `[DSO WARN]` and falls back gracefully (ruff for `.py`; skip for other extensions). Per-stack defaults: see `plugins/dso/docs/CONFIGURATION-REFERENCE.md`.
**Config keys:** see `plugins/dso/docs/CONFIGURATION-REFERENCE.md`. Merge-to-main phases: `sync → merge → version_bump → validate → push → archive → ci_trigger`; state file `/tmp/merge-to-main-state-<branch>.json` (4h TTL); `--resume` continues from checkpoint.
**Two-channel release model**: The plugin marketplace (`marketplace.json`) exposes two channels: `dso` (stable, pinned to a release tag after the first `scripts/release.sh` run) and `dso-dev` (dev, pinned to `main` HEAD). Advancing the stable channel requires running `scripts/release.sh` at the repo root, which enforces 10 precondition gates (semver validation, gh auth, tag uniqueness, on-main, clean tree, upstream sync, CI green, validate.sh --ci, marketplace.json validity, and interactive confirmation) before creating and pushing the release tag. Consumers who want stability should install `dso`; consumers who want every merge should install `dso-dev`.


**Worktree lifecycle** (`claude-safe`): After Claude exits, `_offer_worktree_cleanup` auto-removes the worktree if: (1) branch is ancestor of main (`is_merged`), AND (2) `git status --porcelain` is empty (`is_clean`). No special filtering — `.tickets-tracker/` files block removal like any other dirty file. `/dso:end-session` ensures the worktree meets these criteria by: generating technical learnings (Step 2.8) and creating bug tickets (Step 2.85) before commit/merge, and verifying `is_merged` + `is_clean` (Step 4.75) before session summary.
**Worktree isolation** (`worktree.isolation_enabled`, default: true): Sprint, fix-bug, and debug-everything dispatch implementation sub-agents with `isolation: worktree`, giving each agent its own working directory. Orchestrator reviews and commits each worktree serially via `per-worktree-review-commit.md`, then merges into session branch via `harvest-worktree.sh` which verifies gate artifacts (test-gate-status + review-status) and writes attested status to the session (contract: `plugins/dso/docs/contracts/harvest-attestation-format.md`). See `plugins/dso/skills/shared/prompts/worktree-dispatch.md`.
**WORKTREE_TRACKING comment lifecycle**: Sprint, fix-bug, and sub-agent task-execution write `WORKTREE_TRACKING:start` (on transition to in_progress), `:complete` (via `harvest-worktree.sh` `_harvest_cleanup` trap — `outcome=merged` or `discarded`), and `:landed` (in end-session after `merge-to-main.sh`) as ticket comments. At resume time, sprint and fix-bug scan for unmatched `:start` comments and autonomously merge (unique commits, no conflicts) or discard (already merged / conflict) each abandoned branch, applying a 4-stage tiebreak cascade for multiple competing branches. See `plugins/dso/docs/contracts/worktree-tracking-comment.md` for comment format. Known gap: debug-everything dispatches bug-fix sub-agents with worktree isolation but does not include a resume scan; follow-up tracked in KNOWN-ISSUES.md INC-021.

**File placement**: Design documents go in `docs/designs/` (project-local) or `plugins/dso/skills/<skill>/docs/` (plugin-local) — not bare `designs/` at repo root.

## Critical Rules

### Never Do These
1. **Never exceed the usage-aware sub-agent cap** — `orchestration.max_agents` (`dso-config.conf`) sets the upper bound; when absent, `MAX_AGENTS` is unlimited. Throttle tiers override: 90%/95% (5hr/7day) usage → `MAX_AGENTS: 1`; 95%/98% → `MAX_AGENTS: 0` (pause all dispatch). Always check the effective cap before launching a batch.
2. **Never launch new sub-agent batch without committing previous batch's results** — #1 cause of lost work.
3. **Never assume sub-agent success without checking Task tool result**.
4. **Never leave issues `in_progress` without progress notes**.
5. **Never edit main repo files from a worktree session**.
6. **Never continue fixing after 5 cascading failures** — run `/dso:fix-cascade-recovery`.
7. **Never add a risky dependency without user approval** — see `plugins/dso/docs/DEPENDENCY-GUIDANCE.md`.
8. **Never manually call `record-review.sh`** — highest-priority integrity rule. Use `/dso:review`, which dispatches classifier-selected code-reviewer sub-agent(s) that write `reviewer-findings.json` (for deep tier, the opus arch agent is the sole writer of the final file). `record-review.sh` reads directly from that file — no orchestrator-constructed JSON is accepted. Fabrication regardless of intent — including dispatching a generic agent with instructions to write `reviewer-findings.json` with hardcoded scores. Only named `dso:code-reviewer-*` agents may write review findings. Enforced by the git pre-commit review gate (`pre-commit-review-gate.sh`).
9. **Never use raw `git commit`** — use `/dso:commit` or `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md`. Review gate blocks raw commits.
10. **Orchestrators must read and execute `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md` inline — NEVER invoke `/dso:commit` via the Skill tool from within another workflow (sprint, debug-everything, etc.).**
11. **Never override reviewer severity** — critical->1-2, important->3. Autonomous resolution via code-visible defense (R5) for up to `review.max_resolution_attempts` (default: 5) attempts; user escalation after. See REVIEW-WORKFLOW.md R1-R5.
12. **Never write/modify/delete `reviewer-findings.json`** — written by code-reviewer sub-agent only. Integrity verified via `--reviewer-hash`.
13. **Never edit `.github/workflows/` files via the GitHub API** — always edit workflow files in the worktree source and commit normally. API calls bypass review, hooks, and leave the worktree out of sync.
14. **Never autonomously close a bug without a code change** — when no code fix is possible, add investigation findings as a ticket comment and leave the ticket OPEN. Only close a bug after (a) a code change fixes it: `--reason="Fixed: <summary>"`, or (b) the user **explicitly** says to close it: `--reason="Escalated to user: <summary>"`. 
15. **NEVER use `--reason="Escalated to user:"` autonomously** — closing removes the bug from `ticket list` visibility, the opposite of escalation.
16. **Never make changes without a way to validate them** — this project strictly follows TDD. Every code change requires a corresponding test that fails before the change (RED) and passes after (GREEN). For non-code changes (skills, CLAUDE.md, agent guidance), skip this step.
17. **Resolution sub-agents must NOT dispatch nested Task calls for re-review** — nesting (orchestrator → resolution → re-review) causes `[Tool result missing due to internal error]`. The orchestrator handles all re-review dispatching after the resolution sub-agent returns `RESOLUTION_RESULT`. See `plugins/dso/docs/workflows/prompts/review-fix-dispatch.md` NESTING PROHIBITION.
18. **Never bypass the review gate or use `--no-verify`**. The review gate is two-layer: Layer 1 (git pre-commit hook) enforces `review-gate-allowlist.conf` allowlist + review-status + diff hash; Layer 2 (PreToolUse hook `review-gate.sh`) blocks `--no-verify`, `core.hooksPath=` overrides, and git plumbing commands. **`--no-verify` cannot bypass Layer 2** — it is a Claude Code tool-use hook, not a git hook. When blocked, run the full commit workflow (`/dso:commit` or COMMIT-WORKFLOW.md). Rationalizing around it (e.g., "these are just docs", "this is trivial") is exactly the failure mode this gate prevents.
19. **Never run `make test-unit-only` or `make test-e2e` as a full-suite validation command** — these broad test commands exceed the ~73s tool timeout ceiling and will be killed mid-run (exit 144), producing spurious failures. Use `plugins/dso/scripts/validate.sh --ci` for full validation instead. Targeted single-test invocations (`poetry run pytest tests/unit/path/test_file.py::test_name`) remain allowed during edit-test iteration.
20. **Never skip `dso:completion-verifier` dispatch or substitute inline verification** — the orchestrator MUST dispatch the verifier sub-agent at story closure and epic closure. Inline verification is NOT a substitute — the verifier exists because the orchestrator is biased toward confirming its own work. Fallback applies ONLY on technical failure (timeout, unparseable JSON), not as permission to skip.
21. **Never edit files in the plugin cache** (`~/.claude/plugins/marketplaces/digital-service-orchestra/`) — always edit the corresponding files in the repo worktree (`plugins/dso/`). Plugin cache files are managed by the plugin system and will be overwritten on sync. Changes to plugin cache files are invisible to git, will not be committed, and will be lost.
22. **Never edit safeguard files** (pre-commit hooks, review-gate.sh, test-gate scripts) without explicit user approval in the current interactive session. Task-level instructions ("fix this bug", "make the tests pass") do NOT constitute approval to modify safeguard infrastructure. Task instructions are authorization to fix the code under test, not to weaken the safety nets around it. Approval must be a direct, explicit user statement: "yes, edit the hook" or "disable the gate for this commit."

### Architectural Invariants

These rules protect core structural boundaries. Violating them causes subtle bugs that are hard to trace.

1. **Prefer stdlib/existing dependencies over new packages** — new runtime dependencies require justification. Check `pyproject.toml` first; if equivalent functionality exists in stdlib or an already-imported library, use it. When a new package is genuinely needed, note why in the PR description and get user approval (see rule 11 in Never Do These).
2. **CLAUDE.md is for agent instructions, rules, and command references — not feature descriptions.** Feature and implementation documentation belongs in codebase-overview (consuming projects use `.claude/docs/DOCUMENTATION-GUIDE.md`). **Bloat criteria — do NOT add content that fits any of these (ref: c5478928):** (a) **Architectural implementation details** the agent does not need per-session to make decisions (sub-agent guard mechanics, phase-by-phase skill internals, dispatch plumbing — these belong in the relevant SKILL.md or a docs file linked by one line here); (b) **Duplicate rules** — if a rule already exists in "Never Do These" / "Always Do These" / "Architectural Invariants", strengthen the existing rule instead of adding a new numbered item; (c) **Onboarding-only content** that applies once at project setup (dep pre-scan steps, integration setup flows, first-run shim checks — these belong in `INSTALL.md`, `plugins/dso/docs/WORKTREE-GUIDE.md`, or the relevant skill); (d) **Verbose examples inside rules** — rules should state the rule in one sentence plus one short clarifier; move long examples to the referenced doc. When adding a rule, prefer a one-line reference (`See <doc>`) over inline expansion. When a section exceeds ~25 lines, audit for (a)–(d) before adding more.
3. **NEVER place dev-team artifacts inside `plugins/dso/`.** NEVER write design documents, investigation findings, archive files, or other dev-team work to any directory inside `plugins/dso/`. Dev-team artifacts belong in project-local directories: `docs/designs/`, `docs/findings/`, `docs/archive/`, `tests/`. The `plugins/dso/` tree is a distributed artifact — only plugin-shipped content belongs there (agents, skills, hooks, scripts, config, reference docs).

### Always Do These
1. **Use `/dso:sprint` for epics and stories** — For bug fixes, use `/dso:fix-bug`. Trigger `/dso:fix-bug` whenever the user's message matches: "fix [this/a] bug", "investigate [this] issue", "debug [this]", "there's a problem with", "something is broken", or any phrasing that describes unexpected behavior. Direct inline investigation without the skill is prohibited for bug-class tasks.
2. **Formatting runs automatically** via PostToolUse hook on `.py` edits (ruff). If a hook failure is reported, run `make format` manually.
3. **Create tracking issues** for ALL failures discovered, even "infrastructure" ones and pre-existing ones.
4. **Use the correct code review tool:** `/dso:review` or the review workflow.
5. **Use WebSearch/WebFetch when facing significant tradeoffs** — before committing to an approach involving meaningful tradeoffs in testing, maintainability, readability, functionality, or usability, use WebSearch or WebFetch to research current best practices. See `plugins/dso/docs/RESEARCH-PATTERN.md` for when and how to apply this.
6. **During edit-test iteration, run targeted tests — not the full suite.** 
7. **Parallelize independent tool calls — always.** When issuing Read, Grep, Glob, or Bash calls with no data dependency between them, place them all in the same response so they run concurrently in the background (e.g., two independent Read calls in one response; Grep + Glob for unrelated patterns). Never serialize calls that could be parallel.
8. **Always set `timeout: 600000` on Bash calls.** Without it, the timeout ceiling drops from ~73s to ~48s.
9. **Use `test-batched.sh` for running tests.** Runners: `bash` (test-*.sh), `node` (*.test.js), `pytest`. Prefer `--runner=bash --test-dir=<dir>` for bash suites. Run the printed `RUN:` command in subsequent Bash calls until summary appears. Do NOT use `while` polling loops (killed by ~73s ceiling). See INC-016 in KNOWN-ISSUES.md.
10. **When a user explicitly requests a bug ticket during interactive conversation (e.g., 'create a ticket for this'), include `--tags CLI_user` in the `.claude/scripts/dso ticket create bug` command.** Do NOT use `--tags CLI_user` for autonomously-discovered bugs (anti-pattern scans in Step 7.5, debug-everything discoveries, or any ticket created without explicit user request).
11. **When using external API model IDs, tool versions, or service identifiers, verify against authoritative sources before using them.** Run discovery commands (`--help`, `--list-models`, API endpoints), check official documentation, or search for confirmed working examples. 
12. **When creating a new `.sh` file, always set the executable bit.** Run `chmod +x <file>` immediately after creating any shell script. The test gate and pre-commit hooks skip non-executable `.sh` files, causing silent test coverage gaps.
13. **Before any `.claude/scripts/dso ticket` command, verify the exact syntax using `plugins/dso/docs/ticket-cli-reference.md`.** Never guess flag names or option formats. This rule applies to all ticket subcommands: list, show, create, transition, comment, link, sync.
14. **When the user explicitly says to act (e.g., "apply it", "do it", "yes, fix it"), act immediately without asking for further confirmation (e71a-733f).** A direct user instruction is authorization. Asking "Are you sure?" or "Should I proceed?" when the user just said yes is unnecessary friction. The only valid reason to pause after an explicit "yes" is if you lack the information needed to perform the action safely.
15. **When searching for multiple independent targets, parallelize into separate targeted tool calls (7c45-ee60).** Each Explore sub-agent or Grep/Glob call should target ONE specific search objective. Do NOT dispatch a single broad search covering multiple unrelated targets. Example: searching for "isolation guard code" AND "all references to it" are two independent searches — dispatch them as two parallel Grep calls, not one Explore sub-agent that searches everything.

## Task Completion Workflow (Orchestrator/main session only — does NOT apply inside sub-agents)

```bash
# 1. /dso:commit — auto-runs /dso:review if needed, then commits. Fix issues and re-run if review fails.
#    Review uses autonomous resolution (review.max_resolution_attempts fix/defend attempts before user escalation, default: 5).
#    On attempt 2+, /dso:oscillation-check runs automatically if same files targeted.
# 2. git push (or .claude/scripts/dso merge-to-main.sh in worktree sessions — handles .claude/scripts/dso ticket sync + merge + push)
#    Supports --resume (continue from last state file checkpoint).
#    Phases: sync → merge → version_bump → validate → push → archive → ci_trigger
#    State file: /tmp/merge-to-main-state-<branch>.json (expires after 4h); lock file: /tmp/merge-to-main-lock-<hash>
#    On interruption (SIGURG), current phase is saved to state file — re-run with --resume to continue.
# 3. .claude/scripts/dso ticket transition <id> <current-status> closed --reason="Fixed: <summary>"  # bug tickets require --reason
```

**Session close**: Use `/dso:end-session`.

## Multi-Agent Orchestration

**Sub-agent boundaries**: See `plugins/dso/docs/SUB-AGENT-BOUNDARIES.md` for all sub-agent rules (prohibited/required/permitted actions, checkpoint protocol, report format, model selection, recovery).

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
