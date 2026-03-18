## Fix: {issue title}
Beads ID: {id}
Category: {tier name — e.g., "Type error (mypy)", "Import error", "Config issue"}

### Error Details
{exact error output — type error message, lint violation, or import error}
{include file paths and line numbers}

### Project Context
Refer to CLAUDE.md (already in your context) for architecture, patterns, and conventions.

### Instructions

1. Run `pwd` to confirm working directory
2. Read the failing code — understand what's wrong before changing anything
2a. **Research if stuck** — if the fix isn't obvious after reading the code and multiple approaches are plausible, consult `${CLAUDE_PLUGIN_ROOT}/docs/RESEARCH-PATTERN.md` before guessing. Use `WebSearch` inline (≤3 searches, ≤2 fetches) only for external knowledge gaps (library API, framework behavior, third-party error). Skip if the answer is visible in the codebase.
3. Implement the minimal fix — change ONLY what is necessary
4. Run full validation — capture verbose output to disk to keep the orchestrator's context lean:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
   RESULT_FILE="$(get_artifacts_dir)/agent-result-{id}.md"
   mkdir -p "$(dirname "$RESULT_FILE")"
   { cd "$REPO_ROOT/app" && make format-check && make lint && make test-unit-only; } > "$RESULT_FILE" 2>&1
   TEST_EXIT=$?
   # Show only the tail — full output is in $RESULT_FILE
   tail -5 "$RESULT_FILE"
   ```
   - If `TEST_EXIT != 0`: revert changes that broke tests, then report FAIL below.
5. **Write discovery file** (best-effort): If during execution you encountered bugs, missing dependencies, API changes, or convention violations outside your fix scope, write a discovery file so the orchestrator can propagate findings to the next batch:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
   DISC_DIR="$(get_artifacts_dir)/agent-discoveries"
   mkdir -p "$DISC_DIR"
   cat > "$DISC_DIR/{id}.json.tmp" << 'DISC_EOF'
   {"task_id": "{id}", "type": "<bug|dependency|api_change|convention>", "summary": "<one-line description>", "affected_files": ["<absolute-path>", ...]}
   DISC_EOF
   mv "$DISC_DIR/{id}.json.tmp" "$DISC_DIR/{id}.json"
   ```
   - Only write if you have genuine discoveries — do not write an empty file
   - Use atomic write (write `.tmp`, then `mv`) to avoid partial reads
   - If writing fails, continue — discovery writing is non-fatal and must not block task completion
6. **Your final response MUST contain ONLY the structured report below — no test output, no diffs, no tracebacks.** Verbose output is saved in `$RESULT_FILE` for post-hoc inspection.
   ```
   RESULT: PASS | FAIL | PARTIAL
   ISSUE_ID: {id}
   FILES_MODIFIED: <path1>, <path2>, ... (or "none")
   ROOT_CAUSE: <1-sentence explanation>
   TESTS: <N> passed, <M> failed
   CONCERNS: <any remaining issues, or "none">
   DISCOVERIES_WRITTEN: yes|no|error
   ```

### Rules
Read `${CLAUDE_PLUGIN_ROOT}/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules. Key constraints:
- Do NOT: `git commit`, `git push`, `tk close`, `tk status`
- Do NOT skip, disable, or delete any tests
- Do NOT add `# type: ignore`, `# noqa`, `@pytest.mark.skip`, or any suppression comments
- Do NOT modify files outside the scope of this fix

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
