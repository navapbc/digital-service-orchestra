## Task
Ticket ID: {id}

### Instructions
1. Run `ticket show {id}` to read your full task description and acceptance criteria
   → Write checkpoint: `ticket comment {id} "CHECKPOINT 1/6: Task context loaded ✓"`
2. Run `pwd` to confirm working directory
3. Read relevant existing code to understand patterns
   → Write checkpoint: `ticket comment {id} "CHECKPOINT 2/6: Code patterns understood ✓"`
4. Write unit tests in the appropriate `tests/unit/` subdirectory **before implementing**
   → Write checkpoint: `ticket comment {id} "CHECKPOINT 3/6: Tests written ✓"` (if no tests required: `"CHECKPOINT 3/6: Tests written (none required) ✓"`)
5. Implement the task following existing conventions
   → Write checkpoint: `ticket comment {id} "CHECKPOINT 4/6: Implementation complete ✓"`
6. Run `make format-check && make lint && make test-unit-only` from app/
   → Write checkpoint: `ticket comment {id} "CHECKPOINT 5/6: Validation passed ✓"` (or `"CHECKPOINT 5/6: Validation failed — <error summary>"` on failure)
7. **Self-check**: If your task has an `ACCEPTANCE CRITERIA` section, re-read it from the `ticket show` output.
   For each criterion with a `Verify:` command, run it. If any fails, fix your implementation
   before reporting. Skip universal criteria (test/lint/format) — already verified in step 6.
   **Shell compatibility**: `!` (bang negation) is not portable across shells. If a `Verify:` command uses `! cmd`, rewrite it as `{ cmd; test $? -ne 0; }` before running. Example: `! grep -q PAT file` → `{ grep -q PAT file; test $? -ne 0; }`
   → Write checkpoint: `ticket comment {id} "CHECKPOINT 6/6: Done ✓"`
8. **Discovered work**: If you find bugs or defects outside your task scope (unhandled edge cases, anti-patterns, regressions), create a bug ticket:
   ```bash
   ticket create "<descriptive title>" -t bug -p 3 --parent=<parent-id>
   ```
   Get your parent ID from the `ticket show {id}` output (PARENT field). Use `-t bug` for discovered defects and anti-patterns so they are correctly classified for triage. Do NOT create tasks for work that IS your task. Only create tasks for genuinely out-of-scope discoveries. If `ticket create` fails, note the error and continue — task creation is non-fatal.
8a. **Write discovery file** (best-effort): If during execution you encountered bugs, missing dependencies, API changes, or convention violations, write a discovery file so the orchestrator can propagate findings to the next batch:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   # Resolve CLAUDE_PLUGIN_ROOT: prefer env var, fall back to plugins/dso under repo root.
   # This prevents sub-agents from writing discovery files to .claude/ (protected dir).
   _DEPS_SH="${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}/hooks/lib/deps.sh"
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
   AC_RESULTS: (if ACCEPTANCE CRITERIA section present) criterion1: pass, criterion2: pass/fail
   TASKS_CREATED: ticket-042, ticket-043 (or "none", or "error: <reason>")
   DISCOVERIES_WRITTEN: yes|no|error

### Rules
Read and follow `${CLAUDE_PLUGIN_ROOT}/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules (prohibited/required/permitted actions, checkpoint protocol, report format). Key points:
- DO write checkpoint notes after each substep: `ticket comment {id} "CHECKPOINT N/6: ..."`
- Do NOT: git commit, git push, ticket transition, ticket link, slash-commands, nested Task calls
- You MAY run: ticket create -t bug --parent=<parent-id> (for discovered bugs/defects only)
- Your task ends at step 9 (Report output) — the orchestrator handles commits and issue lifecycle

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
