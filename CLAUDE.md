# Claude Code Project Configuration

**Repo root**: `/Users/joeoakhart/digital-service-orchestra` — all script paths below are relative to this.

## Working Directory & Paths

**ALWAYS run `pwd` first** to confirm your working directory before running commands.

**Worktree sessions**: If in a worktree (`test -f .git`), use `REPO_ROOT=$(git rev-parse --show-toplevel)`. See `plugins/dso/docs/WORKTREE-GUIDE.md`.

## Quick Start: What Are You Doing?

```
Task type → Action:
  Bug fix        → /dso:fix-bug
  New feature    → Run pwd → Review Architecture below /dso:sprint for epics
  Interface      → /dso:interface-contracts
  Task mgmt      → Ticket Commands section
  Test failure   → See TEST-FAILURE-DISPATCH.md (auto-delegation via /dso:sprint and /dso:commit)
  Debugging      → Check KNOWN-ISSUES.md in consuming project's .claude/docs/
```

## Quick Reference

| Action | Command | When Run |
|--------|---------|----------|
| Onboard a new project (unified) | `/dso:onboarding` | Onboarding a host project |
| Scaffold enforcement infrastructure | `/dso:architect-foundation` | After onboarding |
| Run epics end-to-end | `/dso:sprint` | Starting a feature epic |
| Feature ideation to epic spec | `/dso:brainstorm` | New feature exploration |
| Epic decomposition into stories | `/dso:preplanning` | After epic creation |
| Story to task breakdown | `/dso:implementation-plan` | Before coding a story |
| Fix a bug (TDD-based) | `/dso:fix-bug` | Bug fixes (classifies, investigates, fixes) |
| TDD development cycle | `/dso:tdd-workflow` | New feature TDD (not bug fixes) |
| Diagnose and fix failures | `/dso:debug-everything` | Test/CI/runtime failures |
| Commit with review gates | `/dso:commit` | Ready to commit |
| Code review via sub-agent | `/dso:review` | Pre-commit review |
| Review plans/designs | `/dso:plan-review` | Before presenting a plan |
| Update project docs | `/dso:update-docs` | After epic completion |
| Clean session close | `/dso:end` | End of session |
| Full validation suite | `plugins/dso/scripts/validate.sh --ci` | Before merge / after epic |
| Check unqualified skill refs | `plugins/dso/scripts/check-skill-refs.sh` | After editing in-scope files |
| Bulk-qualify skill refs | `plugins/dso/scripts/qualify-skill-refs.sh` | One-shot migration (run once) |
| Merge worktree to main | `plugins/dso/scripts/merge-to-main.sh` | Worktree session complete |
| List ready tickets | `.claude/scripts/dso ticket list` | Check what to work on |
| Show ticket details | `.claude/scripts/dso ticket show <id>` | Inspect a specific ticket |
| Create a ticket | `.claude/scripts/dso ticket create <type> <title>` | Create bug/epic/story/task |
| Close a ticket | `.claude/scripts/dso ticket transition <id> <current> closed` | Close a ticket (bug tickets require `--reason="Fixed: <summary>"`) |
| Link tickets | `.claude/scripts/dso ticket link <src> <tgt> <relation>` | Add dependency/blocks/relates_to link |
| Sync with Jira | `.claude/scripts/dso ticket sync` (Jira bridge; see architecture) | Sync to Jira |

Priority: 0-4 (0=critical, 4=backlog). Never use "high"/"medium"/"low".

**Ticket type terminology**: `epic` = container for a feature area; `story` = user story (epic children, written as "As a [user], [goal]"); `task` = implementation work item. Ticket titles must be ≤ 255 characters (Jira sync limit).

## Architecture

**Ticket system v3 (event-sourced)**: Orphan git branch `tickets` mounted at `.tickets-tracker/`. JSON event files per ticket; Python reducer (`ticket-reducer.py`) compiles state on-demand. Writes are serialized with `fcntl.flock` to prevent concurrent corruption. CLI: `plugins/dso/scripts/ticket <subcommand>` (full reference: `plugins/dso/docs/ticket-cli-reference.md`). **Archived-ticket exclusion**: All scan operations (`ticket list`, `ticket deps`, `ticket-graph.py` dep lookups) exclude archived tickets by default; `ticket show` always includes them. `ticket list` and `ticket deps` accept `--include-archived` to override. `ticket transition close` uses a single `batch_close_operations` scan (no repeated reducer calls). `ticket-graph.py` uses a single `reduce_all_tickets` call per invocation. **Jira bridge**: `.claude/scripts/dso ticket sync` (incremental default, `--full` to force, `--check` for dry-run). Requires `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`.
**Hook architecture**: Consolidated dispatchers (`pre-bash.sh` + `post-bash.sh`). All hooks are jq-free — use `parse_json_field`, `json_build`, and `python3` for JSON parsing. See `plugins/dso/hooks/dispatchers/` and `plugins/dso/hooks/lib/`. **Review gate (two-layer defense-in-depth)**: Layer 1 — `pre-commit-review-gate.sh` (git pre-commit hook); default-deny allowlist from `review-gate-allowlist.conf`; checks review-status + diff hash; formatting-only mismatches self-heal via `ruff format`. Layer 2 — `review-gate.sh` (PreToolUse hook, wraps `review-gate-bypass-sentinel.sh`); blocks `--no-verify`, `-n`, `core.hooksPath=` override, `git commit-tree`, direct `.git/hooks/` writes, direct writes/deletions to `test-gate-status` and `test-exemptions` (only `record-test-status.sh` and `record-test-exemption.sh` are authorized writers). **Test gate (two-layer defense-in-depth)**: Layer 1 — `pre-commit-test-gate.sh` (git pre-commit hook); verifies `test-gate-status` for each staged source file with an associated test (fuzzy matching or `.test-index`). Test dirs: `test_gate.test_dirs` in `.claude/dso-config.conf` (default: `tests/`). `.test-index` format: `source/path.ext: test/path1.ext, test/path2.ext` (one per line; `#` comments ok). **RED marker format**: `source/path.ext: test/path.ext [first_red_test_name]` — `[marker]` marks boundary between GREEN (passing) and RED (not yet implemented) tests; failures at or after marker are tolerated. RED tests must be at end of test file. **TDD workflow**: Add test at end of file + `[test_name]` marker to `.test-index` — e.g., `source/foo.sh: tests/test_foo.sh [test_new_feature]`. Remove marker after implementation passes. **Epic closure**: blocked while any `[marker]` entries remain in `.test-index`. Layer 2 — `review-gate-bypass-sentinel.sh` blocks direct writes/deletions to `test-gate-status` and `test-exemptions`.
**Validation gate**: `validate.sh` writes state; hooks block sprint/epic if validation hasn't passed. `--verbose` for real-time progress.
**Agent routing**: `discover-agents.sh` resolves routing categories to agents via `agent-routing.conf`; all fall back to `general-purpose`. See `plugins/dso/docs/INSTALL.md`. **Named-agent dispatch** (via `subagent_type`, defined in `plugins/dso/agents/`):

| Agent | Model | Dispatched by |
|-------|-------|---------------|
| `dso:complexity-evaluator` | haiku | `/dso:sprint`, `/dso:brainstorm`; read inline by `/dso:fix-bug` |
| `dso:conflict-analyzer` | sonnet | `/dso:resolve-conflicts` |
| `dso:doc-writer` | sonnet | `/dso:sprint` (doc stories), `/dso:update-docs` |
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

RED test escalation: `dso:red-test-writer` → `dso:red-test-evaluator` triage → opus retry → user escalation. Template: `plugins/dso/skills/sprint/prompts/red-task-escalation.md`.
**Tiered review**: `review-complexity-classifier.sh` scores diffs on 7 factors; 0–2 → light (haiku), 3–6 → standard (sonnet), 7+ → deep (3 parallel sonnet + opus synthesis). Diff: 300+ lines → opus upgrade, 600+ → rejection; merge commits bypass size limits. See `plugins/dso/docs/contracts/classifier-tier-output.md`. **Review dimensions**: `correctness`, `verification`, `hygiene`, `design`, `maintainability` in `reviewer-findings.json`.
**Conflict avoidance** (multi-agent): Static file impact analysis, shared blackboard, agent discovery protocol, semantic conflict check — integrated into `/dso:sprint` and `/dso:debug-everything`.
**This repo is the `dso` plugin.** Skills: interface-contracts, resolve-conflicts, tickets-health, onboarding, architect-foundation, design-review, design-wireframe, ui-discover, debug-everything, sprint, brainstorm, preplanning, implementation-plan, fix-bug (replaces tdd-workflow for bug fixes), tdd-workflow (new feature TDD only), etc. Commands: commit, end, review. Invocation: `/dso:skill-name` (qualified, required) or `/skill-name` (alias). **Namespace policy**: in-scope files MUST use `/dso:<skill-name>`. Enforced by `check-skill-refs.sh` (fatal in `validate.sh`); `qualify-skill-refs.sh` for bulk migration. Config: `.claude/dso-config.conf` (flat KEY=VALUE; keys: `format.*`, `ci.*`, `commands.*`, `jira.*`, `design.*`, `tickets.*`, `merge.*`, `version.*`, `test.*`). Test suites: `project-detect.sh --suites [REPO_ROOT]` for discovery. CI workflow generation: see `/dso:onboarding` skill.
**Onboarding** (`/dso:onboarding`): Phase 1 auto-detects project configuration from files (`project-detect.sh`, `package.json`, `pyproject.toml`, `.husky/`, `.github/workflows/`, test directories) before asking any questions; detected values are presented for confirmation rather than re-discovered from scratch. Phase 3 initializes enforcement infrastructure for the host project: installs git pre-commit hooks (Husky / pre-commit framework / bare `.git/hooks/` — detected automatically), initializes the ticket system (orphan `tickets` branch + `.tickets-tracker/` + smoke test), generates `.test-index` via `generate-test-index.sh`, generates a host-project `CLAUDE.md` with ticket command references, and copies the `KNOWN-ISSUES` template. Both the `project-understanding.md` artifact and `dso-config.conf` are presented for user review before writing; existing files show a diff so no prior configuration is silently overwritten.
**Architect-foundation** (`/dso:architect-foundation`): Reads `.claude/project-understanding.md` written by `/dso:onboarding` and skips questions already answered there. Phase 2.5 (Recommendation Synthesis) synthesizes findings into concrete, project-specific enforcement recommendations — each recommendation cites the specific project file or pattern that triggered it (e.g., "Because `src/adapters/db.py` directly imports `domain/models.py`, recommend enforcing the adapter boundary as a fitness function"). Recommendations are presented one at a time for the user to accept, reject, or discuss. Phase 2.75 presents every artifact for user review before writing; existing files (such as `CLAUDE.md` or `ARCH_ENFORCEMENT.md`) show a diff rather than a full replacement.
Config keys: `ci.workflow_name` (GitHub Actions workflow; preferred over deprecated `merge.ci_workflow_name`), `merge.visual_baseline_path` (snapshot dir), `merge.message_exclusion_pattern` (default `^chore: post-merge cleanup`), `version.file_path` (semver file; `.json`/`.toml`/plaintext; absent = skip bumping). Source of truth: `plugins/dso/scripts/merge-to-main.sh`. Phases: `sync → merge → version_bump → validate → push → archive → ci_trigger`; state file at `/tmp/merge-to-main-state-<branch>.json` (4h TTL) for `--resume`; SIGURG saves current phase. **Plugin portability**: path assumptions config-driven via `.claude/dso-config.conf`. **Host project invocation**: `.claude/scripts/dso <script-name>` shim; install via `bash plugins/dso/scripts/dso-setup.sh [TARGET_REPO]`.

The pre-commit review gate (`pre-commit-review-gate.sh`) handles merge commits (`MERGE_HEAD`) natively — when MERGE_HEAD exists, it computes the merge base and filters out incoming-only files (files changed on main but not on the worktree branch) from review consideration, since those were already reviewed on main. Fail-safe: if MERGE_HEAD equals HEAD or merge-base computation fails, normal review enforcement applies.

**Worktree lifecycle** (`claude-safe`): After Claude exits, `_offer_worktree_cleanup` auto-removes the worktree if: (1) branch is ancestor of main (`is_merged`), AND (2) `git status --porcelain` is empty (`is_clean`). No special filtering — `.tickets-tracker/` files block removal like any other dirty file. `/dso:end` ensures the worktree meets these criteria by: generating technical learnings (Step 2.8) and creating bug tickets (Step 2.85) before commit/merge, and verifying `is_merged` + `is_clean` (Step 4.75) before session summary.

**File placement**: Design documents go in `plugins/dso/docs/designs/` — not bare `designs/` at repo root (review-gate blocks it).

## Critical Rules

### Never Do These
1. **Never close tasks before CI passes** — fix if you broke it; create tracking issue if pre-existing.
2. **Never use `app/` in paths when CWD is `app/`** — use `src/`, `tests/` directly. When CWD is the repo root, `app/` prefix is required. `.claude/` is always at the repo root; plugin scripts are at `plugins/dso/scripts/`. (This is this project's convention; `app/` is configured via `paths.app_dir` in `.claude/dso-config.conf` and is project-specific, not a universal plugin requirement.)
3. **Never skip issue validation after creating issues or adding deps** — run `validate-issues.sh --quick --terse`.
4. **Never create more than 5 sub-agents at a time** — batch into groups of 5.
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
18. **Never edit safeguard files without user approval** — protected: `plugins/dso/skills/**`, `plugins/dso/hooks/**`, `plugins/dso/docs/workflows/**`, `plugins/dso/scripts/**`, `CLAUDE.md`, `plugins/dso/hooks/lib/review-gate-allowlist.conf`, `plugins/dso/scripts/review-complexity-classifier.sh`. Agents may rationalize removing safeguards — this is exactly the failure mode this rule prevents. Always confirm specific changes first.
19. **Never autonomously close a bug without a code change** — escalate to the user if no code fix is possible. Use `.claude/scripts/dso ticket comment <id> "note"` to record findings. Only `.claude/scripts/dso ticket transition <id> <current> closed --reason="Fixed: <summary>"` after (a) a code change fixes it, or (b) the user explicitly authorizes closure (use `--reason="Escalated to user: <summary>"`). Bug tickets **require** the `--reason` flag with prefix `Fixed:` or `Escalated to user:` — omitting it causes a silent failure.
20. **Never make changes without a way to validate them** — this project strictly follows TDD. Every code change requires a corresponding test that fails before the change (RED) and passes after (GREEN). For non-code changes (skills, CLAUDE.md, agent guidance), define an eval or validation method before making the change.
21. **Resolution sub-agents must NOT dispatch nested Task calls for re-review** — nesting (orchestrator → resolution → re-review) causes `[Tool result missing due to internal error]`. The orchestrator handles all re-review dispatching after the resolution sub-agent returns `RESOLUTION_RESULT`. See `plugins/dso/docs/workflows/prompts/review-fix-dispatch.md` NESTING PROHIBITION.
22. **Never bypass the review gate or use `--no-verify`** without explicit user approval. The review gate is two-layer: Layer 1 (git pre-commit hook) enforces allowlist + review-status + diff hash; Layer 2 (PreToolUse hook `review-gate.sh`) blocks `--no-verify`, `core.hooksPath=` overrides, and git plumbing commands. **`--no-verify` cannot bypass Layer 2** — it is a Claude Code tool-use hook, not a git hook, so `--no-verify` has no effect on it. When blocked, run the full commit workflow (`/dso:commit` or COMMIT-WORKFLOW.md). Rationalizing around it (e.g., "these are just docs", "this is trivial") is exactly the failure mode this gate prevents. Pre-commit hooks include format-check (Ruff) and lint (Ruff/MyPy); if hooks fail: `make format` for formatting, fix lint manually.
23. **Never run `make test-unit-only` or `make test-e2e` as a full-suite validation command** — these broad test commands exceed the ~73s tool timeout ceiling and will be killed mid-run (exit 144), producing spurious failures. Use `plugins/dso/scripts/validate.sh --ci` for full validation instead. Targeted single-test invocations (`poetry run pytest tests/unit/path/test_file.py::test_name`) remain allowed during edit-test iteration.
24. **Never skip `dso:completion-verifier` dispatch or substitute inline verification** — the orchestrator MUST dispatch the verifier sub-agent at story closure (Step 10a) and epic closure (Phase 7 Step 0.75). Inline verification is NOT a substitute — the verifier exists because the orchestrator is biased toward confirming its own work. Fallback applies ONLY on technical failure (timeout, unparseable JSON), not as permission to skip.

### Architectural Invariants

These rules protect core structural boundaries. Violating them causes subtle bugs that are hard to trace.

1. **Prefer stdlib/existing dependencies over new packages** — new runtime dependencies require justification. Check `pyproject.toml` first; if equivalent functionality exists in stdlib or an already-imported library, use it. When a new package is genuinely needed, note why in the PR description and get user approval (see rule 11 in Never Do These).
2. **CLAUDE.md is for agent instructions, rules, and command references — not feature descriptions.** Feature and implementation documentation belongs in codebase-overview (consuming projects use `.claude/docs/DOCUMENTATION-GUIDE.md`).

### Always Do These
1. **Use `/dso:sprint` for epics** — it runs `validate.sh --ci` automatically. For bug fixes, use `/dso:fix-bug`. For non-epic work (docs, research), validation runs at commit time for code changes.
2. **Formatting runs automatically** via PostToolUse hook on `.py` edits (ruff). If a hook failure is reported, run `make format` manually.
3. **Create tracking issues** for ALL failures discovered, even "infrastructure" ones.
4. **Use the correct review tool:**

| Reviewing a... | Use | NOT this |
|----------------|-----|----------|
| Plan or design | `/dso:plan-review` | `/dso:review` |
| Completed code | `/dso:review` | `/dso:plan-review` |

5. **Use task status updates for step/phase progress — not text headers.** When executing a skill's numbered steps or phases, track progress through `TaskUpdate` (`in_progress` → `completed`) rather than printing headers like `**Step N: Description**` or `**Phase N: Description**` as visible text. Task status updates show in the spinner; narrating step/phase headers is redundant and clutters the user-visible output.
6. **Use WebSearch/WebFetch when facing significant tradeoffs** — before committing to an approach involving meaningful tradeoffs in testing, maintainability, readability, functionality, or usability, use WebSearch or WebFetch to research current best practices. See `plugins/dso/docs/RESEARCH-PATTERN.md` for when and how to apply this.
7. **During edit-test iteration, run targeted tests — not the full suite.** Use `cd app && poetry run pytest tests/unit/path/test_file.py::test_name --tb=short -q` for the specific test being worked on. For final validation, use `plugins/dso/scripts/validate.sh --ci`. Use `--tb=no -q` for repeated iteration runs, `--tb=short` for final pass.
8. **Parallelize independent tool calls — always.** When issuing Read, Grep, Glob, or Bash calls with no data dependency between them, place them all in the same response so they run concurrently (e.g., two independent Read calls in one response; Grep + Glob for unrelated patterns). Never serialize calls that could be parallel.
9. **When fixing a bug, search for the same anti-pattern elsewhere.** After fixing a bug, search the codebase for other code that follows the same anti-pattern you just fixed. Create a bug ticket (`.claude/scripts/dso ticket create bug "<title>"`) for each occurrence found so they can be tracked and fixed systematically.
10. **Write a failing test to verify your CI/staging bug hypothesis before fixing.** When diagnosing a CI or staging failure, write a unit or integration test that reproduces the suspected root cause FIRST. Run it to confirm it fails (RED). Only then implement the fix and verify the test passes (GREEN). This prevents fixing symptoms instead of causes and guards against the fix being wrong.
11. **Always set `timeout: 600000` on Bash calls expected to exceed 30s AND on all Bash calls during commit/review workflows.** Without it, the timeout ceiling drops from ~73s to ~48s. Known slow commands: `validate.sh --ci`, `make test`, `.claude/scripts/dso ticket sync`. Even fast commands during commit/review can receive SIGURG (exit 144) from tool-call cancellation (see INC-016).
12. **Use `test-batched.sh` for running tests.** Prefer `--runner=bash --test-dir=<dir>` for bash suites (per-script resume on timeout). Example: `$(git rev-parse --show-toplevel)/plugins/dso/scripts/test-batched.sh --timeout=50 --runner=bash --test-dir=tests/scripts`. Runners: `bash` (test-*.sh), `node` (*.test.js), `pytest`. Generic fallback: `--timeout=50 "command"`. Run the printed `RUN:` command in subsequent Bash calls until summary appears. Do NOT use `while` polling loops (killed by ~73s ceiling). For non-test long-running commands, see INC-016 in KNOWN-ISSUES.md.

## Task Start Workflow

**Worktree session setup**: See `plugins/dso/docs/WORKTREE-GUIDE.md` (Session Setup section).

**Epics**: Use `/dso:sprint` — it runs `plugins/dso/scripts/validate.sh --ci` automatically and blocks until the codebase is healthy.
**Bug fixes**: Use `/dso:fix-bug` — classifies the bug, selects the investigation path, and applies the TDD-based fix. Do NOT use `/dso:tdd-workflow` for bug fixes; tdd-workflow is for new feature TDD only. Investigation RESULT reports must include a `hypothesis_tests` field (sub-fields: `hypothesis`, `test`, `observed`, `verdict`); results with no confirmed hypothesis are rejected by Step 3.5 (Hypothesis Validation Gate) and escalated. Code modification is blocked by Step 5.5 (RED-before-fix Gate) until a RED test is confirmed failing — mechanical bugs (import errors, lint violations, config syntax) are exempt.
**Docs, research**: Start directly. Validation runs at commit time for code changes (skipped for docs-only commits).
**Before `/dso:debug-everything`**: Run `plugins/dso/scripts/estimate-context-load.sh debug-everything`. If static load >10,000 tokens, trim `MEMORY.md` before starting to avoid premature compaction.
**`/dso:debug-everything` is a thin triage/dispatch layer**: It routes all bugs to `/dso:fix-bug` and handles escalation reports. Complexity evaluation happens post-investigation in `/dso:fix-bug` (Step 4.5), after the bug is fully understood — not pre-investigation in `/dso:debug-everything`.

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
#    # REVIEW-DEFENSE: checkpoint_verify phase removed from docs here intentionally — story dso-q0df (batch 2) removes _phase_checkpoint_verify() from merge-to-main.sh. Docs lead code in this multi-story epic.
#    State file: /tmp/merge-to-main-state-<branch>.json (expires after 4h); lock file: /tmp/merge-to-main-lock-<hash>
#    On interruption (SIGURG), current phase is saved to state file — re-run with --resume to continue.
# 3. plugins/dso/scripts/ci-status.sh --wait — must return "success"
# 4. .claude/scripts/dso ticket transition <id> <current> closed --reason="Fixed: <summary>"  # bug tickets require --reason
```

**Session close**: Use `/dso:end`.

## Multi-Agent Orchestration

**Sub-agent boundaries**: See `plugins/dso/docs/SUB-AGENT-BOUNDARIES.md` for all sub-agent rules (prohibited/required/permitted actions, checkpoint protocol, report format, model selection, recovery).
**Sub-agent guard pattern**: Skills that require the Agent tool or direct user interaction contain a `<SUB-AGENT-GUARD>` block at the top of their `SKILL.md`. When invoked in sub-agent context (via Task tool), the guard instructs the agent to stop immediately and return an error. Two guard variants exist: (1) **Agent tool check** — for skills that dispatch sub-agents (sprint, debug-everything, brainstorm, preplanning, implementation-plan, design-wireframe, design-review, roadmap, plan-review, review-protocol, resolve-conflicts, architect-foundation, validate-work, retro, ui-discover); (2) **Orchestrator signal check** — for skills that require user interaction (end-session, project-setup, design-onboarding, onboarding). Tests: `tests/hooks/test-sub-agent-guard.sh` (40 tests, 2 per skill).

Orchestrator-level rules (apply to `/dso:sprint` and `/dso:debug-everything`, not sub-agents):
- Max 5 concurrent sub-agents; commit+push between batches
- Models: `haiku` (structured I/O), `sonnet` (code gen, review), `opus` (architecture, high-blast-radius); escalate on failure
- Recovery: `.claude/scripts/dso ticket list` + `.claude/scripts/dso ticket show <id>` to read CHECKPOINT notes → `git log --oneline -5 && git status --short` for git state

## Context Efficiency

**After editing a file**: Do not re-read the entire file to verify. The Edit tool confirms success. Use `Read` with `offset`/`limit` for surrounding context if needed.
**After reading a workflow file**: If already read earlier in this conversation (and not compacted since), use the version in context.
**Use built-in Grep and Read tools — not Bash equivalents**: Bash `grep`/`cat` only when piping to other commands or in scripts.

## Common Fixes

| Problem | Fix |
|---------|-----|
| CI shows "queued" | Wait - don't close task yet |
| CI fails | Dispatch `error-debugging:error-detective` agent with CI URL + failed jobs to diagnose, then `/dso:debug-everything` to fix |
| Scripts not found | Use absolute paths from repo root |
| Path not found | Run `pwd` first, adjust paths |
| "No such file" errors | Run `pwd`, verify location, use absolute paths |
| Worktree: "Command not found" | `cd app && rm -rf .venv && poetry env use /opt/homebrew/opt/python@3.13/bin/python3.13 && poetry install` |
| Isolation check fails | Add `# isolation-ok: <reason>` comment to suppress false positive, or fix the violation |

**Before debugging**: Search the consuming project's `KNOWN-ISSUES.md` first (if available). After solving: add to it (3+ similar incidents → propose CLAUDE.md rule).
