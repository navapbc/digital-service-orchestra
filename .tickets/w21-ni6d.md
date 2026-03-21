---
id: w21-ni6d
status: closed
deps: []
links: []
created: 2026-03-20T00:10:13Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-9xnr
---
# test-jq-to-parse-json-field.sh uses real REPO_ROOT for cascade STATE_DIR — same isolation anti-pattern as dso-b934


## Notes

**2026-03-20T00:10:18Z**

Same anti-pattern as dso-b934. tests/hooks/test-jq-to-parse-json-field.sh at line 81 computes TEST_STATE_DIR=/tmp/claude-cascade-${STATE_DIR_HASH} from the real REPO_ROOT. This can collide with other tests running in parallel. Fix: use a unique mktemp -d fake git repo per test run.

<!-- note-id: 03kpk2vj -->
<!-- timestamp: 2026-03-21T00:17:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: tests/hooks/test-jq-to-parse-json-field.sh now uses FAKE_ROOT with a minimal git repo for STATE_DIR isolation, preventing interference with real cascade state
