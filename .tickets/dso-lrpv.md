---
id: dso-lrpv
status: closed
deps: [dso-mso2]
links: []
created: 2026-03-21T05:02:18Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# Fix ticket-list.sh to inspect JSON status field, not just reducer exit code, for ghost/corrupt tickets

Gap analysis finding (implicit assumption gap): ticket-list.sh (dso-97wx) is specified to check reducer exit code to detect ghost tickets. However, after dso-mso2, the reducer's main() must exit non-zero for error-state dicts to maintain backward compatibility with ticket-show.sh (see dso-mso2 AC amendment). This means ticket-list.sh can rely on exit code OR JSON status field — but the description must be explicit about which signal is authoritative.

Resolution: Update the ticket-list.sh implementation spec in dso-97wx to document the exact algorithm:
1. Run python3 ticket-reducer.py <ticket_dir>
2. If exit 0: parse JSON, include the state dict in the output array (even if status='error' or 'fsck_needed' — the reducer exiting 0 with error-state JSON is valid for list purposes)
3. If exit non-zero: construct a fallback error-state dict manually: {'ticket_id': <id>, 'status': 'error', 'error': 'reducer_failed'} and include it

This ensures ticket-list.sh handles both code paths robustly and doesn't silently drop tickets.

Note: This task amends the acceptance criteria of dso-97wx (ticket-list.sh implementation) — the implementer must handle both exit-0-with-error-status and exit-nonzero outcomes from the reducer.

TDD: Update tests in test-ticket-list.sh (dso-woj0) to cover both the exit-0-error-status case and the exit-nonzero case.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] dso-97wx description updated with dual-signal algorithm documentation
  Verify: grep -q 'exit 0\|exit-0\|fallback error-state\|reducer_failed' $(git rev-parse --show-toplevel)/.tickets/dso-97wx.md


## Notes

**2026-03-21T05:36:30Z**

CHECKPOINT 6/6: Done ✓ — Amended dso-97wx and dso-woj0 with dual-signal algorithm spec.
