## Task
Ticket ID: {id}

### Pre-Step: Git Root Verification (isolation:worktree only)

If `ORCHESTRATOR_ROOT` is set in this prompt (injected by the orchestrator when `worktree.isolation_enabled=true`), verify your working directory root differs from the orchestrator's root before doing anything else:

```bash
SUB_AGENT_ROOT=$(git rev-parse --show-toplevel)
if [ "$SUB_AGENT_ROOT" = "$ORCHESTRATOR_ROOT" ]; then
  echo "ERROR: Sub-agent git root matches orchestrator root — isolation not in effect" >&2
  exit 1
fi
echo "Git root verified: $SUB_AGENT_ROOT (differs from orchestrator root: $ORCHESTRATOR_ROOT)"
```

If `ORCHESTRATOR_ROOT` is not present in this prompt, skip this check and continue.

**CWD lock (isolation:worktree mode)**: When `ORCHESTRATOR_ROOT` is set, your current working directory at startup IS your isolated worktree root. Treat it as authoritative for all operations in this session:
- Do NOT `cd` to `ORCHESTRATOR_ROOT` or any path derived from it.
- Do NOT use `ORCHESTRATOR_ROOT` as a base path for any git command, file read, or file write.
- All `git` commands (status, add, diff, log) operate on your isolation branch — not the session branch. This is correct and expected.
- When computing `REPO_ROOT` for script paths (e.g., `.claude/scripts/dso`), always use `git rev-parse --show-toplevel` from your current directory — never substitute `ORCHESTRATOR_ROOT`.
- The branch name you record in WORKTREE_TRACKING is your isolation branch (output of `git rev-parse --abbrev-ref HEAD` from your CWD), not the orchestrator's session branch.

### Instructions

**Retry Budget contract**: If the task description contains a `## Retry Budget` block (see implementation-plan SKILL.md Step 3 → Retry Budget), respect the `MAX_ATTEMPTS` cap declared in that block. On terminal failure (you cannot complete the task within budget), emit a final report containing the full failure context — failing test output, files modified, error messages, and a brief diagnosis — so the orchestrator can pass that context to the opus escalation tier.

Post WORKTREE_TRACKING:start on this task ticket (fail silently if .tickets-tracker/ unavailable):
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
6. Run `make format-check && make lint && make test-unit-only` from app/
   → On pass: Write checkpoint: `.claude/scripts/dso ticket comment {id} "CHECKPOINT 5/6: Validation passed ✓"`
   → On failure: **Investigate before retrying.** Do NOT revert and try a different approach without first understanding WHY the tests failed:
     a. Identify WHICH specific tests failed (not just "4 tests failed")
     b. Read the failing test code and trace the failure to your change
     c. Determine: did your change break these tests, or were they pre-existing failures? (`git stash && make test-unit-only && git stash pop` to compare)
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

These 5 anti-patterns are **never** acceptable ways to make tests pass. They hide the root cause rather than fixing it. Treat any impulse to use them as a signal that you need to investigate deeper.

**1. Skipping or removing tests**

Removing or skipping a failing test hides the real failure instead of fixing it.

```python
# PROHIBITED
@pytest.mark.skip(reason="flaky")
def test_important_behavior():
    ...
```

Do this instead: Fix the underlying code so the test passes. If the test is genuinely wrong, update the assertion to reflect the correct expected behavior and document why.

**2. Loosening assertions**

Weakening assertions so a test passes without fixing the underlying logic masks the bug.

```python
# PROHIBITED — changed from assertEqual to assertIn just to pass
assert result in [expected, None]  # was: assert result == expected
```

Do this instead: Fix the implementation so the original assertion holds. If the spec changed, update the assertion to the new correct value with a comment explaining the change.

**3. Broad exception handlers**

Catching broad exceptions swallows errors and hides the root cause, making tests appear to pass when they should fail.

```python
# PROHIBITED
try:
    result = do_something()
except Exception:
    pass  # silently ignore all failures
```

Do this instead: Catch only the specific exception you expect and handle it correctly. Let unexpected exceptions propagate so failures are visible.

**4. Downgrading error severity**

Changing an assertion or error to a warning so execution continues covers up a genuine failure.

```python
# PROHIBITED
# was: assert result == expected
import warnings
warnings.warn(f"result {result!r} does not match {expected!r}")
```

Do this instead: Fix the root cause so the assertion passes. If severity genuinely changed, document the reasoning explicitly.

**5. Commenting out failing code**

Commenting out the code that causes a failure hides the defect without resolving it.

```python
# PROHIBITED
# assert check_integrity(data), "data integrity check failed"
```

Do this instead: Understand why the check fails and fix the underlying data or logic so the check passes.

**6. Reverting and retrying without investigating**

Reverting a fix attempt and trying a different approach without understanding WHY the tests failed leads to repeated failures of the same kind.

```python
# PROHIBITED pattern (behavioral, not code):
# Attempt 1: change X → tests fail → revert
# Attempt 2: change Y → tests fail → revert
# Attempt 3: change Z → tests fail → revert
# Result: "needs more care" / deferred
```

Do this instead: When tests fail after your change, investigate the specific test failures BEFORE reverting. Read the failing test, trace the dependency chain, and understand what your change broke and why. The next attempt must be informed by the previous failure's root cause.

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
