---
id: w21-jndb
status: closed
deps: []
links: []
created: 2026-03-19T01:53:22Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-t1xp
---
# Document monitoring.tool_errors in INSTALL.md and CONFIGURATION-REFERENCE.md

Update two documentation files to document the new monitoring.tool_errors config flag.

1. plugins/dso/docs/INSTALL.md: Add row to Key Configuration Summary table:
   | monitoring.tool_errors | false (absent) | Set to true to enable tool error tracking and auto-ticket creation |

2. plugins/dso/docs/CONFIGURATION-REFERENCE.md: Add entry under # Monitoring section documenting:
   - Default: absent (disabled)
   - Valid values: true (enabled) or absent/any non-true value (disabled)
   - Behavior when true: hook_track_tool_errors() tracks errors to ~/.claude/tool-error-counter.json and sweep_tool_errors() creates tickets at threshold
   - Behavior when absent/false: both functions return 0 immediately with no side effects

TDD EXEMPTION: Criterion 3 (Markdown documentation — static text assets where no executable assertion is possible).

## Acceptance Criteria

- [ ] monitoring.tool_errors appears in INSTALL.md
  Verify: grep -q 'monitoring.tool_errors' plugins/dso/docs/INSTALL.md
- [ ] monitoring.tool_errors appears in CONFIGURATION-REFERENCE.md
  Verify: grep -q 'monitoring.tool_errors' plugins/dso/docs/CONFIGURATION-REFERENCE.md
- [ ] INSTALL.md row contains both flag name and its default on the same line
  Verify: grep -iE 'monitoring\.tool_errors.*(absent|false)|(absent|false).*monitoring\.tool_errors' plugins/dso/docs/INSTALL.md


## Notes

<!-- note-id: 1vdaxlwv -->
<!-- timestamp: 2026-03-19T02:23:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Files: Modified/created test files and docs. Tests: RED state confirmed.

<!-- note-id: kztwzlan -->
<!-- timestamp: 2026-03-19T02:45:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: added monitoring.tool_errors to INSTALL.md and CONFIGURATION-REFERENCE.md
