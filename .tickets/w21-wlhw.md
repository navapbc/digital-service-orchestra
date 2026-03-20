---
id: w21-wlhw
status: open
deps: []
links: []
created: 2026-03-20T00:10:05Z
type: task
priority: 2
assignee: Joe Oakhart
---
# test-pre-edit-write-dispatcher.sh uses real REPO_ROOT for cascade STATE_DIR — same isolation anti-pattern as dso-b934


## Notes

**2026-03-20T00:10:09Z**

Same anti-pattern as dso-b934 (test-cascade-breaker.sh). tests/hooks/test-pre-edit-write-dispatcher.sh computes _CASCADE_STATE_DIR from the real REPO_ROOT hash. During parallel suite runs, this can collide with the real cascade counter or other tests. Fix: use a unique mktemp -d fake git repo, run hook from within it, and resolve path via git rev-parse to handle macOS symlinks (/private/var/... vs /var/...). See dso-b934 for the reference fix pattern.
