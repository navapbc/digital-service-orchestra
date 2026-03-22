---
id: w21-v0ad
status: open
deps: []
links: []
created: 2026-03-22T22:10:16Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# sprint-next-batch.sh overlap detector flags AC verify commands as file conflicts, causing false-positive batch splits


## Notes

**2026-03-22T22:10:26Z**

## Observed Behavior
sprint-next-batch.sh's conflict matrix flagged dso-2bmc and dso-5rya as overlapping on `bash tests/run-all.sh` and `tests/run-all.sh`. These references come from the ACCEPTANCE CRITERIA `Verify:` commands, not from the tasks' actual file modifications (dso-2bmc modifies debug-everything/SKILL.md, dso-5rya modifies sprint/SKILL.md — completely disjoint).

## Impact
A 2-task epic that should have completed in 1 batch required 2 sequential batches, roughly doubling wall-clock time.

## Expected Behavior
The overlap detector should distinguish between files a task will *modify* (from the File Impact section) and files referenced in AC verify commands. Only actual modification targets should trigger conflict detection.

## Reproduction
Run `sprint-next-batch.sh dso-s12s --limit=5` on an epic with two tasks whose AC both reference `bash tests/run-all.sh` but modify different files.
