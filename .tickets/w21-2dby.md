---
id: w21-2dby
status: open
deps: []
links: []
created: 2026-03-21T03:45:38Z
type: bug
priority: 1
assignee: Joe Oakhart
parent: w22-ns6l
---
# Bug: test suite exceeds Claude Code tool timeout (~73s) despite test-batched.sh guidance in CLAUDE.md


## Notes

**2026-03-21T03:45:47Z**

Full test suite (bash tests/run-all.sh) and validate.sh --ci consistently exceed the ~73s Claude Code tool timeout ceiling, producing exit 144. CLAUDE.md rule 12 prescribes test-batched.sh for commands >60s, but agents still invoke bare test/validate commands during commit workflows. Recent fix added agent guidance but agents continue to hit timeouts during end-session commit workflow Step 1. Root cause: COMMIT-WORKFLOW.md Step 1 references 'make test-unit-only' and the config-resolved TEST_CMD without prescribing test-batched.sh wrapping.
