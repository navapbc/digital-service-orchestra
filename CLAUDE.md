# Claude Code Project Configuration

**Repo root**: `/Users/joeoakhart/digital-service-orchestra` — all script paths below are relative to this.

## Working Directory & Paths

**ALWAYS run `pwd` first** to confirm your working directory before running commands.

**Worktree sessions**: If in a worktree (`test -f .git`), use `REPO_ROOT=$(git rev-parse --show-toplevel)`. See `docs/WORKTREE-GUIDE.md`.

## Quick Start: What Are You Doing?

```
Task type → Action:
  Bug fix        → /tdd-workflow
  New feature    → Run pwd → Review Architecture below /sprint for epics
  Interface      → /interface-contracts
  Task mgmt      → Ticket Commands section
  Test failure   → See TEST-FAILURE-DISPATCH.md (auto-delegation via /sprint and /commit)
  Debugging      → Check KNOWN-ISSUES.md in consuming project's .claude/docs/
```

**`/implementation-plan` gap analysis**: COMPLEX stories get opus gap analysis (Step 6); TRIVIAL stories skip. See skill for details.

**`/preplanning` adversarial review**: Epics with 3+ stories get red team + blue team adversarial review (Phase 2.5). See skill for details.

## Quick Reference

| Action | Command | When Run |
|--------|---------|----------|
| Run epics end-to-end | `/sprint` | Starting a feature epic |
| Feature ideation to epic spec | `/brainstorm` | New feature exploration |
| Epic decomposition into stories | `/preplanning` | After epic creation |
| Story to task breakdown | `/implementation-plan` | Before coding a story |
| TDD development cycle | `/tdd-workflow` | Bug fixes, code changes |
| Diagnose and fix failures | `/debug-everything` | Test/CI/runtime failures |
| Commit with review gates | `/commit` | Ready to commit |
| Code review via sub-agent | `/review` | Pre-commit review |
| Review plans/designs | `/plan-review` | Before presenting a plan |
| Clean session close | `/end` | End of session |
| Full validation suite | `scripts/validate.sh --ci` | Before merge / after epic |
| Merge worktree to main | `scripts/merge-to-main.sh` | Worktree session complete |
| List ready tickets | `tk ready` | Check what to work on |
| Show ticket details | `tk show <id>` | Inspect a specific ticket |

Priority: 0-4 (0=critical, 4=backlog). Never use "high"/"medium"/"low".

**Ticket type terminology**: `epic` = container for a feature area; `story` = user story (epic children, written as "As a [user], [goal]"); `task` = implementation work item. Ticket titles must be ≤ 255 characters (Jira sync limit).

## Architecture

**Jira integration**: `tk sync` (incremental default, `--full` to force, `--check` for dry-run). Requires `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`.
**Hook architecture**: Consolidated dispatchers (2 processes per Bash tool call: `pre-bash.sh` + `post-bash.sh`). All hooks are jq-free — use `parse_json_field`, `json_build`, and `python3` for JSON parsing. Hook optimization: `tool_logging` and `tool_use_guard` removed from per-call dispatchers; `validation_gate` removed from Edit/Write dispatchers (kept in pre-bash.sh); early-exit guards skip narrow hooks when command keywords don't match. Review workflow timing fix: hash capture occurs after auto-fix passes to prevent drift. On review gate mismatch, diagnostic dump writes to `$ARTIFACTS_DIR/mismatch-diagnostics-<timestamp>.log`; breadcrumb trail in `$ARTIFACTS_DIR/commit-breadcrumbs.log`. See `hooks/dispatchers/` and `hooks/lib/`. **Review gate (two-layer defense-in-depth)**: Layer 1 — `pre-commit-review-gate.sh` is a git pre-commit hook (registered in `.pre-commit-config.yaml`); uses `git diff --cached --name-only` for reliable staged-file detection (no command-string parsing); default-deny allowlist from `review-gate-allowlist.conf`; checks review-status file + diff hash; writes JSONL telemetry to `$ARTIFACTS_DIR/review-gate-telemetry.jsonl`; formatting-only hash mismatches self-heal by re-running `ruff format`. Layer 2 — `review-gate.sh` is a PreToolUse hook (thin wrapper around `review-gate-bypass-sentinel.sh`); blocks bypass vectors: `--no-verify`, `-n` on git commit, `core.hooksPath=` override, `git commit-tree`, direct `.git/hooks/` writes. Test suite: `bash tests/hooks/test-two-layer-review-gate.sh` (or via `bash tests/run-all.sh`).
**Validation gate**: `validate.sh` writes state; hooks block sprint/epic if validation hasn't passed. `--verbose` for real-time progress.
**Agent routing** (dynamic discovery): `discover-agents.sh` resolves routing categories (e.g., `test_fix_unit`, `complex_debug`) to the best available agent using `agent-routing.conf`. Optional plugins (feature-dev, error-debugging, playwright) are preferred when installed; all categories fall back to `general-purpose` with category-specific prompts from `prompts/fallback/<category>.md`. See `docs/INSTALL.md` for optional plugin documentation.
**Conflict avoidance** (multi-agent): Static file impact analysis, shared blackboard, agent discovery protocol, semantic conflict check — integrated into `/sprint` and `/debug-everything`.
**This repo is the `dso` plugin.** Skills: interface-contracts, resolve-conflicts, tickets-health, design-onboarding, design-review, design-wireframe, ui-discover, debug-everything, sprint, brainstorm, preplanning, implementation-plan, tdd-workflow, etc. Commands (commit, end, review) also come from the plugin. Skills are invoked as `/skill-name` (command alias) or `/dso:skill-name` (fully qualified). Ticket scripts in `scripts/` (tk, tk-sync-lib.sh, and 22+ utility scripts). Project-specific config in `workflow-config.conf` (flat KEY=VALUE format; keys: `format.*`, `ci.*`, `commands.*`, `jira.*`, `design.*`, `tickets.*`, `merge.*`). `merge.*` config keys: `merge.visual_baseline_path` (path to snapshot dir; absent = skip baseline intent check), `merge.ci_workflow_name` (GitHub Actions workflow name for `gh workflow run`; absent = skip post-push CI trigger recovery), `merge.message_exclusion_pattern` (regex passed to `grep -vE` when composing merge message; default `^chore: post-merge cleanup`). Source of truth: `scripts/merge-to-main.sh`. Phased workflow: `checkpoint_verify → sync → merge → validate → push → archive → ci_trigger`; state file at `/tmp/merge-to-main-state-<branch>.json` (4h TTL) records completed phases for `--resume`; lock file at `/tmp/merge-to-main-lock-<hash>` prevents concurrent runs; SIGURG trap saves current phase to state file on interrupt. **Plugin portability**: All host-project path assumptions (app dir, make targets, Python version) are config-driven via `workflow-config.conf` — the plugin is portable to projects with different directory structures.

**Ticket index merge driver**: `.tickets/.index.json` conflicts auto-resolve via `scripts/merge-ticket-index.py` (JSON union merge; theirs-wins on true conflicts). `.gitattributes` maps the file to the `tickets-index-merge` driver (register per-clone; see Quick Reference). `worktree-sync-from-main.sh` includes a script-level fallback for CI/fresh-clone environments where the driver is not registered. The pre-commit review gate (`pre-commit-review-gate.sh`) handles merge commits (`MERGE_HEAD`) natively — `git diff --cached` returns only staged files, so the gate classifies them correctly without any cross-worktree special-casing.

**Worktree lifecycle** (`claude-safe`): After Claude exits, `_offer_worktree_cleanup` auto-removes the worktree if: (1) branch is ancestor of main (`is_merged`), AND (2) `git status --porcelain` is empty (`is_clean`). No special filtering — `.tickets/` files block removal like any other dirty file. `/end` ensures the worktree meets these criteria by: generating technical learnings (Step 2.8) and creating bug tickets (Step 2.85) before commit/merge, writing `.disable-precompact-checkpoint` sentinel during the post-merge window (Step 3.25), and verifying `is_merged` + `is_clean` (Step 4.75) before session summary.

**File placement**: Design documents go in `docs/designs/` — not bare `designs/` at repo root (review-gate blocks it).

## Critical Rules

### Never Do These
1. **Never close tasks before CI passes** — fix if you broke it; create tracking issue if pre-existing.
2. **Never use `--no-verify`** without human approval. Exception: PreCompact auto-save. Pre-commit hooks: format-check (Ruff), lint (Ruff/MyPy). If hooks fail: `make format` for formatting; fix lint manually.
3. **Tracking issues are auto-created** by commit-failure-tracker hook. Create manually for failures validation won't catch. Duplicates OK; gaps not.
4. **Never use `app/` in paths when CWD is `app/`** — use `src/`, `tests/` directly. When CWD is the repo root, `app/` prefix is required. `.claude/` and `scripts/` are always at the repo root regardless of CWD. (This is this project's convention; `app/` is configured via `paths.app_dir` in `workflow-config.conf` and is project-specific, not a universal plugin requirement.)
5. **Never skip issue validation after creating issues or adding deps** — run `validate-issues.sh --quick --terse`.
6. **Never create more than 5 sub-agents at a time** — batch into groups of 5.
7. **Never launch new sub-agent batch without committing previous batch's results** — #1 cause of lost work.
8. **Never assume sub-agent success without checking Task tool result**.
9. **Never leave issues `in_progress` without progress notes**.
10. **Never skip `git push` between sub-agent batches**.
11. **Never edit main repo files from a worktree session**.
12. **Never continue fixing after 5 cascading failures** — run `/fix-cascade-recovery`.
13. **Never add a risky dependency without user approval** — see `docs/DEPENDENCY-GUIDANCE.md`.
14. **Never manually call `record-review.sh`** — highest-priority integrity rule. Use `/review`, which dispatches a code-reviewer sub-agent that writes `reviewer-findings.json`. `record-review.sh` reads directly from that file — no orchestrator-constructed JSON is accepted. Fabrication regardless of intent. Enforced by the git pre-commit review gate (`pre-commit-review-gate.sh`).
15. **Never use raw `git commit`** — use `/commit` or `docs/workflows/COMMIT-WORKFLOW.md`. Review gate blocks raw commits. **Orchestrators must read and execute `docs/workflows/COMMIT-WORKFLOW.md` inline — NEVER invoke `/commit` via the Skill tool from within another workflow (sprint, debug-everything, etc.).**
16. **Never present a plan without `/plan-review` first**. Do NOT use `/review` for plans.
17. **Never override reviewer severity** — critical->1-2, important->3. Autonomous resolution via code-visible defense (R5) for up to 2 attempts; user escalation after. See REVIEW-WORKFLOW.md R1-R5.
18. **Never write/modify/delete `reviewer-findings.json`** — written by code-reviewer sub-agent only. Integrity verified via `--reviewer-hash`.
19. **Never edit `.github/workflows/` files via the GitHub API** — always edit workflow files in the worktree source and commit normally. API calls bypass review, hooks, and leave the worktree out of sync.
20. **Never edit safeguard files without user approval** — protected: `skills/**`, `hooks/**`, `docs/workflows/**`, `scripts/**`, `CLAUDE.md`, `hooks/lib/review-gate-allowlist.conf`. Agents may rationalize removing safeguards — this is exactly the failure mode this rule prevents. Always confirm specific changes first.
21. **Never autonomously close a bug without a code change** — escalate to the user if no code fix is possible. Use `tk add-note <id> "note"` to record findings. Only `tk close <id> --reason="Fixed: <file/change>"` after (a) a code change fixes it, or (b) the user explicitly authorizes closure (`--reason="Escalated to user: <reason>"`).
22. **Never make changes without a way to validate them** — this project strictly follows TDD. Every code change requires a corresponding test that fails before the change (RED) and passes after (GREEN). For non-code changes (skills, CLAUDE.md, agent guidance), define an eval or validation method before making the change.
23. **Resolution sub-agents must NOT dispatch nested Task calls for re-review** — the Autonomous Resolution Loop in REVIEW-WORKFLOW.md dispatches a resolution sub-agent that performs fixes and then calls a re-review sub-agent internally (two levels of nesting: orchestrator → resolution → re-review). This two-level nesting causes `[Tool result missing due to internal error]` failures. The orchestrator handles all re-review dispatching after the resolution sub-agent returns `RESOLUTION_RESULT`. See `docs/workflows/prompts/review-fix-dispatch.md` NESTING PROHIBITION section.
24. **Never bypass the review gate without explicit user approval** — the review gate is now two-layer: Layer 1 is the git pre-commit hook (`pre-commit-review-gate.sh`) which enforces allowlist + review-status + diff hash; Layer 2 is the PreToolUse bypass sentinel (`review-gate.sh`) which blocks `--no-verify`, `core.hooksPath=` overrides, and git plumbing commands. When the review gate blocks a commit, run the full commit workflow (`/commit` or COMMIT-WORKFLOW.md) to satisfy it. Do not use `--no-verify`, WIP workarounds, or any other bypass mechanism unless the user explicitly approves in that specific instance. Rationalizing around it (e.g., "these are just docs", "this is trivial") is exactly the failure mode this gate prevents.

### Architectural Invariants

These rules protect core structural boundaries. Violating them causes subtle bugs that are hard to trace.

1. **Prefer stdlib/existing dependencies over new packages** — new runtime dependencies require justification. Check `pyproject.toml` first; if equivalent functionality exists in stdlib or an already-imported library, use it. When a new package is genuinely needed, note why in the PR description and get user approval (see rule 13 in Never Do These).
2. **CLAUDE.md is for agent instructions, rules, and command references — not feature descriptions.** Feature and implementation documentation belongs in codebase-overview (consuming projects use `.claude/docs/DOCUMENTATION-GUIDE.md`).

### Always Do These
1. **Use `/sprint` for epics** — it runs `validate.sh --ci` automatically. For non-epic work (bug fixes, docs, research), validation runs at commit time for code changes.
2. **Formatting runs automatically** via PostToolUse hook on `.py` edits (ruff). If a hook failure is reported, run `make format` manually.
3. **Create tracking issues** for ALL failures discovered, even "infrastructure" ones
4. **Use the correct review tool:**

| Reviewing a... | Use | NOT this |
|----------------|-----|----------|
| Plan or design | `/plan-review` | `/review` |
| Completed code | `/review` | `/plan-review` |

5. **Use task status updates for step/phase progress — not text headers.** When executing a skill's numbered steps or phases, track progress through `TaskUpdate` (`in_progress` → `completed`) rather than printing headers like `**Step N: Description**` or `**Phase N: Description**` as visible text. Task status updates show in the spinner; narrating step/phase headers is redundant and clutters the user-visible output.
6. **Use WebSearch/WebFetch when facing significant tradeoffs** — before committing to an approach involving meaningful tradeoffs in testing, maintainability, readability, functionality, or usability, use WebSearch or WebFetch to research current best practices. See `docs/RESEARCH-PATTERN.md` for when and how to apply this.
7. **During edit-test iteration, run targeted tests — not the full suite.** Use `cd app && poetry run pytest tests/unit/path/test_file.py::test_name --tb=short -q` for the specific test being worked on. Reserve `make test-unit-only` for the final validation pass only. Use `--tb=no -q` for repeated iteration runs, `--tb=short` for final pass.
8. **Parallelize independent tool calls — always.** When issuing Read, Grep, Glob, or Bash calls with no data dependency between them, place them all in the same response so they run concurrently (e.g., two independent Read calls in one response; Grep + Glob for unrelated patterns). Never serialize calls that could be parallel.
9. **When fixing a bug, search for the same anti-pattern elsewhere.** After fixing a bug, search the codebase for other code that follows the same anti-pattern you just fixed. Create a bug ticket (`tk create`) for each occurrence found so they can be tracked and fixed systematically.
10. **Write a failing test to verify your CI/staging bug hypothesis before fixing.** When diagnosing a CI or staging failure, write a unit or integration test that reproduces the suspected root cause FIRST. Run it to confirm it fails (RED). Only then implement the fix and verify the test passes (GREEN). This prevents fixing symptoms instead of causes and guards against the fix being wrong.
11. **Always set `timeout: 600000` on Bash tool calls for commands expected to exceed 30 seconds, AND on all Bash calls during commit/review workflows.** Claude Code's hard timeout ceiling is ~73s even with max timeout. Without `timeout: 600000`, the ceiling drops to ~48s. Commands known to exceed 30s: `make test-unit-only`, `make test`, `make test-e2e`, `validate.sh`, `tk sync`, `tk` write commands in worktrees with many tickets. Additionally, set `timeout: 600000` on ALL Bash tool calls during COMMIT-WORKFLOW.md and REVIEW-WORKFLOW.md execution — even fast commands like `ruff check` can receive SIGURG (exit 144) from tool-call cancellation during internal event processing (see INC-016 scenario 4).
12. **Use `test-batched.sh` for test commands expected to exceed 60 seconds.** Example: `$(git rev-parse --show-toplevel)/scripts/test-batched.sh --timeout=50 "make test-unit-only"`. The script runs the command in a time-bounded loop, saves progress to a state file, and prints a `NEXT:` resume command when the time limit is reached. Run the printed `NEXT:` command in subsequent Bash tool calls until the summary appears. Do NOT use `while` polling loops — they get killed by the ~73s tool timeout ceiling, producing spurious exit 144. For non-test long-running commands (e.g., `tk sync`), see INC-016 in KNOWN-ISSUES.md for the managed launch/poll script pattern.

## Task Start Workflow

**Worktree session setup**: See `docs/WORKTREE-GUIDE.md` (Session Setup section).

**Epics**: Use `/sprint` — it runs `validate.sh --ci` automatically and blocks until the codebase is healthy.
**Bug fixes, docs, research**: Start directly. Validation runs at commit time for code changes (skipped for docs-only commits).
**Before `/debug-everything`**: Run `scripts/estimate-context-load.sh debug-everything`. If static load >10,000 tokens, trim `MEMORY.md` before starting to avoid premature compaction.
**`/debug-everything` Phase 2.5**: After triage, a complexity gate dispatches a haiku sub-agent with the shared evaluator (`skills/shared/prompts/complexity-evaluator.md`). COMPLEX bugs are routed to epics instead of fix sub-agents.

## Plan Mode Post-Approval Workflow

After ExitPlanMode approval, do NOT begin implementation. Create tk epic, then invoke `/preplanning` on it to decompose into user stories, validate issue health, report the dependency graph, then **STOP and wait**. Do NOT prompt to clear context. See `docs/PLAN-APPROVAL-WORKFLOW.md`.

## Task Completion Workflow (Orchestrator/main session only — does NOT apply inside sub-agents)

```bash
# 1. /commit — auto-runs /review if needed, then commits. Fix issues and re-run if review fails.
#    Review uses autonomous resolution (2 fix/defend attempts before user escalation).
#    On attempt 2+, /oscillation-check runs automatically if same files targeted.
# 2. git push (or scripts/merge-to-main.sh in worktree sessions — handles ticket sync + merge + push)
#    Supports phased execution: --phase=<name> (run one phase) or --resume (continue from last state file checkpoint).
#    Phases: checkpoint_verify → sync → merge → validate → push → archive → ci_trigger
#    State file: /tmp/merge-to-main-state-<branch>.json (expires after 4h); lock file: /tmp/merge-to-main-lock-<hash>
#    On interruption (SIGURG), current phase is saved to state file — re-run with --resume to continue.
# 3. scripts/ci-status.sh --wait — must return "success"
# 4. tk close <id> --reason="Fixed: <summary>" (--reason is REQUIRED)
```

**Session close**: Use `/end` — not the tk Session Close Protocol checklist.

## Multi-Agent Orchestration

**Sub-agent boundaries**: See `docs/SUB-AGENT-BOUNDARIES.md` for all sub-agent rules (prohibited/required/permitted actions, checkpoint protocol, report format, model selection, recovery).

Orchestrator-level rules (apply to `/sprint` and `/debug-everything`, not sub-agents):
- Max 5 concurrent sub-agents; commit+push between batches
- Models: `haiku` (structured I/O), `sonnet` (code gen, review), `opus` (architecture, high-blast-radius); escalate on failure
- Recovery: `tk ready` + `tk show <id>` to read CHECKPOINT notes → `git log --oneline -5 && git status --short` for git state

## Context Efficiency

**After editing a file**: Do not re-read the entire file to verify. The Edit tool confirms success. Use `Read` with `offset`/`limit` for surrounding context if needed.
**After reading a workflow file**: If already read earlier in this conversation (and not compacted since), use the version in context.
**Use built-in Grep and Read tools — not Bash equivalents**: Bash `grep`/`cat` only when piping to other commands or in scripts.

## Common Fixes

| Problem | Fix |
|---------|-----|
| CI shows "queued" | Wait - don't close task yet |
| CI fails | Dispatch `error-debugging:error-detective` agent with CI URL + failed jobs to diagnose, then `/debug-everything` to fix |
| Scripts not found | Use absolute paths from repo root |
| Path not found | Run `pwd` first, adjust paths |
| "No such file" errors | Run `pwd`, verify location, use absolute paths |
| Worktree: "Command not found" | `cd app && rm -rf .venv && poetry env use /opt/homebrew/opt/python@3.13/bin/python3.13 && poetry install` |
| Isolation check fails | Add `# isolation-ok: <reason>` comment to suppress false positive, or fix the violation |

**Before debugging**: Search the consuming project's `KNOWN-ISSUES.md` first (if available). After solving: add to it (3+ similar incidents → propose CLAUDE.md rule).
