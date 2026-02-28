## Task
Beads ID: {id}

### Instructions
1. Run `bd show {id}` to read your full task description and acceptance criteria
   → Write checkpoint: `bd update {id} --notes="CHECKPOINT 1/6: Task context loaded ✓"`
2. Run `pwd` to confirm working directory
3. Read relevant existing code to understand patterns
   → Write checkpoint: `bd update {id} --notes="CHECKPOINT 2/6: Code patterns understood ✓"`
4. Write unit tests in the appropriate `tests/unit/` subdirectory **before implementing**
   → Write checkpoint: `bd update {id} --notes="CHECKPOINT 3/6: Tests written ✓"` (if no tests required: `"CHECKPOINT 3/6: Tests written (none required) ✓"`)
5. Implement the task following existing conventions
   → Write checkpoint: `bd update {id} --notes="CHECKPOINT 4/6: Implementation complete ✓"`
6. Run `make format-check && make lint && make test-unit-only` from app/
   → Write checkpoint: `bd update {id} --notes="CHECKPOINT 5/6: Validation passed ✓"` (or `"CHECKPOINT 5/6: Validation failed — <error summary>"` on failure)
7. **Self-check**: If your task has an `ACCEPTANCE CRITERIA` section, re-read it from the `bd show` output.
   For each criterion with a `Verify:` command, run it. If any fails, fix your implementation
   before reporting. Skip universal criteria (test/lint/format) — already verified in step 6.
   → Write checkpoint: `bd update {id} --notes="CHECKPOINT 6/6: Done ✓"`
8. **Discovered work**: If you find work outside your task scope (unhandled edge cases, missing docs, follow-on refactors), create a beads task:
   ```bash
   bd create --title="<descriptive title>" --type=task --parent=<parent-id> --priority=3
   ```
   Get your parent ID from the `bd show {id}` output (PARENT field). Do NOT create tasks for work that IS your task. Only create tasks for genuinely out-of-scope discoveries. If `bd create` fails, note the error and continue — task creation is non-fatal.
9. Report output:
   STATUS: pass|fail
   FILES_MODIFIED: path1, path2
   FILES_CREATED: path3 or none
   TESTS: N passed, N failed
   AC_RESULTS: (if ACCEPTANCE CRITERIA section present) criterion1: pass, criterion2: pass/fail
   TASKS_CREATED: beads-042, beads-043 (or "none", or "error: <reason>")

### Rules
- DO write checkpoint notes after each substep: `bd update {id} --notes="CHECKPOINT N/6: ..."`
- Do NOT: git commit, git push, bd close, bd update --status, bd dep
- You MAY run: bd create --parent=<parent-id> (for discovered work only)
- Do NOT invoke `/commit`, `/review`, or any slash-command — you are a sub-agent, not an orchestrator
- Do NOT dispatch nested Task tool calls or code-review sub-agents
- The "Task Completion Workflow" in CLAUDE.md does NOT apply to sub-agents — your task ends at step 9 (Report output)
- Do NOT modify files outside the scope of this task
- Do NOT modify files outside your working directory (e.g., if working in a worktree, never write to the main repo path)
- Follow existing code patterns and naming conventions
- Use absolute paths for scripts: $(git rev-parse --show-toplevel)/scripts/
