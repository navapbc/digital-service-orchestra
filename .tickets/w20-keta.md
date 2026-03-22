---
id: w20-keta
status: open
deps: []
links: []
created: 2026-03-21T16:55:05Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# Bug: sprint-next-batch.sh overlap detector treats AC Verify commands as file impacts

## Description
sprint-next-batch.sh file overlap detection parses acceptance criteria Verify commands (e.g. bash tests/run-all.sh) as files that will be modified by the task. Since nearly all tasks include tests/run-all.sh as a universal verification command, the overlap detector flags every task as conflicting with every other task, limiting batch size to 1.

## Reproduction
Run sprint-next-batch.sh w21-54wx --limit=5 — observe BATCH_SIZE: 1 with all other tasks SKIPPED_OVERLAP due to tests/run-all.sh.

## Expected
Only consider files in the File Impact section, not AC Verify commands.

## Actual
Every ready task overlaps via shared test runner commands, producing batch size 1.

## Impact
Reduces sprint throughput from 5 tasks/batch to 1 task/batch.

