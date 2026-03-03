## Task
Ticket ID: {id}

### Instructions
1. Run `tk show {id}` to read your full task description and acceptance criteria
   → Write checkpoint: `tk add-note {id} "CHECKPOINT 1/6: Task context loaded ✓"`
2. Run `pwd` to confirm working directory
3. Read relevant existing code to understand patterns
   → Write checkpoint: `tk add-note {id} "CHECKPOINT 2/6: Code patterns understood ✓"`
4. Write unit tests in the appropriate `tests/unit/` subdirectory **before implementing**
   → Write checkpoint: `tk add-note {id} "CHECKPOINT 3/6: Tests written ✓"` (if no tests required: `"CHECKPOINT 3/6: Tests written (none required) ✓"`)
5. Implement the task following existing conventions
   → Write checkpoint: `tk add-note {id} "CHECKPOINT 4/6: Implementation complete ✓"`
6. Run `make format-check && make lint && make test-unit-only` from app/
   → Write checkpoint: `tk add-note {id} "CHECKPOINT 5/6: Validation passed ✓"` (or `"CHECKPOINT 5/6: Validation failed — <error summary>"` on failure)
7. **Self-check**: If your task has an `ACCEPTANCE CRITERIA` section, re-read it from the `tk show` output.
   For each criterion with a `Verify:` command, run it. If any fails, fix your implementation
   before reporting. Skip universal criteria (test/lint/format) — already verified in step 6.
   → Write checkpoint: `tk add-note {id} "CHECKPOINT 6/6: Done ✓"`
8. **Discovered work**: If you find work outside your task scope (unhandled edge cases, missing docs, follow-on refactors), create a ticket task:
   ```bash
   tk create "<descriptive title>" -t task -p 3 --parent=<parent-id>
   ```
   Get your parent ID from the `tk show {id}` output (PARENT field). Do NOT create tasks for work that IS your task. Only create tasks for genuinely out-of-scope discoveries. If `tk create` fails, note the error and continue — task creation is non-fatal.
9. Report output:
   STATUS: pass|fail
   FILES_MODIFIED: path1, path2
   FILES_CREATED: path3 or none
   TESTS: N passed, N failed
   AC_RESULTS: (if ACCEPTANCE CRITERIA section present) criterion1: pass, criterion2: pass/fail
   TASKS_CREATED: ticket-042, ticket-043 (or "none", or "error: <reason>")

### Rules
Read and follow `$(git rev-parse --show-toplevel)/lockpick-workflow/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules (prohibited/required/permitted actions, checkpoint protocol, report format). Key points:
- DO write checkpoint notes after each substep: `tk add-note {id} "CHECKPOINT N/6: ..."`
- Do NOT: git commit, git push, tk close, tk status, tk dep, slash-commands, nested Task calls
- You MAY run: tk create --parent=<parent-id> (for discovered work only)
- Your task ends at step 9 (Report output) — the orchestrator handles commits and issue lifecycle
