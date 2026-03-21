---
id: dso-hzwm
status: in_progress
deps: [dso-dipm]
links: []
created: 2026-03-21T16:10:20Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-goqp
---
# Implement hook_tickets_tracker_bash_guard in pre-bash-functions.sh (Bash commands)

Implement hook_tickets_tracker_bash_guard in plugins/dso/hooks/lib/pre-bash-functions.sh.

Behavior:
- Only fires on Bash tool calls
- Extracts command from tool_input
- Checks if command string contains .tickets-tracker/
- Allowlist: if command matches ticket CLI patterns (ticket *, tk *), return 0 (allow)
  Allowlist patterns: command contains 'ticket ' or command contains 'tk ' as first meaningful token
- If .tickets-tracker/ is referenced AND not allowlisted: return 2 (block)
- All other cases: return 0 (allow, fail-open)
- ERR trap: log to hook-error-log.jsonl and return 0 (consistent with other bash hooks)

Error message format:
  BLOCKED [tickets-tracker-guard]: Direct Bash modifications to .tickets-tracker/ are not allowed.
  Use ticket commands (ticket create, ticket sync, etc.) instead.
  Direct modifications bypass event sourcing invariants and may corrupt the event log.

Allowlist rationale: ticket CLI scripts (ticket, tk) manage .tickets-tracker/ as their authoritative
implementation — they are the sanctioned write path. All other commands are blocked.

Add function after hook_blocked_test_command in pre-bash-functions.sh.
Add function name to pre-bash-functions.sh header comment.

TDD: Task dso-dipm RED tests must pass GREEN after this task.


## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] hook_tickets_tracker_bash_guard function defined in pre-bash-functions.sh
  Verify: grep -q 'hook_tickets_tracker_bash_guard' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/pre-bash-functions.sh
- [ ] Bash command with .tickets-tracker/ reference returns exit 2 (blocked)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh
- [ ] ticket CLI command with .tickets-tracker/ context returns exit 0 (allowlisted)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh
- [ ] ruff check plugins/dso/scripts/*.py tests/**/*.py passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Empty Bash command (empty string) returns exit 0 (fail-open — no crash)
  Verify: echo '{"tool_name":"Bash","tool_input":{"command":""}}' | source $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/pre-bash-functions.sh 2>/dev/null; hook_tickets_tracker_bash_guard '{"tool_name":"Bash","tool_input":{"command":""}}'; test $? -eq 0

## Notes

**2026-03-21T18:51:20Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T18:52:00Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T18:52:25Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T18:52:28Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T18:52:36Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T18:52:46Z**

CHECKPOINT 6/6: Done ✓
