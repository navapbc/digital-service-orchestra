---
id: w21-cphn
status: open
deps: [w21-l7zk, w21-8vlg]
links: []
created: 2026-03-20T19:10:30Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-uqfn
---
# IMPL: Add test-gate write protection to review-gate-bypass-sentinel.sh

Extend plugins/dso/hooks/lib/review-gate-bypass-sentinel.sh to block direct writes to test-gate-status and related test-status files.

This is Layer 2 bypass prevention for the test gate — the same pattern as the review gate's write protection (Pattern f: Write to .git/hooks/).

Add a new detection block after the existing Pattern f, following the same structure:

Pattern g: Direct writes to test-gate-status or test-status directory
Block commands that attempt to write the test-gate-status file directly using echo/cat/tee/printf redirections or cp/mv targeting the artifacts directory test-gate-status path.

Detection criteria:
- Commands containing 'test-gate-status' with write operators (>, tee, cp, mv, echo/printf with redirect)
- Commands containing 'test-status/' with write operators targeting that directory

Pattern h: Direct deletion of test-gate-status
Block 'rm ... test-gate-status' commands (cannot delete to reset gate state).

Exemptions (do NOT block):
- read operations: cat test-gate-status, grep test-gate-status (no write operator)
- record-test-status.sh itself (the only authorized writer)
- test-batched.sh commands (exempt — they don't write to test-gate-status)
- WIP commits (already exempted at top of function)

Implementation constraints:
- Add patterns AFTER existing Pattern f block (line ~103 in current file)
- Follow the same comment format, return 2 pattern, and error message format
- Error message: 'BLOCKED [bypass-sentinel]: direct write to test-gate-status detected. Use record-test-status.sh to record test results.'
- Authorized writer exemption: if command contains 'record-test-status.sh', return 0 (allow)

## Acceptance Criteria

- [ ] review-gate-bypass-sentinel.sh blocks direct writes to test-gate-status
  Verify: RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo passed > /tmp/workflow-plugin-xxx/test-gate-status"}}' | bash $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/review-gate-bypass-sentinel.sh 2>&1 || true); echo "exit=$?"
- [ ] Test file test-review-gate-bypass-sentinel.sh passes (or coexistence test covers bypass)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-review-gate-bypass-sentinel.sh 2>&1 | tail -3
- [ ] record-test-status.sh is NOT blocked by the sentinel
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/review-gate-bypass-sentinel.sh '{"tool_name":"Bash","tool_input":{"command":"bash plugins/dso/hooks/record-test-status.sh"}}' < /dev/null; echo "exit=$?"
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

