# Claude Code Project Configuration

**Repo root**: Use `REPO_ROOT=$(git rev-parse --show-toplevel)` — all script paths below are relative to the repo root.

## Working Directory & Paths

**ALWAYS run `pwd` first** to confirm your working directory before running commands.

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

**Ticket system v3 (event-sourced)**: Orphan branch `tickets` → `.tickets-tracker/`. CLI: `.claude/scripts/dso ticket <subcommand>` (ref: `plugins/dso/docs/ticket-cli-reference.md`). Archived tickets excluded from list/deps by default; `--include-archived` to override. **Jira bridge**: `.claude/scripts/dso ticket sync` (incremental default, `--full` to force, `--check` for dry-run). Requires `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`. The --tags flag sets tags atomically at creation time (comma-separated). The CLI_user tag marks bugs reported explicitly by a human during an interactive session; /dso:fix-bug Gate 1a skips the dso:intent-search dispatch for CLI_user-tagged bugs, setting GATE_1A_RESULT="intent-aligned" directly. **Suggestion capture**: `suggestion-record.sh` records agent friction/suggestions as immutable JSON files to `.tickets-tracker/.suggestions/`; fields include `source`, `observation`, `recommendation`, `skill_name`, `affected_file`, and `metrics`. Workflow: agents record suggestions during execution → `/dso:retro` synthesizes them into `SUGGESTION_DATA` → Friction Suggestions phase proposes edits to skills/config.
**Hook architecture**: Consolidated dispatchers (`pre-bash.sh` + `post-bash.sh`). All hooks are jq-free — use `parse_json_field`, `json_build`, and `python3` for JSON parsing. See `plugins/dso/hooks/dispatchers/` and `plugins/dso/hooks/lib/`. **Shared merge-state library** (`plugins/dso/hooks/lib/merge-state.sh`): centralizes merge/rebase detection for all enforcement hooks. `ms_` namespace. Fail-open when state is indeterminate. Test injection: set `_MERGE_STATE_GIT_DIR` before sourcing. See file for full API. **Review gate (two-layer)**: Layer 1 — `pre-commit-review-gate.sh` (git hook); Layer 2 — `review-gate.sh` (PreToolUse hook) blocks `--no-verify` and plumbing bypasses. Both layers handle MERGE_HEAD and REBASE_HEAD via `merge-state.sh`. See Never-Do rule 22. **Test gate**: `pre-commit-test-gate.sh` verifies test status per staged file. Centrality-aware (`record-test-status.sh`): high fan-in files trigger full suite. Use `--restart` to clear stale status when the test gate is stuck on a previous failed recording. Config: `test_gate.*` in `dso-config.conf`. `.test-index` maps source → tests; RED marker `[test_name]` tolerates failures at that boundary. **Status values**: `passed`, `failed`, `timeout`, `resource_exhaustion` (distinct from `failed`; written by `record-test-status.sh` when exit 254 + EAGAIN stderr pattern is detected). Severity hierarchy: `timeout > failed > resource_exhaustion > passed`. **EAGAIN retry**: `suite-engine.sh` detects exit 254 + EAGAIN stderr pattern in `_process_completed_test` and retries with `MAX_PARALLEL=1`; retry result is authoritative. `resource_exhaustion` is non-blocking at both fast-path and full-path checkpoints in `pre-commit-test-gate.sh` (emits warning to stderr). **Epic closure**: blocked while any `[marker]` entries remain in `.test-index`. **Brainstorm enforcement gate** (`pre-enterplanmode.sh`): PreToolUse hook blocks EnterPlanMode when no brainstorm sentinel exists (`$ARTIFACTS_DIR/brainstorm-sentinel`). Allowlist bypass via `$ARTIFACTS_DIR/active-skill-context` for non-feature workflows (fix-bug, debug-everything, sprint, implementation-plan, preplanning, resolve-conflicts, architect-foundation, retro). Config: `brainstorm.enforce_entry_gate` (default true). **Test quality gate** (`pre-commit-test-quality-gate.sh`): Pre-commit hook that detects anti-patterns in staged test files (source-file-grepping, tautological tests, change-detector tests, implementation-coupled assertions, existence-only assertions). Scoped to files matching `^tests/`. Config: `test_quality.enabled` (default `true`) and `test_quality.tool` (`bash-grep` | `semgrep` | `disabled`, default `bash-grep`). When `semgrep` is selected, uses rules at `plugins/dso/hooks/semgrep-rules/test-anti-patterns.yaml`. Graceful degradation: if Semgrep is not installed, gate disables rather than blocks. Timeout budget: 15 seconds.
**Validation gate**: `validate.sh` writes state; hooks block sprint/epic if validation hasn't passed. `--verbose` for real-time progress.
**Pre-commit hooks** (self-enforcing — print errors with fix instructions): `check-portability.sh` (hardcoded paths; suppress: `# portability-ok`), `check-shim-refs.sh` (direct plugin script refs; suppress: `# shim-exempt: <reason>`; use `.claude/scripts/dso <script-name>` shim instead), `check-contract-schemas.sh` (contract markdown structure), `check-referential-integrity.sh` (dead path references in instruction files).
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
| `dso:ui-designer` | sonnet | `/dso:preplanning` Step 6 — creates design artifacts (spatial layout, SVG wireframe, token overlay, manifest) for UI stories via Agent tool dispatch; returns `UI_DESIGNER_PAYLOAD` (contract: `plugins/dso/docs/contracts/ui-designer-payload.md`) |

**Agent fallback**: On dispatch failure, read `plugins/dso/agents/<agent-name>.md` inline (strip `dso:` prefix from `subagent_type`).
**Tiered review**: Classifier scores 0–2 → light (haiku), 3–6 → standard (sonnet), 7+ → deep (3×sonnet + opus synthesis). 300+ lines → opus upgrade; 600+ → rejection. Security, performance, and test quality overlays auto-dispatched when classifier flags them. Test quality overlay fires when the diff touches `tests/` files. Review dimensions: `correctness`, `verification`, `hygiene`, `design`, `maintainability`.
**Conflict avoidance** (multi-agent): Static file impact analysis, shared blackboard, agent discovery protocol, semantic conflict check — integrated into `/dso:sprint` and `/dso:debug-everything`.
**Usage-aware throttling** (`check-usage.sh` + `agent-batch-lifecycle.sh`): `check-usage.sh` polls the Claude OAuth usage endpoint, caches results (TTL: 5 min), and returns an exit code reflecting current consumption: `0` = unlimited (below throttle thresholds), `1` = throttled (high usage), `2` = paused (critical usage). `agent-batch-lifecycle.sh`'s `_compute_max_agents()` combines the usage verdict with the `orchestration.max_agents` config cap and `CLAUDE_CONTEXT_WINDOW_USAGE` to emit a `MAX_AGENTS` signal before each batch. Three-tier protocol: unlimited → dispatch up to `orchestration.max_agents` (or no cap when absent); throttled (90%/95% rolling 5hr/7day windows) → `MAX_AGENTS: 1`; paused (95%/98%) → `MAX_AGENTS: 0` (all dispatch halted). `_check_rate_limit_error()` provides error-reactive fallback: rate-limit errors during dispatch trigger an immediate re-evaluation and batch suspension. Config: `orchestration.max_agents` (integer or null; null = no cap).
**scrutiny:pending gate**: epics tagged with `scrutiny:pending` (via `/dso:roadmap` opt-out) are blocked at `/dso:preplanning` and `/dso:implementation-plan` entry until `/dso:brainstorm` is run. **Brainstorm non-epic support**: `/dso:brainstorm` accepts any ticket type; non-epics can convert-to-epic or enrich-in-place. **Epic scrutiny pipeline**: See brainstorm SKILL.md and `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md`. Scrutiny emits `FEASIBILITY_GAP` for critical findings; preplanning emits `REPLAN_ESCALATE: brainstorm` for unresolved gaps. **Value-effort scoring**: `plugins/dso/skills/shared/prompts/value-effort-scorer.md` — shared rubric for epic value vs. effort, used by `/dso:roadmap`.
**Prior-art search**: Before writing or modifying code, consult `plugins/dso/skills/shared/prompts/prior-art-search.md`. Routine exclusions: single-file logic fixes, formatting/lint, test reversions, doc-only edits, config value updates.
**Behavioral testing standard** (`plugins/dso/skills/shared/prompts/behavioral-testing-standard.md`): 5-rule standard consumed by all test-writing agents. Rules: (1) check existing coverage, (2) test observable behavior, (3) execute code and assert outcomes, (4) refactoring litmus test, (5) instruction files — test the structural boundary, not the content.
**Testing mode classification**: Implementation-plan and fix-bug emit `testing_mode` per task (RED: new behavior, GREEN: implementation-only, UPDATE: behavior change with coverage). Sprint routes tasks by testing_mode. Tasks without testing_mode default to RED (backward compatible).
**This repo is the `dso` plugin.** Invocation: `/dso:skill-name` (qualified, required) or `/skill-name` (alias). **Namespace policy**: in-scope files MUST use `/dso:<skill-name>` (enforced by `check-skill-refs.sh`). Host project shim: `.claude/scripts/dso <script-name>`. Config: `.claude/dso-config.conf` (KEY=VALUE; see file for keys).
**Re-invocation guard (implementation-plan)**: Safe to re-invoke mid-implementation — produces diff plan, not duplicates. Emits `REPLAN_ESCALATE: brainstorm` when success criteria unresolvable (contract: `plugins/dso/docs/contracts/replan-escalate-signal.md`). Cascade: brainstorm → preplanning → implementation-plan; bounded by `sprint.max_replan_cycles`. **GAP_CLASSIFICATION** (contract: `plugins/dso/docs/contracts/gap-classification-output.md`): `intent_gap` → brainstorm (with user confirmation), `implementation_gap` → remediation (`ROUTING: implementation-plan` is a signal label, NOT a direct skill invocation).
**Proposal generation and resolution loop (implementation-plan)**: See implementation-plan SKILL.md. Emits `APPROACH_DECISION` signal (contract: `plugins/dso/docs/contracts/approach-decision-output.md`).
**Sprint self-healing loop**: 4 checkpoints (drift detection, confidence signals, validation failure, out-of-scope review). All re-planning writes `REPLAN_TRIGGER` / `REPLAN_RESOLVED` to epic ticket. Non-interactive mode writes `INTERACTIVITY_DEFERRED: brainstorm`. See sprint SKILL.md.
**Figma design collaboration** (config-gated, `design.figma_collaboration`; default false): Sprint filters `design:awaiting_import` stories from batch execution. See sprint SKILL.md and preplanning SKILL.md for details.
Config keys: see `plugins/dso/docs/CONFIGURATION-REFERENCE.md`. Merge-to-main phases: `sync → merge → version_bump → validate → push → archive → ci_trigger`; state file `/tmp/merge-to-main-state-<branch>.json` (4h TTL); `--resume` continues from checkpoint.


**Worktree lifecycle** (`claude-safe`): After Claude exits, `_offer_worktree_cleanup` auto-removes the worktree if: (1) branch is ancestor of main (`is_merged`), AND (2) `git status --porcelain` is empty (`is_clean`). No special filtering — `.tickets-tracker/` files block removal like any other dirty file. `/dso:end` ensures the worktree meets these criteria by: generating technical learnings (Step 2.8) and creating bug tickets (Step 2.85) before commit/merge, and verifying `is_merged` + `is_clean` (Step 4.75) before session summary.
**Worktree isolation** (`worktree.isolation_enabled`, default: true): Sprint, fix-bug, and debug-everything dispatch implementation sub-agents with `isolation: worktree`, giving each agent its own working directory. Orchestrator reviews and commits each worktree serially via `per-worktree-review-commit.md`, then merges into session branch. See `plugins/dso/skills/shared/prompts/worktree-dispatch.md`.

**File placement**: Design documents go in `plugins/dso/docs/designs/` — not bare `designs/` at repo root (review-gate blocks it).

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
19. **Never autonomously close a bug without a code change** — when no code fix is possible, add investigation findings as a ticket comment and leave the ticket OPEN. Only close a bug after (a) a code change fixes it: `--reason="Fixed: <summary>"`, or (b) the user **explicitly** says to close it in this interactive session: `--reason="Escalated to user: <summary>"`. **NEVER use `--reason="Escalated to user:"` autonomously** — closing removes the bug from `ticket list` visibility, the opposite of escalation. Bug tickets require `--reason` with prefix `Fixed:` or `Escalated to user:` — omitting it causes a silent failure.
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
16. **Before any `.claude/scripts/dso ticket` command, verify the exact syntax using `plugins/dso/docs/ticket-cli-reference.md`.** Never guess flag names or option formats. Hallucinated flags like `--parent=<id>` or `--filter-parent <id>` don't exist and will error. Run `.claude/scripts/dso ticket --help` when in doubt. This rule applies to all ticket subcommands: list, show, create, transition, comment, link, sync.

## Task Start Workflow

**Worktree session setup**: See `plugins/dso/docs/WORKTREE-GUIDE.md` (Session Setup section).

**Primary tickets**: Use `/dso:sprint` — it runs `plugins/dso/scripts/validate.sh --ci` automatically and blocks until the codebase is healthy.
**Bug fixes**: Use `/dso:fix-bug` — TDD-based; investigates before fixing.
**Docs, research**: Start directly. Validation runs at commit time for code changes (skipped for docs-only commits).
**Before `/dso:debug-everything`**: Run `plugins/dso/scripts/estimate-context-load.sh debug-everything`. If static load >10,000 tokens, trim `MEMORY.md` before starting to avoid premature compaction.
**`/dso:debug-everything` two-mode flow**: When open bug tickets exist, it enters Bug-Fix Mode — reads `/dso:fix-bug` SKILL.md inline at orchestrator level (preserving Agent tool access) and applies it to each open ticket, then runs Validation Mode (inner fix→validate loop, bounded by `debug.max_fix_validate_cycles`, default 3). When no open bugs exist, it runs the diagnostic scan (Phase 1) → triage sub-agent (Phase 2) → fix pipeline. Interactivity is declared at session start; non-interactive mode defers user-blocking gates as `INTERACTIVITY_DEFERRED` ticket comments instead of pausing. Complexity evaluation happens post-investigation in `/dso:fix-bug` (Step 4.5), after the bug is fully understood — not pre-investigation in `/dso:debug-everything`.
**`/dso:fix-bug` Sub-Agent Context Detection** — primary method: Agent tool availability check (if Agent tool is unavailable, skill is in sub-agent context). Fallback: orchestrator signal `You are running as a sub-agent` in dispatch prompt.

## Plan Mode Post-Approval Workflow

After ExitPlanMode approval, do NOT begin implementation. Follow `plugins/dso/docs/PLAN-APPROVAL-WORKFLOW.md`.

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
**Sub-agent guard pattern**: Skills that require the Agent tool or direct user interaction contain a `<SUB-AGENT-GUARD>` block at the top of their `SKILL.md`. When invoked in sub-agent context (via Task tool), the guard instructs the agent to stop immediately and return an error. Two guard variants exist: (1) **Agent tool check** — for skills that dispatch sub-agents (sprint, debug-everything, brainstorm, preplanning, implementation-plan, design-review, roadmap, plan-review, review-protocol, resolve-conflicts, architect-foundation, validate-work, retro, ui-discover); (2) **Orchestrator signal check** — for skills that require user interaction (end-session, onboarding). Tests: `tests/hooks/test-sub-agent-guard.sh`.

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
