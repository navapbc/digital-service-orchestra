---
id: dso-31yq
status: in_progress
deps: []
links: []
created: 2026-03-19T23:51:40Z
type: bug
priority: 1
assignee: Joe Oakhart
parent: dso-d72c
---
# Fix: hook_track_tool_errors test fails — missing monitoring.tool_errors config in test env


## Notes

<!-- note-id: 4boljk7c -->
<!-- timestamp: 2026-03-19T23:51:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Cluster 1: session-misc hook_track_tool_errors early-return due to missing config.

Root cause: hook_track_tool_errors() in plugins/dso/hooks/lib/session-misc-functions.sh:649 reads 'monitoring.tool_errors' from config via read-config.sh. When not set to 'true', it returns 0 early, never creating the counter file.

Failing test:
- test-session-misc-no-jq.sh: test_track_tool_errors: counter file created (expected 1, got 0)

The test does not set this config key in the test environment, so the function exits early without creating the expected counter file. Fix: either set monitoring.tool_errors=true in test fixtures, or add a bypass/mock mechanism in the test that stubs out read-config.sh.

SAFEGUARDED: fix requires editing protected file(s): plugins/dso/hooks/lib/session-misc-functions.sh

<!-- note-id: in0eaqa9 -->
<!-- timestamp: 2026-03-20T00:05:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

SAFEGUARD APPROVED: user approved editing plugins/dso/hooks/lib/session-misc-functions.sh. Proposed fix: Add DSO_MONITORING_TOOL_ERRORS env var override before read-config.sh call

**2026-03-20T00:19:17Z**

Fixed: Added DSO_MONITORING_TOOL_ERRORS env var override to hook_track_tool_errors() in plugins/dso/hooks/lib/session-misc-functions.sh (line 649). Updated tests/hooks/test-session-misc-no-jq.sh to set DSO_MONITORING_TOOL_ERRORS=true in both test_track_tool_errors and test_track_tool_errors_skips_interrupts test cases. Committed at 25dcadb. Tests: PASSED 20 FAILED 0.
