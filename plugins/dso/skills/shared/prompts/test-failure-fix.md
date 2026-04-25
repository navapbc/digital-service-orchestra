## Test-Failure Fix: {task_id}

Attempt: {attempt}
Parent Task: {parent_task_id}

### Decision Gate

Classify the failure and follow the matching path:

| Failure Type | Examples | Path |
|-------------|----------|------|
| **Behavioral** (assertion, runtime error, wrong output) | `AssertionError`, `KeyError`, `TypeError` at runtime, unexpected return value | **TDD path** (Steps 1-7 below) |
| **Mechanical** (import, type annotation, lint, config) | `ModuleNotFoundError`, mypy error, ruff violation, missing config key | **Mechanical path** (Steps 1m-5m below) |

If unsure, default to the TDD path -- it is strictly safer.

---

### Error Details

Test command: `{test_command}`
Exit code: {exit_code}

### Failure Context

**Stderr (last 50 lines):**
```
{stderr_tail}
```

**Changed files in this batch/commit:**
```
{changed_files}
```

**Dispatch context:** `{context}`
(One of: `commit-time`, `sprint-post-batch`, `sprint-ci-failure`)

### Project Context

Refer to CLAUDE.md (already in your context) for architecture, patterns, and conventions.

---

## TDD Path (Behavioral Failures)

### Instructions

1. Run `pwd` to confirm working directory
2. **Investigate root cause** before changing anything:
   a. Read the failing code and its callers/callees
   b. Trace the call stack from error back to origin
   c. Cross-reference `{changed_files}` with the failing test's imports -- the bug is most likely in a recently changed file
   d. If root cause is unknown: `git log --oneline -20 <file>` to find recent changes
   e. Do NOT proceed to step 3 until you can explain WHY the error occurs
2a. **Research if stuck** -- trigger this step when any of these apply:
   - Unfamiliar library behavior (e.g., SQLAlchemy session lifecycle, LangGraph state management)
   - Multiple valid approaches with non-obvious tradeoffs
   - 3+ tool calls without a clear path forward
   Use WebSearch or read official docs; follow guidelines in `${CLAUDE_PLUGIN_ROOT}/docs/RESEARCH-PATTERN.md`.
   Include findings in the ROOT_CAUSE report line.
3. **RED -- Write a failing test FIRST**:
   a. Create a test in the appropriate `tests/unit/` subdirectory
   b. The test must assert the CORRECT behavior (what should happen after the fix)
   c. Run: `cd $(git rev-parse --show-toplevel)/app && poetry run pytest <test_file>::<test_name> -v`
   d. Confirm the test FAILS
   e. If it passes immediately, your test does not capture the bug -- rethink
4. **GREEN -- Implement the minimal fix** -- change ONLY what is necessary
5. Run the test again -- confirm it PASSES
6. Run full validation -- capture verbose output to disk to keep the orchestrator's context lean:
   ```bash
   _REPO=$(git rev-parse --show-toplevel)
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
   _RESULT="$(get_artifacts_dir)/agent-result-{task_id}.md"
   mkdir -p "$(dirname "$_RESULT")"
   { cd "$_REPO/app" && make format-check && make lint && make test-unit-only; } > "$_RESULT" 2>&1
   TEST_EXIT=$?
   # Show only the tail -- full output is in $_RESULT
   tail -5 "$_RESULT"
   ```
   - If `TEST_EXIT != 0`: revert any source code changes that broke tests (`git checkout -- <files>`) — do NOT revert `.test-index` entries that YOU added as part of a RED test in this session (those are intentional TDD metadata). Do NOT add RED markers to `.test-index` to mask pre-existing failures — RED markers are exclusively for TDD (tests expected to fail because the feature under test is not yet implemented). If the test gate blocks due to pre-existing failures, create a bug ticket instead.
7. **Your final response MUST contain ONLY the structured report below.** See Output Format section.

---

## Mechanical Path (Import / Type / Lint Failures)

### Instructions

1m. Run `pwd` to confirm working directory
2m. Read the failing code -- understand what's wrong before changing anything
2ma. **Research if stuck** -- if the fix isn't obvious after reading the code and multiple approaches are plausible, consult `${CLAUDE_PLUGIN_ROOT}/docs/RESEARCH-PATTERN.md` before guessing. Use `WebSearch` inline (max 3 searches, max 2 fetches) only for external knowledge gaps. Skip if the answer is visible in the codebase.
3m. Implement the minimal fix -- change ONLY what is necessary
4m. Run full validation -- same as TDD path Step 6 above (capture to disk, show tail only)
   - If `TEST_EXIT != 0`: revert source code changes that broke tests — do NOT revert `.test-index` entries you added as part of TDD, then report FAIL below. Do NOT add RED markers to mask pre-existing failures.
5m. **Your final response MUST contain ONLY the structured report below.** See Output Format section.

---

## Output Format

**Two-file protocol**: When `{context}` is `sprint-post-batch` or `sprint-ci-failure`, OR when stderr exceeds 100 lines, write verbose output to disk and return only the structured report. For `commit-time` with short stderr, inline the report directly.

```
RESULT: PASS | FAIL | PARTIAL
ISSUE_ID: {task_id}
FILES_MODIFIED: <path1>, <path2>, ... (or "none")
FILES_CREATED: <path1>, <path2>, ... (or "none")
ROOT_CAUSE: <1-2 sentence explanation>
TESTS: <N> passed, <M> failed
CONCERNS: <any remaining issues, or "none">
TASKS_CREATED: <ticket-id1>, <ticket-id2> (or "none", or "error: <reason>")
```

Verbose output location (when two-file protocol is active):
```
$(get_artifacts_dir)/agent-result-{task_id}.md
```

---

### Rules

Read `${CLAUDE_PLUGIN_ROOT}/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules. Key constraints:
- Do NOT: `git commit`, `git push`, `.claude/scripts/dso ticket transition`, `.claude/scripts/dso ticket link`
- You MAY run: `.claude/scripts/dso ticket create bug "<title>" --parent={parent_task_id}` for discovered work outside your fix scope
- Do NOT skip, disable, or delete any tests
- Do NOT add `# type: ignore`, `# noqa`, `@pytest.mark.skip`, or any suppression comments
- Do NOT modify files outside the scope of this fix
- If you discover additional unrelated bugs, create a bug ticket and include the ID in TASKS_CREATED

### File Ownership Boundaries

{file_ownership_context}

If the above section is populated, respect these boundaries:
- Only modify files listed under "You own"
- Do NOT modify files listed under "Other agents own" — if you need changes there, note the dependency in your report
- If you discover you need to modify a file outside your ownership, report it in CONCERNS instead of modifying it

### Anti-Patterns (Never Do These)

| Anti-Pattern | Why It's Wrong | Do This Instead |
|-------------|----------------|-----------------|
| `# type: ignore` | Hides real type errors | Fix the type mismatch |
| `@pytest.mark.skip` | Hides real test failures | Fix the test or the code |
| `# noqa` | Hides lint violations | Fix the code |
| Fixing symptoms not causes | Cascade of new errors | Trace to root cause first |
| Guessing at fixes | Introduces new bugs | Read code, trace data flow |
| Fixing multiple things at once | Can't isolate what worked | One logical fix, then verify |
| Scope creep ("while I'm here...") | Unrelated changes risk regressions | Note it for a separate issue |
| Adding RED markers to `.test-index` for pre-existing failures | RED markers are for TDD only — masking failures bypasses the test gate contract | Fix the failing test, or create a bug ticket for it |
