---
id: dso-kiue
status: closed
deps: []
links: []
created: 2026-03-20T15:55:56Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bugk
---
# Rename workflow-config.example.conf to dso-config.example.conf and update its content

Rename the example config file from plugins/dso/docs/workflow-config.example.conf to plugins/dso/docs/dso-config.example.conf and update its internal content to reference the new filename and path.

Steps:
1. Read the current content of plugins/dso/docs/workflow-config.example.conf
2. Update the comment header to reference 'dso-config.conf' instead of 'workflow-config.conf'
3. Write the updated content to plugins/dso/docs/dso-config.example.conf (new file)
4. Remove (or overwrite-empty) the old plugins/dso/docs/workflow-config.example.conf
   - Use git mv or delete + create if git mv is unavailable in this context
5. Update any docs that reference the example file by its old name (grep for 'workflow-config.example.conf' across plugins/ and CLAUDE.md)

File: plugins/dso/docs/workflow-config.example.conf → plugins/dso/docs/dso-config.example.conf

Also update CLAUDE.md reference if 'workflow-config.example.conf' appears in it.
Also update plugins/dso/docs/INSTALL.md and other docs that may reference the example filename.

TDD Requirement: N/A — Unit test exemption applies (all 3 criteria met):
1. No conditional logic — file rename and content update
2. Any test would be a change-detector test
3. Infrastructure-boundary-only — example config file, no business logic

## Acceptance Criteria

- [ ] plugins/dso/docs/dso-config.example.conf exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/dso-config.example.conf
- [ ] plugins/dso/docs/workflow-config.example.conf no longer exists
  Verify: test ! -f $(git rev-parse --show-toplevel)/plugins/dso/docs/workflow-config.example.conf
- [ ] dso-config.example.conf content header references 'dso-config.conf' not 'workflow-config.conf'
  Verify: grep -v 'workflow-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/docs/dso-config.example.conf | head -3
- [ ] No references to 'workflow-config.example.conf' remain in any in-scope file
  Verify: test $(grep -r 'workflow-config.example.conf' $(git rev-parse --show-toplevel)/plugins/ $(git rev-parse --show-toplevel)/CLAUDE.md 2>/dev/null | wc -l) -eq 0


## Notes

**2026-03-20T16:01:51Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T16:02:03Z**

CHECKPOINT 2/6: File read, references found in MIGRATION-TO-PLUGIN.md, decisions/adr-config-system.md, and CONFIG-RESOLUTION.md ✓

**2026-03-20T16:02:28Z**

CHECKPOINT 3/6: File renamed via git mv; header updated to reference dso-config.conf ✓

**2026-03-20T16:03:01Z**

CHECKPOINT 4/6: Updated references in MIGRATION-TO-PLUGIN.md, decisions/adr-config-system.md, and CONFIG-RESOLUTION.md ✓

**2026-03-20T16:03:11Z**

CHECKPOINT 5/6: All 4 acceptance criteria verified — PASS ✓

**2026-03-20T16:04:00Z**

CHECKPOINT 6/6: All references updated including test scripts (test-docs-config-refs.sh, test-read-config.sh). Zero remaining references outside .tickets/. git mv confirmed. All 4 ACs pass. ✓
