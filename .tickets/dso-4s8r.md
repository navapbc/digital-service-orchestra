---
id: dso-4s8r
status: open
deps: []
links: []
created: 2026-03-17T18:34:14Z
type: epic
priority: 4
assignee: Joe Oakhart
jira_key: DIG-28
---
# Cleanup tests

Our tests have accumulated over time. Many tests check for the absence of behavior we have removed from the application. We should eliminate tests that do not meaningfully check for regression or validate desired behavior.


## Notes

<!-- note-id: mnvr62is -->
<!-- timestamp: 2026-03-18T20:49:36Z -->
<!-- origin: agent -->
<!-- sync: synced -->

Review existing tests for exemption criteria: audit the test suite and remove or rewrite tests that fail the behavioral-content criteria: (1) no conditional logic in the code under test — test is pure wiring/assignment/initialization; (2) change-detector tests — assertion mirrors implementation, breaks on any refactoring regardless of correctness; (3) infrastructure-boundary-only code — belongs at integration level not unit level. See dso-ffzi for the escape hatch criteria definition.
