## Task
Ticket ID: {id}

### Pre-Step: Isolation Self-Check (path-shape verification)

Confirm your CWD matches the isolated-worktree convention. Per bug 9679-695c-6e11-4d95, the orchestrator no longer injects its session-worktree path into your prompt — you have no canonical pointer to compare against. The check below is a tripwire for mis-configured dispatches (it does not — and cannot — fail when isolation is correctly applied):

```bash
SUB_AGENT_ROOT=$(git rev-parse --show-toplevel)
if [[ "$SUB_AGENT_ROOT" != *"/.claude/worktrees/agent-"* ]]; then
  echo "WARNING: Sub-agent root does not match the isolated-worktree convention." >&2
  echo "         Got: $SUB_AGENT_ROOT" >&2
fi
```

The check is informational — continue regardless. The platform's CWD redirection under `isolation: "worktree"` already places you in your own worktree; this just records that fact in your logs.

**CLAUDE.md path leak (bug 6b67-2aad)**: The CLAUDE.md file shown in your system context may reference the PARENT session worktree path (e.g., `Contents of /Users/.../worktree-20260523-.../CLAUDE.md`). That path is NOT your repo root — it is the orchestrator's session worktree. NEVER derive file paths from the CLAUDE.md system context path. Always use `$(git rev-parse --show-toplevel)` to construct absolute paths for Read, Edit, and Write tool calls.

#### Session HEAD Sync (worktree isolation fix)

If `SESSION_BRANCH` and `SESSION_HEAD` are both set in the environment, sync this worktree to the session HEAD:

```bash
if [[ -n "${SESSION_BRANCH:-}" && -n "${SESSION_HEAD:-}" ]]; then
    bash "${PLUGIN_SCRIPTS}/worktree-session-head-sync.sh"  # shim-exempt: internal orchestration script
    if [[ $? -ne 0 ]]; then
        echo "ERROR: worktree-session-head-sync.sh failed — aborting sub-agent execution" >&2
        exit 1
    fi
fi
```

If only one of `SESSION_BRANCH` / `SESSION_HEAD` is set (inconsistent state), emit a warning but continue:

```bash
if [[ -n "${SESSION_BRANCH:-}" && -z "${SESSION_HEAD:-}" ]] || [[ -z "${SESSION_BRANCH:-}" && -n "${SESSION_HEAD:-}" ]]; then
    echo "WARNING: SESSION_BRANCH/SESSION_HEAD partially set — skipping worktree sync" >&2
fi
```

**CWD lock (isolation:worktree mode)**: Your current working directory at startup IS your isolated worktree root. Treat it as authoritative for all operations in this session:
- All `git` commands (status, add, diff, log) operate on your isolation branch — not the session branch. This is correct and expected.
- Compute `REPO_ROOT` exclusively from `git rev-parse --show-toplevel` of YOUR CWD.
- Do NOT enumerate other worktrees via `git worktree list` and target one of them. The other entries that command returns are sibling worktrees (including the orchestrator's session worktree); writing to any of them corrupts shared state.
- Do NOT construct absolute paths outside your own worktree. If you find yourself building a string that starts with anything other than the output of `git rev-parse --show-toplevel`, stop.
- The branch name you record in WORKTREE_TRACKING is your isolation branch (output of `git rev-parse --abbrev-ref HEAD` from your CWD), not any other branch.

### Instructions

**Retry Budget contract**: If the task description contains a `## Retry Budget` block (see implementation-plan SKILL.md Step 3 → Retry Budget), respect the `MAX_ATTEMPTS` cap declared in that block. On terminal failure (you cannot complete the task within budget), emit a final report containing the full failure context — failing test output, files modified, error messages, and a brief diagnosis — so the orchestrator can pass that context to the opus escalation tier.

Post WORKTREE_TRACKING:start on this task ticket (fail silently if .tickets-tracker/ unavailable): <!-- # tickets-boundary-ok -->
```bash
_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
.claude/scripts/dso ticket comment {id} "WORKTREE_TRACKING:start branch=${_BRANCH} session_branch=${_BRANCH} timestamp=${_TS}" 2>/dev/null || true
```

1. Run `.claude/scripts/dso ticket show {id}` to read your full task description and acceptance criteria
   → Write checkpoint: `.claude/scripts/dso ticket comment {id} "CHECKPOINT 1/6: Task context loaded ✓"`
2. Run `pwd` to confirm working directory
3. **read_first gate**: Read every file listed in the ticket's file impact section before making any edits. For each file listed, read it in full to understand existing patterns and avoid duplicating logic.
   - If the task creates a new file, also perform **exemplar discovery**: extract the filename suffix (e.g., `_controller.py`, `-handler.ts`, `Controller.java`) and search for existing files with the same suffix — same directory first, then project-wide. Read 1–2 exemplars to understand structure and conventions. Cover all naming convention variants: PascalCase (`*Controller.java`), snake_case (`*_controller.py`), and kebab-case (`*-controller.ts`). If no suffix pattern is extractable (flat lowercase name, generic name like `utils.py`), skip supplemental exemplar reads.
   → Write checkpoint: `.claude/scripts/dso ticket comment {id} "CHECKPOINT 2/6: Code patterns understood (files read: <list files>; exemplars read: <list exemplars or none>) ✓"`
4. **Test validation**: Read the `## Testing Mode` value from your task description (extracted from the ticket by `.claude/scripts/dso ticket show {id}`). Branch on the value:

   - **RED** (or absent — backward-compatible default): Check for existing RED tests before writing new ones. Read the test file(s) listed in the File Impact section or search `tests/` for tests targeting the files you will modify. If existing RED tests are found, validate them (run them to confirm they fail) and flag any missing test coverage rather than writing duplicate tests. Only if no existing RED tests are found should you write new tests in the appropriate `tests/unit/` subdirectory **before implementing**.

   - **GREEN**: Skip test creation. Do NOT write new tests. After implementing, run the existing tests that cover the changed files to confirm they still pass. If they fail, your implementation has a regression — fix it. Consult `skills/shared/prompts/behavioral-testing-standard.md` for the behavioral testing standard.

   - **UPDATE**: Modify the existing test file(s) listed in the File Impact section to assert the new expected behavior **before** making any source code changes. The updated test must fail (RED) on the current code. Only after confirming the test fails should you implement the source change and verify the test passes (GREEN). Do NOT write a brand-new test file — update existing assertions in the identified test file(s).

   When writing or modifying tests, consult `skills/shared/prompts/behavioral-testing-standard.md` for the 5-rule behavioral testing standard.
   → Write checkpoint: `.claude/scripts/dso ticket comment {id} "CHECKPOINT 3/6: Tests written ✓"` (if no tests required: `"CHECKPOINT 3/6: Tests written (none required) ✓"`)
5. Implement the task following existing conventions
   - **Prior-art check**: Before writing new code, consult `skills/shared/prompts/prior-art-search.md` for existing patterns (exempt: single-file logic fixes, formatting changes)
   → Write checkpoint: `.claude/scripts/dso ticket comment {id} "CHECKPOINT 4/6: Implementation complete ✓"`
6. Run `{FORMAT_CHECK_CMD} && {LINT_CMD}`, then run unit tests via `{TEST_CMD}` (CLAUDE.md `rule:no-broad-tests-bash` — raw `make test-unit-only` may exceed the ~73s Bash-tool ceiling and get killed with exit 144)
   → On pass: Write checkpoint: `.claude/scripts/dso ticket comment {id} "CHECKPOINT 5/6: Validation passed ✓"`
   → On failure: **Investigate before retrying.** Do NOT revert and try a different approach without first understanding WHY the tests failed:
     a. Identify WHICH specific tests failed (not just "4 tests failed")
     b. Read the failing test code and trace the failure to your change
     c. Determine: did your change break these tests, or were they pre-existing failures? Use `git stash && {TEST_CMD} && git stash pop` to compare baseline vs. post-change results.
     d. If your change caused the failures: understand the dependency between your change and the failing tests before attempting a fix
     e. If pre-existing: note them and proceed (they are not your responsibility)
     f. Write checkpoint: `.claude/scripts/dso ticket comment {id} "CHECKPOINT 5/6: Validation failed — <which tests failed and why>"`
     **Reverting and blindly trying a different approach is a prohibited anti-pattern** — it produces the same class of failure repeatedly. Each retry must be informed by the investigation of the previous failure.
7. **Self-check**: If your task has an `Acceptance Criteria` section, re-read it from the `.claude/scripts/dso ticket show` output.
   For each criterion with a `Verify:` command, run it. If any fails, fix your implementation
   before reporting. Skip universal criteria (test/lint/format) — already verified in step 6.
   **Shell compatibility**: `!` (bang negation) is not portable across shells. If a `Verify:` command uses `! cmd`, rewrite it as `{ cmd; test $? -ne 0; }` before running. Example: `! grep -q PAT file` → `{ grep -q PAT file; test $? -ne 0; }`
   → Write checkpoint: `.claude/scripts/dso ticket comment {id} "CHECKPOINT 6/6: Done ✓"`
8. **Discovered work**: If you find bugs or defects outside your task scope (unhandled edge cases, anti-patterns, regressions), create a bug ticket:
   ```bash
   .claude/scripts/dso ticket create bug "<descriptive title>" --priority 3 --parent=<parent-id>
   ```
   Get your parent ID from the `.claude/scripts/dso ticket show {id}` output (PARENT field). Use `bug` as the ticket type for discovered defects and anti-patterns so they are correctly classified for triage. Do NOT create tasks for work that IS your task. Only create tasks for genuinely out-of-scope discoveries. If `.claude/scripts/dso ticket create` fails, note the error and continue — task creation is non-fatal.
8a. **Write discovery file** (best-effort): If during execution you encountered bugs, missing dependencies, API changes, or convention violations, write a discovery file so the orchestrator can propagate findings to the next batch:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   # Resolve CLAUDE_PLUGIN_ROOT: set by the DSO shim at session start.
   # This prevents sub-agents from writing discovery files to .claude/ (protected dir).
   _DEPS_SH="${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
   if [[ ! -f "$_DEPS_SH" ]]; then
     # Last-resort: write to a known /tmp/ path if deps.sh cannot be found
     DISC_DIR="/tmp/workflow-plugin-fallback/agent-discoveries"
   else
     source "$_DEPS_SH"
     DISC_DIR="$(get_artifacts_dir)/agent-discoveries"
   fi
   mkdir -p "$DISC_DIR"
   cat > "$DISC_DIR/{id}.json.tmp" << 'DISC_EOF'
   {"task_id": "{id}", "type": "<bug|dependency|api_change|convention>", "summary": "<one-line description>", "affected_files": ["<absolute-path>", ...]}
   DISC_EOF
   mv "$DISC_DIR/{id}.json.tmp" "$DISC_DIR/{id}.json"
   ```
   - Only write if you have genuine discoveries — do not write an empty file
   - Use atomic write (write `.tmp`, then `mv`) to avoid partial reads
   - If writing fails, continue — discovery writing is non-fatal and must not block task completion
8b. **Stage all changes for worktree retention** (isolation:worktree mode only):
   ```bash
   git add -A
   git status --short
   ```
   The Claude Code platform auto-cleans worktrees with no staged or committed changes. Staging ensures the platform preserves this worktree so the orchestrator can review, commit, and harvest the changes. Do NOT commit — the orchestrator handles commits via per-worktree-review-commit.md.
9. Report output:
   STATUS: pass|fail
   FILES_MODIFIED: path1, path2
   FILES_CREATED: path3 or none
   TESTS: N passed, N failed
   AC_RESULTS: (if Acceptance Criteria section present) criterion1: pass, criterion2: pass/fail
   TASKS_CREATED: ticket-042, ticket-043 (or "none", or "error: <reason>")
   DISCOVERIES_WRITTEN: yes|no|error
   CONFIDENT or UNCERTAIN:<reason>
   Confidence signal (per docs/contracts/confidence-signal.md):
   - Emit `CONFIDENT` (single keyword, own line) when you have high confidence the task is correctly and completely implemented, all acceptance criteria genuinely pass, and no significant edge cases were left unaddressed.
   - Emit `UNCERTAIN:<reason>` (keyword + colon + reason, own line, no space before reason) when you lack confidence — ambiguous task description, missing context, codebase state mismatch, untested edge cases, or unfamiliar patterns. The reason must not be empty.
   - You MUST emit exactly one of these signals. If omitted, the orchestrator treats it as UNCERTAIN with reason "no confidence signal emitted".

### Design Context

{design_context}

If the above section is populated, you are working on a story with a designer-approved Figma revision:
- **Manifest path**: The spatial-layout.json file is authoritative for behavior (interactions, states, accessibility, responsive rules)
- **Revision image path**: The figma-revision.png is authoritative for visual layout and styling
- **Precedence rule**: When the manifest and image contradict each other, flag the contradiction as [NEEDS_REVIEW] in your output and proceed with the manifest's behavioral specification
- Use the Read tool to view the revision image (multimodal capable) and the manifest JSON

### Escalation Policy

{escalation_policy}

This governs when you must stop and ask versus proceed with your best judgment.

### Rules
Read and follow `${CLAUDE_PLUGIN_ROOT}/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules (prohibited/required/permitted actions, checkpoint protocol, report format). Key points:
- DO write checkpoint notes after each substep: `.claude/scripts/dso ticket comment {id} "CHECKPOINT N/6: ..."`
- Sub-agents must NOT commit, push, or run any commit-related command. Prohibited actions include:
  - `git commit` (any form, including `git commit --amend`)
  - `/dso:commit` skill invocation
  - `git push` or `git push --force`
  - Any command that writes to git history
  - `.claude/scripts/dso ticket transition` or `.claude/scripts/dso ticket link`
  - Slash-commands or nested Task calls
- You MAY run: .claude/scripts/dso ticket create bug "<title>" --parent=<parent-id> (for discovered bugs/defects only)
- Your task ends at step 9 (Report output) — the orchestrator handles commits and issue lifecycle

### Prohibited Fix Patterns

Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/prohibited-fix-patterns.md` — six anti-patterns that hide rather than fix test failures. Treat any impulse to apply one as a signal to investigate deeper.

### Prior Batch Discoveries

{prior_batch_discoveries}

If discoveries are listed above, review them before starting implementation.
They may affect your task — check for relevant bugs, dependency changes,
API changes, or convention violations reported by agents in the previous batch.

### File Ownership Boundaries

{file_ownership_context}

If the above section is populated, respect these boundaries:
- Only modify files listed under "You own"
- Do NOT modify files listed under "Other agents own" — if you need changes there, note the dependency in your report
- If you discover you need to modify a file outside your ownership, report it in CONCERNS instead of modifying it

## Visual Evaluator Integration (Integration A)

When a task touches UI files (detected by `${CLAUDE_PLUGIN_ROOT}/scripts/detect-ui-files.sh`), the sprint orchestrator runs visual evaluation after commit and before harvest. This is **Integration A** — the inline per-task iteration loop with attribution routing.

Implementation: `${CLAUDE_PLUGIN_ROOT}/scripts/sprint/visual-eval-inline.sh` (called at per-worktree Step 4a).

### Activation Gate

Requires both `visual_evaluator.enabled=true` AND `visual_evaluator.integration_a_enabled=true` (both default false). Shared preconditions are checked via `visual-eval-preconditions.sh --route-map-required`. When any gate fails, the script emits `visual_eval_inapplicable:<reason>` and exits 0 (never blocks). <!-- # precondition-emit-ok: preconditions checked in external script -->

**Surface route_map_stale prominently**: when the skill emits `visual_eval_inapplicable:route_map_stale`, the sprint orchestrator must surface this to the user with explicit instruction to run `/dso:ui-discover` and retry. Do NOT bury in logs.

### Attribution Routing

After the visual-evaluator returns its JSON findings, route by `attribution_class` × `attribution_confidence`:

| attribution_class | confidence | Action |
|---|---|---|
| `implementation_drift` | high or medium | Re-prompt the implementing sub-agent with the finding evidence |
| `design_flaw` | high or medium | Re-dispatch `/dso:ui-designer` with the finding evidence |
| `mixed`, `uncertain`, or any class with `low` confidence | (any) | User dialog with bounding-box evidence (or `INTERACTIVITY_DEFERRED` annotation in non-interactive mode); cap at 2 user-dialog escalations per task with auto-defer beyond |

### Iteration Cap and Threshold

| Config Key | Default | Behavior |
|---|---|---|
| `visual_evaluator.iteration_cap` | `2` | Max self-correction iterations per task |
| `visual_evaluator.iteration_threshold` | `3` | Minimum `intent_match` score (1-5) to allow task closure |

**Failure modes** (conditional):

- **intent_match < threshold**: blocks task closure. After `iteration_cap` exhausted with sustained intent_match drift, the task is FAILED and reverted to open with a checkpoint comment.
- **Quality-dim shortfall** (intent_match ≥ threshold, but `whitespace_balance` / `element_density` / `visual_hierarchy_legibility` / `alignment_grid_adherence` < threshold): closure proceeds with ticket annotation `visual_debt:<dimension>` recorded via `.claude/scripts/dso ticket tag`.

### Independence from review.max_cycles

**`visual_evaluator.iteration_cap` is independent of `review.max_cycles`.** They track separate counters:

- `iteration_cap` (default 2) governs visual self-correction (Integration A inline loop)
- `review.max_cycles` (default 4) governs text-review autonomous-resolution (the code-reviewer loop)

When both fire on the same task: visual iteration runs first (post-implementation, pre-review). If visual iteration cap is exhausted, task FAILS; if visual passes (or visual_debt is annotated), the code review loop proceeds independently with its own counter.

### Regression Tests

See `tests/skills/test-sprint-task-execution-visual-eval.sh` for the three required test cases:

1. `test_sustained_intent_match_drift_fails_closure`: fixture task with intent_match<3 across 2 iterations → task FAILED, reverted to open
2. `test_quality_dim_shortfall_visual_debt_annotated`: intent_match≥3 but another dimension <3 → closure proceeds, `visual_debt:<dimension>` ticket tag applied
3. `test_mixed_uncertain_findings_auto_defer`: 3 mixed/uncertain findings → auto-defer after 2nd user-dialog escalation
