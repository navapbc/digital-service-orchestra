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
| FP-recovery escape valve (when CI llm-review blocks on a suspect FP) | `/dso:fp-recovery <pr-number>` (skill: `${CLAUDE_PLUGIN_ROOT}/skills/fp-recovery/SKILL.md`; workflow: `${CLAUDE_PLUGIN_ROOT}/docs/workflows/FP-RECOVERY-WORKFLOW.md`) |
| Respond to PR review comments | `/dso:respond-to-pr-comments` (skill: `plugins/dso/skills/respond-to-pr-comments/SKILL.md`) |
| Update project docs | `/dso:update-docs` |
| Clean session close | `/dso:end-session` |
| Full validation suite | `.claude/scripts/dso validate.sh [--ci]` |
| Merge worktree to main | `.claude/scripts/dso merge-to-main.sh [--resume]` |
| List tickets (canonical filtered retrieval; AND across filters, comma=OR within one) | `.claude/scripts/dso ticket list [--type=] [--status=] [--priority=] [--parent=] [--has-tag=] [--without-tag=] [--format=llm]` |
| Check if ticket exists | `.claude/scripts/dso ticket exists <id>` |
| List open epics | `.claude/scripts/dso ticket list-epics [--all] [--has-tag=TAG]` |
| List ticket descendants (BFS) | `.claude/scripts/dso ticket list-descendants <id>` |
| Next agent batch for epic | `.claude/scripts/dso ticket next-batch <epic-id> [--json]` |
| List tickets ready to work | `.claude/scripts/dso ticket ready [--epic=<id>]` |
| Show ticket details | `.claude/scripts/dso ticket show <id>` |
| Create a ticket | `.claude/scripts/dso ticket create <type> <title> [--description <text>] [--tags <tag>] [--parent <parent>] [--priority <priority>]` |
| Close a ticket | `.claude/scripts/dso ticket transition <id> <current-status> closed` (bug tickets: see `rule:bug-close-with-code`) |
| Delete a ticket (human-approved gate) | `.claude/scripts/dso ticket delete <id> --user-approved` |
| Link tickets | `.claude/scripts/dso ticket link <src> <tgt> <relation>` |
| Add / remove tag | `.claude/scripts/dso ticket tag <id> <tag>` / `untag <id> <tag>` |
| Acknowledge degradation fallthrough | `.claude/scripts/dso preconditions-ack <story_id> <decision_id> --if-skipped "<rationale>"` |
| Query UI/UX corpus | `dso ref-query [--top-n N] [--tier=summary\|detail\|implementation] [--session-hash H]` |
Less common commands (Figma resync, harvest-worktree, recipe-executor, update-artifacts, release.sh, review-stats, check-skill-refs, qualify-skill-refs): see the relevant skill.

Priority: 0-4 (0=critical, 4=backlog). Never use "high"/"medium"/"low".

**Ticket type terminology**: `epic` = container for a feature area; `story` = user story (epic children, written as "As a [user], [goal]"); `task` = implementation work item. Ticket titles must be ≤ 255 characters (Jira sync limit). `deleted` = terminal status; ticket is excluded from ticket list by default; requires `--user-approved` gate; all children must be deleted first.

**`jira-*` IDs are first-class**: a ticket whose ID starts with `jira-` (e.g., `jira-dig-2564`) is a normal local ticket sourced from the Reconcile Bridge's inbound applier (a Jira-originated issue materialized locally by the reconciler). Accept these IDs anywhere a native ID is accepted — `/dso:fix-bug jira-...`, transitions, `--parent`, batch queues. The prefix is a sourcing label, not an out-of-system signal. A sparse `ticket show` for a `jira-*` ID indicates Jira-mirror sync lag (check `bridge_alerts`), not non-existence. Out-of-scope decisions for `jira-*` tickets follow the same triage criteria as any other ticket — never the prefix alone.

## Architecture (pointers)

- **Ticket system v3 (event-sourced)**: orphan branch `tickets` → `.tickets-tracker/`. CLI: `.claude/scripts/dso ticket <subcommand>`. Full reference and rules: `plugins/dso/docs/ticket-cli-reference.md`. The CLI_user tag marks bugs reported explicitly by a human during an interactive session.  <!-- tickets-boundary-ok -->
- **`## Closure Checks` section** (epic/story tickets): durable end-state intent that is not transitional work; written by `/dso:preplanning` Phase H; verified at closure by `dso:completion-verifier`; audited pre-migration by `.claude/scripts/dso audit-closure-checks-migration.sh`.
- **Sub-agents and routing**: `plugins/dso/docs/AGENTS.md` (full named-agent table), `plugins/dso/docs/SUB-AGENT-BOUNDARIES.md` (rules), `INSTALL.md` (routing config).
- **Hooks, gates, test gate, review gate, hook error handler**: `plugins/dso/docs/HOOKS-REFERENCE.md`.
- **Compliance verifier** (wrapper-driven artifact verification, load-bearing pre-commit gate): see `plugins/dso/docs/HOOKS-REFERENCE.md`.
- **CI integration, llm-review orchestrator, two-channel release**: `plugins/dso/docs/CI-INTEGRATION.md`. Re-review (cycle N≥2) uses two-call architecture (`DSO_REVIEW_CYCLE` env var); defenses recorded via `TrackerDefenseStore` (`review-defense-store.sh`) locally and `GitHubPRDefenseStore` (`review-github-defense-store.sh`) in CI; `mirror-defenses-to-pr.sh` is the CI wrapper. Defense record shape: `plugins/dso/docs/contracts/review-defenses.md`.
- **Context-augmentation loop** (multi-turn file/grep requests, Anthropic prompt caching, soft-cap exhaustion handling): `plugins/dso/docs/contracts/ci-review-context-request.md`; config keys: `review.context_aug.*` in `plugins/dso/docs/CONFIGURATION-REFERENCE.md`.
- **Workflow-stability hardening (v4)**: net-end-state integration diff (`lib/build-integration-diff.sh`), fail-closed Goal-1 coverage invariant (`scripts/ci/review-coverage-invariant.sh`), symbol-level dangling-reference check (`scripts/ci/check-dangling-references.sh`), allowlist-correctness gate (`scripts/ci/check-allowlist-correctness.sh`), review convergence/cycle-cap (`scripts/ci/review-convergence-check.sh`), post-hoc bypass audit (`scripts/ci/fp-recovery-audit-sweep.sh`), and identity-based Goal-4 containment (non-admin agent; `ruleset.bypass_user_id`; human web-UI override). New checks ship in `warn`/advisory mode; admin go-live = flip `DSO_*_MODE=enforce` + add to `required-checks.txt` + provision live. Full map: `plugins/dso/docs/WORKFLOW-STABILITY-CHECKS.md`; setup: `INSTALL.md` → *Goal-4 containment*; plan: `docs/handoff/workflow-stability-plan-v4-handoff.md`.
- **Worktree lifecycle, isolation, WORKTREE_TRACKING comments**: `plugins/dso/docs/WORKTREE-GUIDE.md` and `plugins/dso/skills/shared/prompts/worktree-dispatch.md`.
- **Sprint-active marker** (`.sprint-active`, gitignored): created by Phase A, removed by Phase I; enables `check-session-merge-only.sh` pre-commit hook on the session worktree. See `plugins/dso/skills/sprint/SKILL.md` Phase A and Phase I.
- **Story-branch invariant**: Phase E creates `story/<epic-id>/<story-id>` branch; Phase F merges with `DSO-Story-Merge:` trailer (written by `merge-story-branch.sh`, enforced by `check-session-branch-invariant.sh`). A separate `DSO-Story:` trailer is written on individual task commits by `apply-attribution-trailers.sh` and enforced by `check-sprint-trailer.sh`. See `plugins/dso/docs/contracts/dso-story-merge-trailer.md`.
- **Config keys** (`dso.workflow` — consolidated workflow knob; supersedes the legacy `merge.strategy`/`enforcement.strategy`/`worktree.isolation_enabled` triple — and `orchestration.max_agents`, `test_gate.*`, `test_quality.*`, `commands.lint`/`format`/`format_check`, `design.figma_collaboration`, `planning.external_dependency_block_enabled`, `scope_drift.enabled`, `review.max_cycles`, `pr_comments.human_in_loop`): `plugins/dso/docs/CONFIGURATION-REFERENCE.md`.
- **Behavioral testing standard** (5-rule standard for all test-writing agents): `plugins/dso/skills/shared/prompts/behavioral-testing-standard.md`.
- **Prior-art search** (consult before writing/modifying code; routine exclusions: single-file logic fixes, formatting/lint, test reversions, doc-only edits, config value updates): `plugins/dso/skills/shared/prompts/prior-art-search.md`.
- **Value-effort scoring** (used by `/dso:roadmap`): `plugins/dso/skills/shared/prompts/value-effort-scorer.md`.
- **Contracts** (`GAP_CLASSIFICATION`, `INFERENCE_CHALLENGE` / `INFERENCE_SKIP`, `APPROACH_DECISION`, `UI_DESIGNER_PAYLOAD`, harvest attestation, phase1-gate attestation, external-dependencies-block, worktree-tracking-comment): `plugins/dso/docs/contracts/`.
- **Figma design collaboration** (config-gated, `design.figma_collaboration`; default false): see sprint and preplanning SKILL.md.
- **External Dependencies planning** (config-gated, `planning.external_dependency_block_enabled`; default off): see brainstorm SKILL.md.
- **Namespace policy**: in-scope files MUST use `/dso:<skill-name>` (enforced by `check-skill-refs.sh`). Host project shim: `.claude/scripts/dso <script-name>`. Plugin scripts use `_PLUGIN_ROOT` / `_PLUGIN_GIT_PATH`, never literal `plugins/dso/` paths.
- **Testing-mode classification** (per task: RED / GREEN / UPDATE; default RED): emitted by implementation-plan and fix-bug, routed by sprint.
- **Recipe task type** (`recipe:` task type for deterministic transforms; pre-flight engine check at sprint start validates engine presence + version; cleanup phase runs after each sub-agent before review; LLM fallback via `translate-recipe-to-llm-task.sh` when engine missing): see `plugins/dso/skills/sprint/SKILL.md`.
- **Scrutiny pipeline & `scrutiny:pending` / `ui_probes:deferred` gates**: see brainstorm SKILL.md and `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md`.
- **File placement**: design documents go in `docs/designs/` (project-local) or `plugins/dso/skills/<skill>/docs/` (plugin-local) — not bare `designs/` at repo root.
- **Jira reconciler** (level-triggered, supersedes the edge-triggered bridges per epic 3a03 cutover): workflow `.github/workflows/reconcile-bridge.yml`; implementation `plugins/dso/scripts/dso_reconciler/`; env vars (`BRIDGE_ENV_ID`, `BRIDGE_USER_MAP`, `JIRA_PROJECT`) documented in `plugins/dso/docs/CONFIGURATION-REFERENCE.md`.
- **UI/UX reference corpus** (domain-partitioned YAML files with YAML frontmatter): corpus at `plugins/dso/data/ui-reference/`; retrieval via `plugins/dso/scripts/ref-query.sh` (BM25) and `dso ref-query` shim; `check-corpus-schema.sh` pre-commit hook enforces tag vocabulary; provenance at `docs/ui-reference-sources.yaml`; `plugins/dso/data/**` requires boundary allowlist entry maintenance.
- **PRECONDITIONS degradation channel** (degradation:bool + degradation_type in event data; `EMIT-PRECONDITIONS` landmark required for graceful-degradation triggers in skill files; unacked-degradation check in sprint Step 18 blocks story closure; ack via `dso preconditions-ack`; non-Latin precondition text requires human review): see `plugins/dso/docs/contracts/ack-rationale-rubric.md` and `plugins/dso/hooks/check-precondition-emit.sh`.
- **Orphan-task convention** (DEFER rulings, lifecycle, validate-issues.sh exemption): `docs/orphan-task-convention.md`
- **Completion-verifier protocol** (typed-enum P1 gate, `check-verifier-verdict.sh`, `render-closure-narrative.sh`, `check-manifest-completeness.sh`): `plugins/dso/docs/VERIFIER-PROTOCOL.md`.

## Critical Rules

### Never Do These
1. <!-- rule:agent-cap --> **Never exceed the usage-aware sub-agent cap** — `orchestration.max_agents` (`dso-config.conf`) sets the upper bound; when absent, `MAX_AGENTS` is unlimited. Throttle tiers override: 90%/95% (5hr/7day) usage → `MAX_AGENTS: 1`; 95%/98% → `MAX_AGENTS: 0` (pause all dispatch). Always check the effective cap before launching a batch.
2. <!-- rule:batch-commit --> **Never launch new sub-agent batch without committing previous batch's results** — #1 cause of lost work.
3. <!-- rule:agent-success-check --> **Never assume sub-agent success without checking Task tool result**.
4. <!-- rule:progress-notes --> **Never leave issues `in_progress` without progress notes**.
5. <!-- rule:no-edit-main-from-worktree --> **Never edit main repo files from a worktree session**.
6. <!-- rule:cascade-circuit --> **Never continue fixing after 5 cascading failures** — run `/dso:fix-cascade-recovery`.
7. <!-- rule:risky-dep --> **Never add a risky dependency without user approval** — check stdlib and `pyproject.toml` (or equivalent manifest) first; prefer existing libraries. See `plugins/dso/docs/DEPENDENCY-GUIDANCE.md`.
8. <!-- rule:fabrication --> **Never manually call `record-review.sh`** — highest-priority integrity rule. Use `/dso:review`, which dispatches classifier-selected code-reviewer sub-agent(s) that write `reviewer-findings.json` (for deep tier, the opus arch agent is the sole writer of the final file). `record-review.sh` reads directly from that file — no orchestrator-constructed JSON is accepted. Fabrication regardless of intent — including dispatching a generic agent with instructions to write `reviewer-findings.json` with hardcoded findings. Only named `dso:code-reviewer-*` agents may write review findings. Enforced by the git pre-commit review gate (`pre-commit-review-gate.sh`).
9. <!-- rule:raw-commit --> **Never use raw `git commit`** — use `/dso:commit` or `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md`. Review gate blocks raw commits.
10. <!-- rule:inline-commit-workflow --> **Orchestrators must read and execute `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md` inline — NEVER invoke `/dso:commit` via the Skill tool from within another workflow (sprint, debug-everything, etc.).**
11. <!-- rule:severity-override --> **Never override reviewer severity** — critical→1-2, important→3. Autonomous resolution runs up to `review.max_cycles` attempts (default 4; override in `.claude/dso-config.conf`) before user escalation; the attempt counter may be paused by the verifier's cascading-failure brake when `review.verifier_failure_threshold` is exceeded. See `plugins/dso/docs/workflows/REVIEW-WORKFLOW.md` R1-R5 and `docs/adr/0013-verifier-severity-authority.md` for the verifier and `code-reviewer-arbiter` (cycle-end `DROP`) exception scope.
12. <!-- rule:reviewer-findings-write --> **Never write/modify/delete `reviewer-findings.json`** — written by code-reviewer sub-agent only. Integrity verified via `--reviewer-hash`.
13. <!-- rule:gh-workflows-api --> **Never edit `.github/workflows/` files via the GitHub API** — always edit workflow files in the worktree source and commit normally. API calls bypass review, hooks, and leave the worktree out of sync.
14. <!-- rule:bug-close-with-code --> **Never autonomously close a bug without a code change** — when no code fix is possible, add investigation findings as a ticket comment and leave the ticket OPEN. Only close a bug after (a) a code change fixes it: `--reason="Fixed: <summary>"`, or (b) the user **explicitly** says to close it: `--reason="Escalated to user: <summary>"`.
15. <!-- rule:no-autonomous-escalation --> **NEVER use `--reason="Escalated to user:"` autonomously** — closing removes the bug from `ticket list` visibility, the opposite of escalation.
16. <!-- rule:tdd-requires-test --> **Never make changes without a way to validate them** — this project strictly follows TDD. Every code change requires a corresponding test that fails before the change (RED) and passes after (GREEN). For non-code changes (skills, CLAUDE.md, agent guidance), skip this step.
17. <!-- rule:no-nested-task --> **Resolution sub-agents must NOT dispatch nested Task calls for re-review** — nesting causes `[Tool result missing due to internal error]`. The orchestrator handles all re-review dispatching after the resolution sub-agent returns `RESOLUTION_RESULT`. See `plugins/dso/docs/workflows/prompts/review-fix-dispatch.md` NESTING PROHIBITION.
18. <!-- rule:no-bypass-review --> **Never bypass the review gate or use `--no-verify`** — `--no-verify` does not bypass Layer 2 (a Claude Code tool-use hook, not a git hook). Exception: `dso.workflow=ci-pr` (the canonical workflow knob; superseded the legacy `enforcement.strategy=ci`) skips local enforcement; CI-level false-positive escape is `/dso:fp-recovery <pr-number>`. See `plugins/dso/docs/HOOKS-REFERENCE.md` and `${CLAUDE_PLUGIN_ROOT}/docs/workflows/FP-RECOVERY-WORKFLOW.md`.
19. <!-- rule:no-broad-tests-bash --> **Never run `make test-unit-only` or `make test-e2e` from the Bash tool** — broad test commands exceed the ~73s tool timeout ceiling and get killed (exit 144). The ~73s ceiling is a Bash-tool property only; it does NOT apply to CI runners. Use `validate.sh --ci` for full validation; targeted single-test invocations remain allowed during edit-test iteration.
20. <!-- rule:dispatch-verifier --> **Never skip `dso:completion-verifier` dispatch or substitute inline verification** — the orchestrator MUST dispatch the verifier sub-agent at story closure and epic closure. Inline verification is NOT a substitute. Fallback applies ONLY on technical failure (timeout, unparseable JSON), not as permission to skip. After dispatch, read `P1` (not `overall_verdict`) from verifier output and halt if `P1 ≠ PASS`; use `check-verifier-verdict.sh` as the machine gate. The narrative field must come from `render-closure-narrative.sh`, not LLM prose. See `plugins/dso/docs/VERIFIER-PROTOCOL.md`.
21. <!-- rule:no-edit-plugin-cache --> **Never edit files in the plugin cache** (`~/.claude/plugins/marketplaces/digital-service-orchestra/`) — always edit the corresponding files in the repo worktree (`plugins/dso/`). Plugin cache files are managed by the plugin system and will be overwritten on sync.
22. <!-- rule:no-safeguard-edits --> **Never edit safeguard files** (pre-commit hooks, review-gate.sh, test-gate scripts) without explicit user approval in the current interactive session. Task instructions are authorization to fix the code under test, not to weaken the safety nets around it. Task-level instructions to fix code do not constitute approval to modify safeguards.
23. <!-- rule:no-direct-gh-pr --> **Never use direct `gh pr create` / `gh pr merge` / `git push` to create or update a PR** — always route through `.claude/scripts/dso merge-to-main.sh`. Cached-plugin-broken exception: see `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md`.
24. <!-- rule:no-session-direct-commit --> **Never commit directly to the session worktree while `.sprint-active` or `.debug-active` exists** — route through a sub-branch worktree and Phase F merge. Bypass requires the matching `DSO_*_ACTIVE=0` plus a non-empty `DSO_*_ACTIVE_BYPASS_REASON`; AND-semantics when both markers are present. See `plugins/dso/scripts/check-session-merge-only.sh`.
25. <!-- rule:no-edit-on-main --> **Never edit tracked files while HEAD is on local `main`/`master`** — switch to a feature branch first (`git checkout -b <branch>`). Bypass requires both `DSO_ALLOW_EDIT_ON_MAIN=1` and `DSO_ALLOW_EDIT_ON_MAIN_REASON='<reason>'`. The merge-to-main version-bump pipeline is allowlisted via `DSO_MERGE_TO_MAIN_PHASE=version_bump` + `DSO_MECHANICAL_AMEND=1`. See `plugins/dso/hooks/lib/pre-bash-functions.sh` (`hook_no_edit_on_main`).

### Architectural Invariants

These rules protect core structural boundaries. Violating them causes subtle bugs that are hard to trace.

1. <!-- invariant:claude-md-purpose --> **CLAUDE.md is for agent instructions, rules, and command references — not feature descriptions.** Feature and implementation documentation belongs in codebase-overview (consuming projects maintain their own project-local `.claude/docs/DOCUMENTATION-GUIDE.md`; that file is intentionally NOT shipped by the dso plugin). **Bloat criteria — do NOT add content that fits any of these (ref: c5478928):** (a) **Architectural implementation details** the agent does not need per-session to make decisions (sub-agent guard mechanics, phase-by-phase skill internals, dispatch plumbing — these belong in the relevant SKILL.md or a docs file linked by one line here); (b) **Duplicate rules** — if a rule already exists in "Never Do These" / "Always Do These" / "Architectural Invariants", strengthen the existing rule instead of adding a new numbered item; (c) **Onboarding-only content** that applies once at project setup (dep pre-scan steps, integration setup flows, first-run shim checks — these belong in `INSTALL.md`, `plugins/dso/docs/WORKTREE-GUIDE.md`, or the relevant skill); (d) **Verbose examples inside rules** — rules should state the rule in one sentence plus one short clarifier; move long examples to the referenced doc. When adding a rule, prefer a one-line reference (`See <doc>`) over inline expansion. When a section exceeds ~25 lines, audit for (a)–(d) before adding more.
2. <!-- invariant:no-dev-artifacts-in-plugin --> **NEVER place dev-team artifacts inside `plugins/dso/`.** NEVER write design documents, investigation findings, archive files, or other dev-team work to any directory inside `plugins/dso/`. Dev-team artifacts belong in project-local directories: `docs/designs/`, `docs/findings/`, `docs/archive/`, `tests/`. The `plugins/dso/` tree is a distributed artifact — only plugin-shipped content belongs there (agents, skills, hooks, scripts, config, reference docs).

### Always Do These (mechanically detectable)

Rules below have a mechanical detection path — a hook fires, a test gate skips, or a tool boundary surfaces the violation. The detection may be a hard block (formatting-auto) or a silent-skip with downstream coverage gaps (chmod-x-new-sh); either way, the violation leaves a machine-readable trace.

1. <!-- always:formatting-auto --> **Formatting runs automatically** via PostToolUse hook on `.py` edits (ruff). If a hook failure is reported, run `make format` manually.
2. <!-- always:chmod-x-new-sh --> **When creating a new `.sh` file, always set the executable bit.** Run `chmod +x <file>` immediately. The test gate and pre-commit hooks skip non-executable `.sh` files, causing silent test coverage gaps.

### Behavioral guidance (self-policed)

Rules below have no hook backing — the agent must remember and apply them on its own. Violations go undetected by the harness; the only safety net is the agent's own discipline.

1. <!-- always:sprint-for-epics --> **Use `/dso:sprint` for epics and stories** — For bug fixes, use `/dso:fix-bug`. Trigger `/dso:fix-bug` whenever the user's message matches: "fix [this/a] bug", "investigate [this] issue", "debug [this]", "there's a problem with", "something is broken", or any phrasing that describes unexpected behavior. Direct inline investigation without the skill is prohibited for bug-class tasks.
2. <!-- always:tracking-issues --> **Create tracking issues** for ALL failures discovered, even "infrastructure" ones and pre-existing ones.
3. <!-- always:correct-review-tool --> **Use the correct code review tool:** `/dso:review` or the review workflow.
4. <!-- always:websearch-tradeoffs --> **Use WebSearch/WebFetch when facing significant tradeoffs** — before committing to an approach involving meaningful tradeoffs in testing, maintainability, readability, functionality, or usability, research current best practices. See `plugins/dso/docs/RESEARCH-PATTERN.md`.
5. <!-- always:targeted-tests-iteration --> **During edit-test iteration, run targeted tests — not the full suite.**
6. <!-- always:parallel-tools --> **Parallelize independent tool calls — always.** When issuing Read, Grep, Glob, or Bash calls with no data dependency between them, place them all in the same response so they run concurrently. This applies equally to multi-target searches: each Explore sub-agent or Grep/Glob call should target ONE specific objective; dispatch them as parallel calls, not one broad search covering multiple unrelated targets.
7. <!-- always:bash-timeout-600 --> **Always set `timeout: 600000` on Bash calls.** Without it, the timeout ceiling drops from ~73s to ~48s.
8. <!-- always:test-batched-sh --> **Use `test-batched.sh` for running tests.** Runners: `bash` (test-*.sh), `node` (*.test.js), `pytest`. Prefer `--runner=bash --test-dir=<dir>` for bash suites. Run the printed `RUN:` command in subsequent Bash calls until summary appears. Do NOT use `while` polling loops (killed by ~73s ceiling). See INC-016 in KNOWN-ISSUES.md.
9. <!-- always:verify-model-ids --> **When using external API model IDs, tool versions, or service identifiers, verify against authoritative sources before using them.** Run discovery commands (`--help`, `--list-models`, API endpoints), check official documentation, or search for confirmed working examples.
10. <!-- always:verify-ticket-cli --> **Before any `.claude/scripts/dso ticket` command, verify the exact syntax using `plugins/dso/docs/ticket-cli-reference.md`.** Never guess flag names or option formats.
11. <!-- always:act-on-explicit-yes --> **When the user explicitly says to act (e.g., "apply it", "do it", "yes, fix it"), act immediately without asking for further confirmation.** A direct user instruction is authorization. The only valid reason to pause after an explicit "yes" is if you lack information needed to act safely.
12. <!-- always:read-create-bug-skill --> **When creating a bug ticket, read `plugins/dso/skills/create-bug/SKILL.md` first.** It is the required entry point for the title format, integer priority rubric (0–4), Zero Inference Rule, and description template.
13. <!-- always:mktemp-tmp --> **When writing to `/tmp` or any shared temp directory, always use `mktemp` to generate the path — never hardcoded names.** Do NOT use the `-t` flag (divergent semantics on macOS vs. GNU). Hardcoded paths cause cross-session conflicts under parallel worktree / multi-session load — silent in single-session development. **The correct template depends on context:**
   - **Tests** (`tests/**/test-*.sh`): use `mktemp [-d] "${TMPDIR:-/tmp}/<prefix>.XXXXXX"` — the test suite engine (`tests/lib/suite-engine.sh`) sets `TMPDIR` to a per-test directory for isolation; templates that hardcode `/tmp/` literal bypass the isolation and place files in shared `/tmp`, producing cross-test contention under parallel test execution.
   - **Production / orchestrator scripts**: `mktemp [-d] "/tmp/<prefix>.XXXXXX"` is fine — there is no per-script isolation contract to honor.
   - Both contexts: bare `mktemp -d` (no template) also honors `$TMPDIR` and is preferred when the prefix doesn't matter for diagnostics.
14. <!-- always:patch-before-destructive --> **Before any destructive git op on a working tree with uncommitted changes, capture a patch first.** Run `git diff > /tmp/session-wip-$(date +%s).patch && git diff --cached >> /tmp/session-wip-$(date +%s).patch` before `git checkout HEAD -- <file>`, `git reset --hard`, `git stash drop`, or any op that discards uncommitted state. Reflog cannot recover uncommitted work — the patch is the only safety net.
15. <!-- always:wait-for-pr --> **When waiting for a PR to reach a terminal state, use `plugins/dso/scripts/wait-for-pr.sh <pr_number>` rather than a hand-rolled `until $(gh pr view ... state) == MERGED` loop.** The helper exits non-zero on FAILURE/TIMED_OUT/CANCELLED required-check conclusions, on CLOSED-without-merge, and on timeout — so the session does not poll a doomed PR indefinitely.
16. <!-- always:integrate-context-window --> **Before any scope-rationing decision, compute context usage as a percentage of the announced session window.** The window size is declared in the system prompt (e.g., "Opus 4.7 (1M context)"). Compute `usage_pct = used_tokens / window_size`. Do NOT base scope decisions on a forecast or on a remembered prior-session default. The 70% threshold in skill phases (e.g., sprint Phase F Step 19) is the only legitimate trigger for context-related actions. Below 70%: proceed to next batch. At 70%+: run `/compact`, then continue. Never ask the user to narrow scope due to context pressure.

## Task Completion Workflow (Orchestrator/main session only — does NOT apply inside sub-agents)

1. **Commit**: `/dso:commit` — auto-runs `/dso:review` if needed, then commits. Review uses autonomous resolution (`review.max_cycles` fix/defend attempts before user escalation; default 4; override in `.claude/dso-config.conf`); `/dso:oscillation-check` runs automatically on attempt 2+ if same files targeted.
2. **Push / merge**: `git push`, or in worktree sessions `.claude/scripts/dso merge-to-main.sh` (handles ticket sync + merge + push; `--resume` continues from checkpoint). Pipeline phases and `merge.strategy=direct|pr` semantics: see `plugins/dso/docs/CI-INTEGRATION.md`.
3. **Close ticket**: `.claude/scripts/dso ticket transition <id> <current-status> closed` (bug tickets require `--reason`; see `rule:bug-close-with-code`).

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
