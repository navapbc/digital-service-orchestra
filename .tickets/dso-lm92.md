---
id: dso-lm92
status: open
deps: []
links: []
created: 2026-03-20T23:52:42Z
type: bug
priority: 3
assignee: Joe Oakhart
---
# record-review.sh CHANGED_FILES overlap check includes untracked files that may not be reviewed

record-review.sh line 269 uses git ls-files --others in the CHANGED_FILES overlap check. This is a different code path from the hash (which now correctly excludes untracked files via compute-diff-hash.sh). The overlap check may accept untracked temp files as 'changed files' for review validation, which could falsely satisfy the overlap requirement. Investigate whether the overlap check should also exclude untracked files or limit to staged/tracked files only. Related to dso-fqxu/dso-g8cz fix.

