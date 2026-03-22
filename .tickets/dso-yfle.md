---
id: dso-yfle
status: open
deps: []
links: []
created: 2026-03-22T21:51:48Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# debug-everything orchestrator fixes bugs directly instead of delegating to /dso:fix-bug

Per Phase 5 spec, debug-everything should delegate all bug resolution to /dso:fix-bug rather than fixing bugs directly in the orchestrator. The orchestrator was observed fixing ci-generator and run-all.sh bugs directly without dispatching /dso:fix-bug sub-agents. This bypasses fix-bug's TDD enforcement, complexity evaluation, and checkpoint protocol.

