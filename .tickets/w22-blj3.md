---
id: w22-blj3
status: open
deps: []
links: []
created: 2026-03-22T16:09:15Z
type: bug
priority: 3
assignee: Joe Oakhart
---
# Bug: merge-to-main.sh PRE_MERGE_SHA unbound variable in ci_trigger phase

During merge-to-main.sh --resume, line 1254 throws 'PRE_MERGE_SHA: unbound variable'. The ci_trigger phase references PRE_MERGE_SHA but it's not set when resuming from a later phase. The variable is likely set in an earlier phase (sync or merge) and not persisted to the state file.

