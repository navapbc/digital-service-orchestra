---
name: retro
description: Use when performing periodic project health reviews, optimizing development workflow, cleaning up worktrees, auditing test quality, or identifying technical debt and maintenance needs
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:retro cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Development Retrospective

Proactive project health assessment focused on maintainability, workflow efficiency, and technical debt. Analyzes metrics, identifies improvements, and creates a structured remediation plan.


**Supports dryrun mode.** Use `/dso:dryrun /dso:retro` to preview without changes.

## Usage

```
/dso:retro    # Run full retrospective assessment
```

## Phases

```
Flow: P1 (Health Assessment) → P2 (Codebase Review) → P3 (Findings Report)
  → [user approves scope] P4 (Epic Creation) → P5 (Quick Wins) → Complete
  → [user declines] End
```

---

## Phase 1: Health Assessment (/dso:retro)

Run the data-collection script to gather all metrics in one pass:

```bash
.claude/scripts/dso retro-gather.sh
```

Use `--quick` to skip slow checks (dependency freshness, plugin versions) when session usage is high.

The script outputs structured sections (`=== SECTION_NAME ===`) covering:
cleanup, validation, ticket health/stats/open/blocked/orphaned, worktree staleness,
outdated dependencies, session usage, hook error logs, timeout logs, plugin versions,
test metrics, code metrics (including TODO-family comment scan), known issues counts,
and CI shift-left data (recent run outcomes, failure rate, failed job names).

### Post-Collection Analysis

After reviewing the script output:

1. **Error log triage**: For each unique error pattern in `HOOK_ERROR_LOG`, propose a ticket bug. Use AskUserQuestion to confirm which warrant creation. **After triage**, truncate the logs.
2. **Plugin updates**: For any outdated plugins, never recommend `@latest` tags — always recommend specific pinned versions. Add as P3 cleanup items.
3. **Friction Suggestions**: If the output contains a `SUGGESTION_DATA` section, review the frequency-ranked clusters. Each cluster represents a recurring workflow friction point captured by `suggestion-record.sh`. For each cluster:
   - Note the `file`, `pattern`, and `proposed_edit` fields.
   - Clusters with `count >= 3` are high-signal and should become P2 improvement tasks.
   - Clusters with `count < 3` are low-signal and can be grouped into a single P3 cleanup task.
   - If no `SUGGESTION_DATA` section is present, skip this step.
4. **Report** the structured health inventory (validation status, ticket health, worktree count, dependency freshness, session usage, error triage summary, plugin versions, friction suggestion summary).

---

## Phase 2: Codebase Review (/dso:retro)

Gather codebase metrics, then invoke `/dso:review-protocol` for structured assessment.

### Data Collection

The `retro-gather.sh` output (from Phase 1) already includes `TEST_METRICS`, `CODE_METRICS`, and `KNOWN_ISSUES` sections. Use those as the raw data baseline.

For the review, additionally check (not covered by the script):
1. **Test quality**: Identify files with no assertions, excessive mocking (10+ mocks per test), generic names (`test_1`, `test_basic`).
2. **Documentation**: Check README/CLAUDE.md for deprecated references.
3. **Code quality**: Deep nesting (4+ levels), duplicate patterns, complex functions (>50 lines).
4. **Naming**: Module (snake_case), class (PascalCase), function (snake_case), constant (UPPER_CASE) consistency.
5. **Architecture**: Service/model/route separation, circular imports, layering compliance.
6. **Review defenses**: Count `# REVIEW-DEFENSE:` comments (`grep -rn "REVIEW-DEFENSE:" src/`). Flag any that reference resolved issues, deleted ADRs, or code patterns that have since been refactored. Stale defenses are comment noise.
7. **TODO-family comment triage**: The `CODE_METRICS` section from `retro-gather.sh` includes per-pattern counts and up to 25 sample matches for: `TODO`, `FIXME`, `HACK`, `XXX`, `NOCOMMIT`, `TEMP`, `KLUDGE`, `WORKAROUND`, `BUG`, `REVISIT`, `DEPRECATED`. For each match, evaluate whether it is: (a) a genuine deferred task → create a P3 ticket task during Phase 4; (b) a historical note that is now resolved → candidate for Quick Wins removal; (c) a defense comment that belongs as `# REVIEW-DEFENSE:` → refactor during Phase 4. Do not flag matches where the comment is a legitimate in-progress annotation with a linked issue ID.
8. **Shift-left CI analysis**: Using the `CI_SHIFT_LEFT` section from `retro-gather.sh`, categorize each failed CI job into one of: `unit`, `lint`, `type-check`, `integration`, `e2e`, `build`, `other`. Then for each failure category, identify the **earliest gate** that could catch it and the **gap** preventing it from being caught there:

   | Failure category | Earliest possible gate | Common gaps |
   |-----------------|----------------------|-------------|
   | `lint` / `type-check` | pre-commit hook | hook not installed; mypy/ruff not in pre-commit config |
   | `unit` | local `make test-unit-only` | missing test for the changed function; assertion not covering the failure path |
   | `integration` | local `make test-integration` | no unit mock that would have caught the contract mismatch |
   | `e2e` | local `make test-e2e` or unit mock | no unit/integration coverage for the failing user flow |
   | `build` | `make format-check` or `poetry lock` pre-push | missing lock-file update gate |

   For each identified gap, produce a finding: `{ "category": "<failure-type>", "gate": "<earliest>", "gap": "<what is missing>", "recommendation": "<specific test or hook to add>" }`. If the CI run history is empty or all runs pass, report "No recent CI failures — shift-left baseline is healthy."

### Structured Review

Read [docs/review-criteria.md](docs/review-criteria.md) for the full reviewer configuration, launch instructions, and aggregation rules.

Invoke `/dso:review-protocol` with:

- **subject**: "Codebase Health Assessment"
- **artifact**: The collected metrics from the data collection step above
- **pass_threshold**: 4
- **start_stage**: 2 (data collection above serves as Stage 1)
- **perspectives**: Load from the following reviewer files:

| Perspective | Reviewer File |
|-------------|---------------|
| Test Quality | [docs/reviewers/test-quality.md](docs/reviewers/test-quality.md) |
| Documentation | [docs/reviewers/documentation.md](docs/reviewers/documentation.md) |
| Code Quality | [docs/reviewers/code-quality.md](docs/reviewers/code-quality.md) |
| Naming Conventions | [docs/reviewers/naming-conventions.md](docs/reviewers/naming-conventions.md) |
| Architecture | [docs/reviewers/architecture.md](docs/reviewers/architecture.md) |

### Output

Report the `/dso:review-protocol` JSON output, categorized by perspective. Include raw counts and top offenders from data collection alongside the structured scores.

---

## Phase 3: Findings Report (/dso:retro)

Present consolidated findings for user scope confirmation.

### Categorization

Group findings into three priority tiers:

- **Critical (P0-P1)**: Test/CI failures, ticket health < 3, blocked issues, circular dependencies; shift-left gaps where a recurring CI failure has no earlier detection gate at all
- **Improvement (P2)**: Outdated deps, code smells, test quality issues, ticket health 3-4, stale worktrees; shift-left gaps where a test exists but doesn't cover the failure path (missing assertion, wrong mock boundary)
- **Cleanup (P3-P4)**: KNOWN-ISSUES archival, TODO/FIXME/HACK comments (deferred tasks), naming issues, doc updates, outdated plugins; shift-left findings where the gap is a pre-commit hook or lock-file update step

### User Confirmation

Use AskUserQuestion to present findings by tier with estimated effort, then ask which categories to include in the remediation epic. Options: All, Critical + Improvement only, Critical only, Cancel.

---

## Phase 4: Epic Creation (/dso:retro)

Create a ticket epic with remediation tasks based on user-confirmed scope.

### Steps

1. **Create epic**: `.claude/scripts/dso ticket create epic "Retro: {YYYY-MM-DD} - {key-findings-summary}"` with description documenting assessment date, health score, top 3 findings, and target outcome.

2. **Create child tasks**: For each finding in scope, create a task with appropriate type/priority. Each task description must include: Issue (what), Location (file paths), Acceptance Criteria (checkboxes), and Context (why it matters).

3. **Add dependencies** where task order matters (e.g., worktree cleanup before orphan resolution).

4. **Validate ticket health**: Run `validate-issues.sh`. Fix any issues before proceeding.

5. **Report**: Epic ID/title, task counts by priority, dependency graph, ready tasks, recommended starting point.

---

## Phase 5: Quick Wins (Optional) (/dso:retro)

Fix trivial items immediately. Skip entirely if session usage is high.

### Eligible Items

Only items completable in <5 minutes with zero risk:
- Archiving resolved KNOWN-ISSUES entries (move to RESOLVED section, preserve content)
- Removing stale worktrees (after standard safety checks per CLAUDE.md)
- Removing trailing whitespace
- Updating outdated documentation references (if replacement is clear)
- Removing stale `# REVIEW-DEFENSE:` comments where the defended pattern has been refactored or the referenced artifact no longer exists

Any item requiring tests or validation is NOT a quick win.

### Execution

Ask user: "X trivial items can be fixed now (Est: Y minutes). Fix them immediately?"

If yes: execute sequentially, one commit per fix, close corresponding task after each. If no: leave all tasks in epic.

---

## Guardrails

1. **Discovery, not implementation** — identify and plan, don't fix everything in one session
2. **No closing existing issues** — only close tasks created during this retro (and only if fixed during Quick Wins)
3. **No scope creep** — new issues discovered during Quick Wins get added to the epic, not acted on
4. **User confirmation required** — Phase 4 requires explicit approval before creating any tasks
5. **Preserve history** — when archiving docs, move to archive section (never delete)
6. **Session limits respected** — skip Phase 5 if session usage is high

## Output

At the end of the retro, report: epic ID/title, findings summary (critical/improvement/cleanup counts), tasks created (ready/blocked counts), quick wins completed (if Phase 5 ran), current and target health scores, and next steps (`.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket list`, `/dso:sprint`).
