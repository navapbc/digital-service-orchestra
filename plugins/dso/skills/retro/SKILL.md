---
name: retro
description: Use when performing periodic project health reviews, repo maintenance, code cleanup, dead-code sweeps, unused-dependency audits, stale-branch / stale-worktree cleanup, test quality / coverage-gap audits, CI failure pattern review, or technical-debt triage. Runs retro-gather.sh to collect CI failure metrics, TODO-family comment counts, validation health, and worktree state; classifies each finding via a shift-left analysis (was this catchable earlier?); produces a candidate task list (P3 maintenance tickets, Quick Wins for <5-minute removals, follow-ups) and writes the approved tasks to the tracker. Trigger phrases include 'project health check', 'code cleanup', 'dead code', 'unused dependencies', 'stale branches', 'stale worktrees', 'coverage gaps', 'repo maintenance', 'tech debt', 'retro', 'audit the tests', 'CI is flaky'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:retro requires Agent tool; invoke from orchestrator."
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

## Phase A: Health Assessment (/dso:retro)

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

## Phase B: Codebase Review (/dso:retro)

Gather codebase metrics, then invoke `/dso:review-protocol` for structured assessment.

### Data Collection

The `retro-gather.sh` output (from Phase A) already includes `TEST_METRICS`, `CODE_METRICS`, and `KNOWN_ISSUES` sections. Use those as the raw data baseline.

For the review, additionally check (not covered by the script):
1. **Test quality**: Identify files with no assertions, excessive mocking (10+ mocks per test), generic names (`test_1`, `test_basic`).
2. **Documentation**: Check README/CLAUDE.md for deprecated references.
3. **Code quality**: Deep nesting (4+ levels), duplicate patterns, complex functions (>50 lines).
4. **Naming**: Module (snake_case), class (PascalCase), function (snake_case), constant (UPPER_CASE) consistency.
5. **Architecture**: Service/model/route separation, circular imports, layering compliance.
6. **Review defenses**: Count `# REVIEW-DEFENSE:` comments (`grep -rn "REVIEW-DEFENSE:" src/`). Flag any that reference resolved issues, deleted ADRs, or code patterns that have since been refactored. Stale defenses are comment noise.
7. **TODO-family comment triage**: The `CODE_METRICS` section from `retro-gather.sh` includes per-pattern counts and up to 25 sample matches for: `TODO`, `FIXME`, `HACK`, `XXX`, `NOCOMMIT`, `TEMP`, `KLUDGE`, `WORKAROUND`, `BUG`, `REVISIT`, `DEPRECATED`. For each match, evaluate whether it is: (a) a genuine deferred task → create a P3 ticket task during Phase D; (b) a historical note that is now resolved → candidate for Quick Wins removal; (c) a defense comment that should be recorded via the DefenseStore pipeline (see `docs/contracts/review-defenses.md` and `REVIEW-WORKFLOW.md` R5) rather than left as an informal comment → flag for removal or formalization during Phase D. Do not flag matches where the comment is a legitimate in-progress annotation with a linked issue ID.
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

## Phase C: Findings Report (/dso:retro)

Present consolidated findings for user scope confirmation.

### Categorization

Group findings into three priority tiers:

- **Critical (P0-P1)**: Test/CI failures, ticket health < 3, blocked issues, circular dependencies; shift-left gaps where a recurring CI failure has no earlier detection gate at all
- **Improvement (P2)**: Outdated deps, code smells, test quality issues, ticket health 3-4, stale worktrees; shift-left gaps where a test exists but doesn't cover the failure path (missing assertion, wrong mock boundary)
- **Cleanup (P3-P4)**: KNOWN-ISSUES archival, TODO/FIXME/HACK comments (deferred tasks), naming issues, doc updates, outdated plugins; shift-left findings where the gap is a pre-commit hook or lock-file update step

**Fix-vs-build tiebreaker**: When a finding has a direct current-state fix (e.g., adding missing rows to an existing table, verifying a bounded set of files, correcting a known path), create a task to apply that fix — not to build a system that would prevent the gap in future. New infrastructure proposals are only appropriate when the fix requires tooling that does not exist. A task to "complete the routing table" is always preferred over "build an agent metadata system".

### User Confirmation

Use AskUserQuestion to present findings by tier with estimated effort, then ask which categories to include in the remediation epic. Options: All, Critical + Improvement only, Critical only, Cancel.

---

## Bug Classification (MANDATORY)

Read config values before running (defaults: retro_window_days=60, recurrence_threshold=3):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
RETRO_WINDOW=$(bash "$PLUGIN_SCRIPTS/read-config.sh" bug_classification.retro_window_days 2>/dev/null || echo 60)  # shim-exempt: SKILL.md orchestrator-direct invocation, legacy pattern pre-dating PR-E
RECURRENCE_THRESHOLD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" bug_classification.recurrence_threshold 2>/dev/null || echo 3)  # shim-exempt: SKILL.md orchestrator-direct invocation, legacy pattern pre-dating PR-E
RETRO_WINDOW="${RETRO_WINDOW:-60}"
RECURRENCE_THRESHOLD="${RECURRENCE_THRESHOLD:-3}"
```

Run:
  .claude/scripts/dso bug-classification-stats.sh --window-days "${RETRO_WINDOW}"

For each finding, fire a DISTINCT labeled finding when any threshold is reached:
- When `bug-type-uncategorized` count >= ${RECURRENCE_THRESHOLD}: add labeled finding `bug-type-uncategorized`
- When any registry slug count >= ${RECURRENCE_THRESHOLD}: add labeled finding for that slug
- When ANY `bug-type-classifier-failed-*` tag is present (threshold=1): add labeled finding `bug-type-classifier-failed`

When NO threshold fires, emit exactly:
  Bug classification health: no threshold breaches in this window.

---

## Phase D: Epic Creation (/dso:retro)

Create a ticket epic with remediation tasks based on user-confirmed scope.

### Steps

1. **Create epic**: `.claude/scripts/dso ticket create epic "Retro: {YYYY-MM-DD} - {key-findings-summary}"` with description documenting assessment date, health score, top 3 findings, and target outcome.

2. **Create child tasks**: For each finding in scope, create a task with appropriate type/priority. Each task description must include: Issue (what), Location (file paths), Acceptance Criteria (checkboxes), and Context (why it matters).

   **Before creating each task**: ask "Is there a direct fix to the current-state problem?" If yes, create a task to APPLY that fix. Only propose new infrastructure if no direct fix is possible. A current-state remediation task is always preferred over a meta-process task.

3. **Add dependencies** where task order matters (e.g., worktree cleanup before orphan resolution).

4. **Validate ticket health**: Run `validate-issues.sh`. Fix any issues before proceeding.

5. **Report**: Epic ID/title, task counts by priority, dependency graph, ready tasks, recommended starting point.

---

## Phase E: Quick Wins (Optional) (/dso:retro)

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

## Phase F: Quarterly Inference-Incident Curation (/dso:retro)

Quarterly append step for the inference-incident corpus consumed by `inference-recall-replay.sh`. Wires the `dso:inference-incident-curator` agent into a recurring cadence (~90 days) so the corpus grows from new closed tickets over time. See `${CLAUDE_PLUGIN_ROOT}/docs/contracts/inference-incident-schema.md` for the record shape and `docs/findings/project-audit-2026-05-19.md` Q2 for the wire-up rationale (R21 follow-up).

### Cadence Gate (STOP HERE if SHOULD_RUN=false)

Check `${CLAUDE_PLUGIN_ROOT}/data/fixtures/inference-incidents/last-curator-run.json` for the previous run's UTC timestamp. If the timestamp exists and is less than 90 days old, **skip the rest of Phase F** and proceed to Guardrails:

```bash
LAST_RUN_FILE="${CLAUDE_PLUGIN_ROOT}/data/fixtures/inference-incidents/last-curator-run.json"
NOW_TS=$(date -u +%s)
SHOULD_RUN=true
if [[ -f "$LAST_RUN_FILE" ]]; then
    LAST_TS=$(jq -r '.last_run_unix // 0' "$LAST_RUN_FILE" 2>/dev/null || echo 0)
    if (( NOW_TS - LAST_TS < 90 * 24 * 3600 )); then
        echo "Phase F: skipped (curator ran $(( (NOW_TS - LAST_TS) / 86400 )) days ago; cadence is 90 days)"
        SHOULD_RUN=false
    fi
fi
```

When `SHOULD_RUN=false`, the orchestrator MUST proceed directly to the Guardrails section. The Curator Dispatch and Corpus Append blocks below are wrapped in `if [[ "$SHOULD_RUN" == "true" ]]; then ... fi` to make this gating explicit for any literal shell execution.

### Curator Dispatch (when cadence threshold reached)

Dispatch the named agent via the Agent tool with `subagent_type: "dso:inference-incident-curator"` and `model: "opus"`. The agent's documented purpose: scan closed tickets via `.claude/scripts/dso ticket list` and per-ticket comments/transitions, identify inference incidents per the contract anchors (assumption/correction/uncertainty/outcome markers), emit JSONL records conforming to `inference-incident-schema.md`.

The agent's output contract:
- Wrapped in the `inference-envelope` form (see `${CLAUDE_PLUGIN_ROOT}/docs/contracts/inference-envelope.md`).
- Emits one validated incident JSON per line on stdout.
- Emits `CORPUS_INSUFFICIENT` signal if fewer than 20 validated incidents are found.

After the dispatch returns, capture the agent's stdout to a temp file for the append step:

```bash
if [[ "$SHOULD_RUN" == "true" ]]; then
    NEW_INCIDENTS_FILE=$(mktemp /tmp/inference-incidents-new.XXXXXX.jsonl)
    # Write the curator agent's JSONL stdout to "$NEW_INCIDENTS_FILE" via the
    # orchestrator's Agent-tool transcript (the agent emits one JSON record per
    # line; the orchestrator extracts those lines and writes them here).
fi
```

### Corpus Append + Timestamp Update

If the curator emitted at least one valid record, append to the corpus and update the run timestamp. The append block is gated on `SHOULD_RUN=true` and on the temp file being non-empty:

```bash
if [[ "$SHOULD_RUN" == "true" && -s "$NEW_INCIDENTS_FILE" ]]; then
    cat "$NEW_INCIDENTS_FILE" >> "${CLAUDE_PLUGIN_ROOT}/data/fixtures/inference-incidents/incidents.jsonl"
    printf '{"last_run_unix": %s, "last_run_iso": "%s"}\n' \
        "$NOW_TS" "$(date -u -r "$NOW_TS" +%Y-%m-%dT%H:%M:%SZ)" \
        > "$LAST_RUN_FILE"
    rm -f "$NEW_INCIDENTS_FILE"
elif [[ "$SHOULD_RUN" == "true" ]]; then
    # CORPUS_INSUFFICIENT or zero records — advance the cadence timestamp anyway so the
    # gate doesn't re-fire on every retro until the ticket history grows.
    printf '{"last_run_unix": %s, "last_run_iso": "%s"}\n' \
        "$NOW_TS" "$(date -u -r "$NOW_TS" +%Y-%m-%dT%H:%M:%SZ)" \
        > "$LAST_RUN_FILE"
    rm -f "$NEW_INCIDENTS_FILE"
fi
```

### Post-Append Validation

After appending, validate that the corpus's new tail parses as well-formed JSONL with the required schema fields. Direct `jq` validation is the lowest-cost check; `inference-recall-replay.sh` does not currently expose a validate-only mode, so we don't invoke it here.

Required fields per `inference-incident-schema.md`: `ticket_id`, `inferred_decision_text`, `affects_fields`, `outcome`, `source_decision_text` (all 5 must be non-null on every record).

```bash
if [[ "$SHOULD_RUN" == "true" && -f "${CLAUDE_PLUGIN_ROOT}/data/fixtures/inference-incidents/incidents.jsonl" ]]; then
    _corpus_file="${CLAUDE_PLUGIN_ROOT}/data/fixtures/inference-incidents/incidents.jsonl"

    # Step 1: detect JSONL parse errors. `jq empty` exits non-zero on the FIRST
    # malformed line and writes its error to stderr; we want a count of parse
    # errors across the whole file, so iterate per line.
    _parse_errors=0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        [[ -z "$_line" ]] && continue
        if ! printf '%s' "$_line" | jq empty 2>/dev/null; then
            _parse_errors=$(( _parse_errors + 1 ))
        fi
    done < "$_corpus_file"

    # Step 2: schema check — among lines that parse, flag any record missing one
    # of the 5 required fields. Skipped when any parse error was detected
    # because jq aborts the whole file on the first bad line, so the count
    # would be unreliable.
    _bad_lines=0
    if [[ "$_parse_errors" -eq 0 ]]; then
        _bad_lines=$(jq -c -r 'select(.ticket_id == null or .inferred_decision_text == null or .affects_fields == null or .outcome == null or .source_decision_text == null)' \
            "$_corpus_file" 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [[ "${_bad_lines:-0}" -gt 0 || "${_parse_errors:-0}" -gt 0 ]]; then
        echo "WARNING: corpus validation flagged ${_bad_lines:-0} missing-field records + ${_parse_errors:-0} parse errors after curator append — review the new records"
    fi
fi
```

The validation is non-blocking — corpus issues surface as a warning rather than aborting the retro.

### Phase F Skip Conditions

In addition to the cadence gate, **skip Phase F entirely** when:
- The session is operating under high token usage (the same constraint as Phase E).
- The retro is run with `--no-curator` (user override; not implemented as a literal flag — surface as a Phase F prompt question).
- The plugin does not have `${CLAUDE_PLUGIN_ROOT}/data/fixtures/inference-incidents/` (e.g., DSO not fully onboarded).

---

## Guardrails

1. **Discovery, not implementation** — identify and plan, don't fix everything in one session
2. **No closing existing issues** — only close tasks created during this retro (and only if fixed during Quick Wins)
3. **No scope creep** — new issues discovered during Quick Wins get added to the epic, not acted on
4. **User confirmation required** — Phase D requires explicit approval before creating any tasks
5. **Preserve history** — when archiving docs, move to archive section (never delete)
6. **Session limits respected** — skip Phase E if session usage is high

## Output

At the end of the retro, report: epic ID/title, findings summary (critical/improvement/cleanup counts), tasks created (ready/blocked counts), quick wins completed (if Phase E ran), current and target health scores, and next steps (`.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket list`, `/dso:sprint`).
