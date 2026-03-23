---
id: w22-uyaq
status: open
deps: []
links: []
created: 2026-03-22T20:08:19Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Bug: sprint-next-batch.sh overlap detection treats universal AC verification commands as file conflicts

sprint-next-batch.sh conflict matrix flags all 7 available tasks as conflicting with each other because their acceptance criteria share universal verification commands (bash tests/run-all.sh, ruff check, ruff format). These are test/lint commands that every task runs — not actual file edits. The script should only flag conflicts on files that sub-agents will CREATE or EDIT, not on shared read-only verification commands.

Example: w22-ah0i (creates contracts/classifier-size-output.md) and dso-gego (edits REVIEW-WORKFLOW.md) are flagged as conflicting because both acceptance criteria include 'bash tests/run-all.sh'. These tasks touch completely different files.

Impact: Batches are artificially limited to 1 task, eliminating all parallelism.

## File Impact
- plugins/dso/scripts/sprint-next-batch.sh (or the overlap detection logic it calls)

## ACCEPTANCE CRITERIA
- [ ] Universal AC verification commands (tests/run-all.sh, ruff check, ruff format) are excluded from overlap detection
- [ ] Tasks that only share verification commands but edit different source/test files are batched together
- [ ] Tasks with genuine source file overlaps are still correctly detected and deferred

