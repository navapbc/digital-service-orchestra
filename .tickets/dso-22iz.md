---
id: dso-22iz
status: closed
deps: [dso-za4o]
links: []
created: 2026-03-22T03:52:22Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Display BRIDGE_ALERT health warning in ticket-show.sh and ticket-list.sh output

Update ticket-show.sh and ticket-list.sh to surface BRIDGE_ALERT health warnings when unresolved alerts exist in the compiled state.

Files to edit:
- plugins/dso/scripts/ticket-show.sh
- plugins/dso/scripts/ticket-list.sh

Implementation for ticket-show.sh (default format):
- After outputting the main JSON, check if the compiled state contains non-empty bridge_alerts with any unresolved entry
- If so, print a warning to stderr: 'WARNING: ticket <id> has <N> unresolved bridge alert(s). Run: ticket bridge-status for details.'
- The JSON output itself already contains bridge_alerts array (from reducer), so agents see it without stderr

Implementation for ticket-list.sh (default format):
- After assembling the output JSON array, iterate tickets; for each with non-empty unresolved bridge_alerts, print to stderr:
  'WARNING: <N> ticket(s) have unresolved bridge alerts. Run: ticket bridge-status for details.'
- One aggregate warning per list invocation (not per-ticket)

LLM format: bridge_alerts array is already included in JSON output from reducer; no additional display logic needed (field available for agents to read). LLM format must NOT print stderr warnings (it is consumed by agents programmatically).

Note: The warning is PASSIVE — it does not block or alter the main output path. ticket-show.sh and ticket-list.sh exit 0 even when alerts exist.

TDD Requirement: Task dso-7n6c (RED tests) and dso-za4o (reducer implementation) must complete first. After this task, test_ticket_show_outputs_health_warning_when_unresolved_alerts and test_ticket_list_includes_bridge_alerts_in_output must pass.

Run tests: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ticket-show.sh outputs health warning to stderr when unresolved BRIDGE_ALERTs exist
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py::test_ticket_show_outputs_health_warning_when_unresolved_alerts -v
- [ ] ticket-list.sh includes bridge_alerts in per-ticket JSON output
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py::test_ticket_list_includes_bridge_alerts_in_output -v
- [ ] ticket-show.sh exits 0 even when BRIDGE_ALERTs exist (passive, non-blocking)
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-show.sh <test-ticket-with-alert> && echo "exit 0 confirmed"
- [ ] LLM format does NOT emit stderr warnings (only human-readable default format does)
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/ticket-show.sh --format=llm <test-ticket> 2>/tmp/stderr-out && ! grep -q 'WARNING' /tmp/stderr-out


## Notes

**2026-03-22T04:23:31Z**

CHECKPOINT 6/6: Done ✓ — impl complete, tests GREEN. BLOCKED: test gate hits pre-existing RED tests from w21-54wx epic (ticket-reducer, ticket-graph, etc.)

**2026-03-22T05:05:08Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/scripts/ticket-show.sh, plugins/dso/scripts/ticket-list.sh. Tests: pass (5/5 bridge_alert_display). Commit blocked by compute-diff-hash.sh divergence between plugin cache and in-repo copies.
