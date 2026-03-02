# Sub-Agent Boundaries

Rules for all sub-agents dispatched by orchestrators (`/sprint`, `/debug-everything`, ad-hoc Task calls). Orchestrators include this file in sub-agent prompts via reference or inline.

## Prohibited Actions

Sub-agents must NOT:
- `git commit`, `git push` — orchestrator handles all commits
- `bd close`, `bd dep`, `bd update --status` — orchestrator manages issue lifecycle
- Invoke `/commit`, `/review`, or any slash-command — sub-agents are workers, not orchestrators
- Dispatch nested Task tool calls or code-review sub-agents
- Modify files outside the scope of their assigned task
- Modify files outside `$(git rev-parse --show-toplevel)` (worktree boundary)
- Skip, disable, or delete any tests
- Add `# type: ignore`, `# noqa`, `@pytest.mark.skip`, or any suppression comments
- Follow the "Task Completion Workflow" in CLAUDE.md — that applies to orchestrators only

**Resolution sub-agents** (launched via `review-fix-dispatch.md`) have an additional prohibition:
- MUST NOT dispatch a nested re-review Task tool call. Two levels of nesting
  (orchestrator → resolution → re-review) cause `[Tool result missing due to internal error]`.
  Resolution sub-agents apply fixes only and return `RESOLUTION_RESULT: FIXES_APPLIED`.
  The orchestrator dispatches re-review sub-agents after the resolution agent returns.
  See CLAUDE.md Never Do These rule 23.

## Required Actions

Sub-agents MUST:
- Run `pwd` first to confirm working directory
- Write code + tests (TDD: tests before implementation when possible)
- Run `make format-check && make lint && make test-unit-only` from `app/` as final validation
- Write checkpoint notes: `bd update {id} --notes="CHECKPOINT N/6: ..."`
- Use absolute paths for scripts: `$(git rev-parse --show-toplevel)/scripts/`
- Follow existing code patterns and naming conventions
- Read code before modifying it

## Permitted Actions

Sub-agents MAY:
- `bd create --parent=<parent-id>` for genuinely out-of-scope discovered work only
- `bd update <id> --notes="..."` for checkpoint progress notes
- Read any file in the repo to understand context

## Worktree Sessions

When running in a worktree:
- Only modify files under `$(git rev-parse --show-toplevel)`
- `.claude/` and `scripts/` always live at `$(git rev-parse --show-toplevel)` — never relative to CWD
- Memory files are at `~/.claude/projects/<encoded-worktree-path>/memory/`

## Model Selection

| Model | Use for |
|-------|---------|
| `haiku` | Structured I/O, validation-only, classification |
| `sonnet` | Code generation, code review, standard implementation |
| `opus` | Architecture decisions, high-blast-radius changes, safeguard files |

Escalation on failure: haiku -> sonnet -> opus.

## Checkpoint Protocol

Sub-agents write progress via `bd update {id} --notes="CHECKPOINT N/6: ..."`:

| Checkpoint | Meaning |
|-----------|---------|
| 1/6 | Task context loaded |
| 2/6 | Code patterns understood |
| 3/6 | Tests written (or "none required") |
| 4/6 | Implementation complete |
| 5/6 | Validation passed (or "failed — summary") |
| 6/6 | Done |

## Report Format

Sub-agent final message must include:
```
STATUS: pass|fail
FILES_MODIFIED: path1, path2
FILES_CREATED: path3 or none
TESTS: N passed, N failed
AC_RESULTS: criterion1: pass/fail (if acceptance criteria present)
TASKS_CREATED: beads-id1, beads-id2 (or "none", or "error: reason")
```

## Recovery

Orchestrators recover interrupted sub-agents via checkpoint notes:
- CHECKPOINT 5/6 or 6/6 → fast-close (spot-check files, close task)
- CHECKPOINT 3/6 or 4/6 → re-dispatch with resume context
- CHECKPOINT 1/6 or 2/6 or missing → revert to open, full re-execution
