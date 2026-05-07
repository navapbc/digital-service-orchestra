# Claude Code Project Configuration

You are a Principal Software Developer at a company like Google or USDS. You are a steward of this codebase; you are invested in the overall quality of the codebase, not just your changes. TAKE YOUR TIME and FIX PREEXISTING ISSUES you encounter.

**Repo root**: Use `REPO_ROOT=$(git rev-parse --show-toplevel)` — all script paths below are relative to the repo root.

**Worktree sessions**: If in a worktree (`test -f .git`), `REPO_ROOT=$(git rev-parse --show-toplevel)` still resolves correctly. See `plugins/dso/docs/WORKTREE-GUIDE.md`.

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
| Clean session close | `/dso:end-session` |
| Full validation suite | `.claude/scripts/dso validate.sh [--ci]` |
| Merge worktree to main | `.claude/scripts/dso merge-to-main.sh [--resume]` |
| List tickets (JSON; filter with `--type=`, `--status=`, `--parent=`) | `.claude/scripts/dso ticket list [--type=<type>] [--status=<status>] [--parent=<id>] [--format=llm]` |
| Check if ticket exists | `.claude/scripts/dso ticket exists <id>` |
| List open epics | `.claude/scripts/dso ticket list-epics [--all] [--has-tag=TAG]` |
| List ticket descendants (BFS) | `.claude/scripts/dso ticket list-descendants <id>` |
| Next agent batch for epic | `.claude/scripts/dso ticket next-batch <epic-id> [--json]` |
| List tickets ready to work | `.claude/scripts/dso ticket ready [--epic=<id>]` |
| Show ticket details | `.claude/scripts/dso ticket show <id>` |
| Create a ticket | `.claude/scripts/dso ticket create <type> <title> [--description <text>] [--tags <tag>] [--parent <parent>] [--priority <priority>]` |
| Close a ticket | `.claude/scripts/dso ticket transition <id> <current-status> closed` (bug tickets require `--reason="Fixed: <summary>"`) |
| Delete a ticket (human-approved gate) | `.claude/scripts/dso ticket delete <id> --user-approved` |
| Link tickets | `.claude/scripts/dso ticket link <src> <tgt> <relation>` |
| Add / remove tag | `.claude/scripts/dso ticket tag <id> <tag>` / `untag <id> <tag>` |

Less common commands (Figma resync, harvest-worktree, recipe-executor, update-artifacts, release.sh, review-stats, check-skill-refs, qualify-skill-refs): see `plugins/dso/docs/COMMANDS-REFERENCE.md` or the relevant skill.

Priority: 0-4 (0=critical, 4=backlog). Never use "high"/"medium"/"low".

**Ticket type terminology**: `epic` = container for a feature area; `story` = user story (epic children, written as "As a [user], [goal]"); `task` = implementation work item. Ticket titles must be ≤ 255 characters (Jira sync limit). `deleted` = terminal status; ticket is excluded from ticket list by default; requires `--user-approved` gate; all children must be deleted first.

## Architecture (pointers)

- **Ticket system v3 (event-sourced)**: orphan branch `tickets` → `.tickets-tracker/`. CLI: `.claude/scripts/dso ticket <subcommand>`. Full reference and rules: `plugins/dso/docs/ticket-cli-reference.md`. The CLI_user tag marks bugs reported explicitly by a human during an interactive session.  <!-- tickets-boundary-ok -->
- **Sub-agents and routing**: `plugins/dso/docs/AGENTS.md` (full named-agent table), `plugins/dso/docs/SUB-AGENT-BOUNDARIES.md` (rules), `INSTALL.md` (routing config).
- **Hooks, gates, test gate, review gate, hook error handler**: `plugins/dso/docs/HOOKS-REFERENCE.md`.
- **CI integration, llm-review orchestrator, two-channel release**: `plugins/dso/docs/CI-INTEGRATION.md`.
- **Worktree lifecycle, isolation, WORKTREE_TRACKING comments**: `plugins/dso/docs/WORKTREE-GUIDE.md` and `plugins/dso/skills/shared/prompts/worktree-dispatch.md`.
- **Config keys** (`merge.strategy`, `enforcement.strategy`, `orchestration.max_agents`, `test_gate.*`, `test_quality.*`, `commands.lint`/`format`/`format_check`, `worktree.isolation_enabled`, `design.figma_collaboration`, `planning.external_dependency_block_enabled`, `scope_drift.enabled`, `review.max_resolution_attempts`): `plugins/dso/docs/CONFIGURATION-REFERENCE.md`.
- **Behavioral testing standard** (5-rule standard for all test-writing agents): `plugins/dso/skills/shared/prompts/behavioral-testing-standard.md`.
- **Prior-art search** (consult before writing/modifying code; routine exclusions: single-file logic fixes, formatting/lint, test reversions, doc-only edits, config value updates): `plugins/dso/skills/shared/prompts/prior-art-search.md`.
- **Value-effort scoring** (used by `/dso:roadmap`): `plugins/dso/skills/shared/prompts/value-effort-scorer.md`.
- **Contracts** (`GAP_CLASSIFICATION`, `INFERENCE_CHALLENGE` / `INFERENCE_SKIP`, `APPROACH_DECISION`, `UI_DESIGNER_PAYLOAD`, harvest attestation, phase1-gate attestation, external-dependencies-block, worktree-tracking-comment): `plugins/dso/docs/contracts/`.
- **Figma design collaboration** (config-gated, `design.figma_collaboration`; default false): see sprint and preplanning SKILL.md.
- **External Dependencies planning** (config-gated, `planning.external_dependency_block_enabled`; default off): see brainstorm SKILL.md.
- **Namespace policy**: in-scope files MUST use `/dso:<skill-name>` (enforced by `check-skill-refs.sh`). Host project shim: `.claude/scripts/dso <script-name>`. Plugin scripts use `_PLUGIN_ROOT` / `_PLUGIN_GIT_PATH`, never literal `plugins/dso/` paths.
- **Testing-mode classification** (per task: RED / GREEN / UPDATE; default RED): emitted by implementation-plan and fix-bug, routed by sprint.
- **Scrutiny pipeline & `scrutiny:pending` / `ui_probes:deferred` gates**: see brainstorm SKILL.md and `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md`.
- **File placement**: design documents go in `docs/designs/` (project-local) or `plugins/dso/skills/<skill>/docs/` (plugin-local) — not bare `designs/` at repo root.

## Critical Rules

### Never Do These
1. **Never exceed the usage-aware sub-agent cap** — `orchestration.max_agents` (`dso-config.conf`) sets the upper bound; when absent, `MAX_AGENTS` is unlimited. Throttle tiers override: 90%/95% (5hr/7day) usage → `MAX_AGENTS: 1`; 95%/98% → `MAX_AGENTS: 0` (pause all dispatch). Always check the effective cap before launching a batch.
2. **Never launch new sub-agent batch without committing previous batch's results** — #1 cause of lost work.
3. **Never assume sub-agent success without checking Task tool result**.
4. **Never leave issues `in_progress` without progress notes**.
5. **Never edit main repo files from a worktree session**.
6. **Never continue fixing after 5 cascading failures** — run `/dso:fix-cascade-recovery`.
7. **Never add a risky dependency without user approval** — see `plugins/dso/docs/DEPENDENCY-GUIDANCE.md`.
8. **Never manually call `record-review.sh`** — highest-priority integrity rule. Use `/dso:review`, which dispatches classifier-selected code-reviewer sub-agent(s) that write `reviewer-findings.json` (for deep tier, the opus arch agent is the sole writer of the final file). `record-review.sh` reads directly from that file — no orchestrator-constructed JSON is accepted. Fabrication regardless of intent — including dispatching a generic agent with instructions to write `reviewer-findings.json` with hardcoded findings. Only named `dso:code-reviewer-*` agents may write review findings. Enforced by the git pre-commit review gate (`pre-commit-review-gate.sh`).
9. **Never use raw `git commit`** — use `/dso:commit` or `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md`. Review gate blocks raw commits.
10. **Orchestrators must read and execute `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md` inline — NEVER invoke `/dso:commit` via the Skill tool from within another workflow (sprint, debug-everything, etc.).**
11. **Never override reviewer severity** — critical->1-2, important->3. Autonomous resolution via code-visible defense (R5) for up to `review.max_resolution_attempts` (default: 5) attempts; user escalation after. See REVIEW-WORKFLOW.md R1-R5.
12. **Never write/modify/delete `reviewer-findings.json`** — written by code-reviewer sub-agent only. Integrity verified via `--reviewer-hash`.
13. **Never edit `.github/workflows/` files via the GitHub API** — always edit workflow files in the worktree source and commit normally. API calls bypass review, hooks, and leave the worktree out of sync.
14. **Never autonomously close a bug without a code change** — when no code fix is possible, add investigation findings as a ticket comment and leave the ticket OPEN. Only close a bug after (a) a code change fixes it: `--reason="Fixed: <summary>"`, or (b) the user **explicitly** says to close it: `--reason="Escalated to user: <summary>"`.
15. **NEVER use `--reason="Escalated to user:"` autonomously** — closing removes the bug from `ticket list` visibility, the opposite of escalation.
16. **Never make changes without a way to validate them** — this project strictly follows TDD. Every code change requires a corresponding test that fails before the change (RED) and passes after (GREEN). For non-code changes (skills, CLAUDE.md, agent guidance), skip this step.
17. **Resolution sub-agents must NOT dispatch nested Task calls for re-review** — nesting causes `[Tool result missing due to internal error]`. The orchestrator handles all re-review dispatching after the resolution sub-agent returns `RESOLUTION_RESULT`. See `plugins/dso/docs/workflows/prompts/review-fix-dispatch.md` NESTING PROHIBITION.
18. **Never bypass the review gate or use `--no-verify`**. The gate is two-layer (see `HOOKS-REFERENCE.md`); `--no-verify` cannot bypass Layer 2 — it is a Claude Code tool-use hook, not a git hook. When blocked, run the full commit workflow. Rationalizing around it ("these are just docs", "this is trivial") is exactly the failure mode this gate prevents. Exception: `enforcement.strategy=ci` skips local enforcement; CI enforces via the parity-uplifted llm-review job.
19. **Never run `make test-unit-only` or `make test-e2e` from the Bash tool** — broad test commands exceed the ~73s tool timeout ceiling and get killed (exit 144). The ~73s ceiling is a Bash-tool property only; it does NOT apply to CI runners. Use `validate.sh --ci` for full validation; targeted single-test invocations remain allowed during edit-test iteration.
20. **Never skip `dso:completion-verifier` dispatch or substitute inline verification** — the orchestrator MUST dispatch the verifier sub-agent at story closure and epic closure. Inline verification is NOT a substitute. Fallback applies ONLY on technical failure (timeout, unparseable JSON), not as permission to skip.
21. **Never edit files in the plugin cache** (`~/.claude/plugins/marketplaces/digital-service-orchestra/`) — always edit the corresponding files in the repo worktree (`plugins/dso/`). Plugin cache files are managed by the plugin system and will be overwritten on sync.
22. **Never edit safeguard files** (pre-commit hooks, review-gate.sh, test-gate scripts) without explicit user approval in the current interactive session. Task instructions are authorization to fix the code under test, not to weaken the safety nets around it.

### Architectural Invariants

These rules protect core structural boundaries. Violating them causes subtle bugs that are hard to trace.

1. **Prefer stdlib/existing dependencies over new packages** — new runtime dependencies require justification. Check `pyproject.toml` first; if equivalent functionality exists in stdlib or an already-imported library, use it. When a new package is genuinely needed, note why in the PR description and get user approval (see rule 7 in Never Do These).
2. **CLAUDE.md is for agent instructions, rules, and command references — not feature descriptions.** Feature and implementation documentation belongs in codebase-overview (consuming projects maintain their own project-local `.claude/docs/DOCUMENTATION-GUIDE.md`; that file is intentionally NOT shipped by the dso plugin). **Bloat criteria — do NOT add content that fits any of these (ref: c5478928):** (a) **Architectural implementation details** the agent does not need per-session to make decisions (sub-agent guard mechanics, phase-by-phase skill internals, dispatch plumbing — these belong in the relevant SKILL.md or a docs file linked by one line here); (b) **Duplicate rules** — if a rule already exists in "Never Do These" / "Always Do These" / "Architectural Invariants", strengthen the existing rule instead of adding a new numbered item; (c) **Onboarding-only content** that applies once at project setup (dep pre-scan steps, integration setup flows, first-run shim checks — these belong in `INSTALL.md`, `plugins/dso/docs/WORKTREE-GUIDE.md`, or the relevant skill); (d) **Verbose examples inside rules** — rules should state the rule in one sentence plus one short clarifier; move long examples to the referenced doc. When adding a rule, prefer a one-line reference (`See <doc>`) over inline expansion. When a section exceeds ~25 lines, audit for (a)–(d) before adding more.
3. **NEVER place dev-team artifacts inside `plugins/dso/`.** NEVER write design documents, investigation findings, archive files, or other dev-team work to any directory inside `plugins/dso/`. Dev-team artifacts belong in project-local directories: `docs/designs/`, `docs/findings/`, `docs/archive/`, `tests/`. The `plugins/dso/` tree is a distributed artifact — only plugin-shipped content belongs there (agents, skills, hooks, scripts, config, reference docs).

### Always Do These
1. **Use `/dso:sprint` for epics and stories** — For bug fixes, use `/dso:fix-bug`. Trigger `/dso:fix-bug` whenever the user's message matches: "fix [this/a] bug", "investigate [this] issue", "debug [this]", "there's a problem with", "something is broken", or any phrasing that describes unexpected behavior. Direct inline investigation without the skill is prohibited for bug-class tasks.
2. **Formatting runs automatically** via PostToolUse hook on `.py` edits (ruff). If a hook failure is reported, run `make format` manually.
3. **Create tracking issues** for ALL failures discovered, even "infrastructure" ones and pre-existing ones.
4. **Use the correct code review tool:** `/dso:review` or the review workflow.
5. **Use WebSearch/WebFetch when facing significant tradeoffs** — before committing to an approach involving meaningful tradeoffs in testing, maintainability, readability, functionality, or usability, research current best practices. See `plugins/dso/docs/RESEARCH-PATTERN.md`.
6. **During edit-test iteration, run targeted tests — not the full suite.**
7. **Parallelize independent tool calls — always.** When issuing Read, Grep, Glob, or Bash calls with no data dependency between them, place them all in the same response so they run concurrently. This applies equally to multi-target searches: each Explore sub-agent or Grep/Glob call should target ONE specific objective; dispatch them as parallel calls, not one broad search covering multiple unrelated targets (7c45-ee60).
8. **Always set `timeout: 600000` on Bash calls.** Without it, the timeout ceiling drops from ~73s to ~48s.
9. **Use `test-batched.sh` for running tests.** Runners: `bash` (test-*.sh), `node` (*.test.js), `pytest`. Prefer `--runner=bash --test-dir=<dir>` for bash suites. Run the printed `RUN:` command in subsequent Bash calls until summary appears. Do NOT use `while` polling loops (killed by ~73s ceiling). See INC-016 in KNOWN-ISSUES.md.
10. **When using external API model IDs, tool versions, or service identifiers, verify against authoritative sources before using them.** Run discovery commands (`--help`, `--list-models`, API endpoints), check official documentation, or search for confirmed working examples.
11. **When creating a new `.sh` file, always set the executable bit.** Run `chmod +x <file>` immediately. The test gate and pre-commit hooks skip non-executable `.sh` files, causing silent test coverage gaps.
12. **Before any `.claude/scripts/dso ticket` command, verify the exact syntax using `plugins/dso/docs/ticket-cli-reference.md`.** Never guess flag names or option formats.
13. **When the user explicitly says to act (e.g., "apply it", "do it", "yes, fix it"), act immediately without asking for further confirmation (e71a-733f).** A direct user instruction is authorization. The only valid reason to pause after an explicit "yes" is if you lack information needed to act safely.
14. **When creating a bug ticket, read `plugins/dso/skills/create-bug/SKILL.md` first.** It is the required entry point for the title format, integer priority rubric (0–4), Zero Inference Rule, and description template.
15. **When writing to `/tmp` or any shared temp directory, always use `mktemp` to generate the path — never hardcoded names.** Use `mktemp /tmp/<prefix>.XXXXXX` (do NOT use the `-t` flag — divergent semantics on macOS vs. GNU). Hardcoded paths cause cross-session conflicts under parallel worktree / multi-session load — silent in single-session development.
16. **Before any destructive git op on a working tree with uncommitted changes, capture a patch first.** Run `git diff > /tmp/session-wip-$(date +%s).patch && git diff --cached >> /tmp/session-wip-$(date +%s).patch` before `git checkout HEAD -- <file>`, `git reset --hard`, `git stash drop`, or any op that discards uncommitted state. Reflog cannot recover uncommitted work — the patch is the only safety net (bug 8988-91be).

## Task Completion Workflow (Orchestrator/main session only — does NOT apply inside sub-agents)

1. **Commit**: `/dso:commit` — auto-runs `/dso:review` if needed, then commits. Review uses autonomous resolution (`review.max_resolution_attempts` fix/defend attempts before user escalation, default 5); `/dso:oscillation-check` runs automatically on attempt 2+ if same files targeted.
2. **Push / merge**: `git push`, or in worktree sessions `.claude/scripts/dso merge-to-main.sh` (handles ticket sync + merge + push; `--resume` continues from checkpoint). Pipeline phases and `merge.strategy=direct|pr` semantics: see `plugins/dso/docs/CI-INTEGRATION.md`.
3. **Close ticket**: `.claude/scripts/dso ticket transition <id> <current-status> closed --reason="Fixed: <summary>"` (bug tickets require `--reason`).

**Session close**: `/dso:end-session`.

## Multi-Agent Orchestration

**Sub-agent boundaries**: see `plugins/dso/docs/SUB-AGENT-BOUNDARIES.md` (prohibited/required/permitted actions, checkpoint protocol, report format, model selection, recovery).

Orchestrator-level models: `haiku` (structured I/O), `sonnet` (code gen, review), `opus` (architecture, high-blast-radius); escalate on failure. Recovery: `.claude/scripts/dso ticket list --status=in_progress` + `.claude/scripts/dso ticket show <id>` for CHECKPOINT notes → `git log --oneline -5 && git status --short` for git state.

## Context Efficiency

- **After editing a file**: do not re-read the entire file to verify. The Edit tool confirms success. Use `Read` with `offset`/`limit` for surrounding context if needed.
- **After reading a workflow file**: if already read earlier in this conversation (and not compacted since), use the version in context.
- **Use built-in Grep and Read tools — not Bash equivalents**: Bash `grep`/`cat` only when piping to other commands or in scripts.

## Structural Code Search (ast-grep)

**Prefer `sg` (ast-grep) over text grep for cross-file dependency discovery** — syntax-aware, distinguishes real references from comments. Check availability: `command -v sg`. When unavailable, fall back to Grep tool. Guard pattern: `if command -v sg >/dev/null 2>&1; then sg ...; else grep ...; fi`.

## Common Fixes

See `.claude/docs/KNOWN-ISSUES.md` for common operational fixes and workarounds.

**Before debugging**: Search the consuming project's `KNOWN-ISSUES.md` first (if available). After solving: add to it (3+ similar incidents → propose CLAUDE.md rule).
