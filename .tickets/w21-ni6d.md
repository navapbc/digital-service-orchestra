---
id: w21-ni6d
status: open
deps: []
links: []
created: 2026-03-20T00:10:13Z
type: task
priority: 2
assignee: Joe Oakhart
---
# test-jq-to-parse-json-field.sh uses real REPO_ROOT for cascade STATE_DIR — same isolation anti-pattern as dso-b934


## Notes

**2026-03-20T00:10:18Z**

Same anti-pattern as dso-b934. tests/hooks/test-jq-to-parse-json-field.sh at line 81 computes TEST_STATE_DIR=/tmp/claude-cascade-${STATE_DIR_HASH} from the real REPO_ROOT. This can collide with other tests running in parallel. Fix: use a unique mktemp -d fake git repo per test run.
