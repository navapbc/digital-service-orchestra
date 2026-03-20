---
id: dso-1kul
status: closed
deps: []
links: []
created: 2026-03-20T15:56:10Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bugk
---
# Update skill files: replace workflow-config.conf with dso-config.conf

Replace all references to 'workflow-config.conf' in skill and command documentation files.

Files to update:
- plugins/dso/skills/project-setup/SKILL.md (16 occurrences — highest count)
- plugins/dso/skills/sprint/SKILL.md (1 occurrence)
- plugins/dso/skills/retro/docs/reviewers/test-quality.md (1 occurrence)

Replacement rules:
- 'workflow-config.conf' → 'dso-config.conf' for bare filename references
- Path contexts: '.claude/dso-config.conf' for full-path references
- In project-setup/SKILL.md: update all JIRA configuration wizard steps, monitoring key instructions, deprecated key migration steps to use new filename

Key areas in project-setup/SKILL.md to update:
- Line ~74: 'Read docs/CONFIGURATION-REFERENCE.md for workflow-config.conf keys'
- Line ~182: 'jira.project key value... Record this for workflow-config.conf'
- Line ~197-202: deprecated key migration wizard referencing old filename
- Lines ~266-267: monitoring.tool_errors key write instructions
- Lines ~388, 457, and remaining occurrences

TDD Requirement: N/A — Unit test exemption applies (all 3 criteria met):
1. No conditional logic — pure text replacement in documentation/skill files
2. Any test would be a change-detector test
3. Infrastructure-boundary-only — skill/documentation files, no business logic

## Acceptance Criteria

- [ ] Zero occurrences of 'workflow-config.conf' in skill files
  Verify: test $(grep -r 'workflow-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/skills/ 2>/dev/null | wc -l) -eq 0
- [ ] project-setup/SKILL.md retains coherent wizard instructions with updated filename
  Verify: grep -c 'dso-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md | awk '{exit ($1 < 10)}'


## Notes

**2026-03-20T16:01:30Z**

CHECKPOINT 1/6: Task context loaded ✓ — 3 files to update: project-setup/SKILL.md (16 occurrences), sprint/SKILL.md (1), retro/docs/reviewers/test-quality.md (1)

**2026-03-20T16:01:56Z**

CHECKPOINT 2/6: Read all 3 files ✓ — project-setup/SKILL.md has 16 occurrences (lines 9, 74, 181, 182, 197, 202, 266, 267, 388, 457, 461, 463, 475, 606, 626, 666); sprint/SKILL.md has 1 (line 1330); test-quality.md has 1 (line 50)

**2026-03-20T16:03:48Z**

CHECKPOINT 3/6: All edits applied ✓ — project-setup/SKILL.md (16 replacements), sprint/SKILL.md (1), test-quality.md (1)

**2026-03-20T16:04:00Z**

CHECKPOINT 4/6: Verification passed ✓ — 0 remaining workflow-config.conf occurrences in plugins/dso/skills/; 16 dso-config.conf occurrences in project-setup/SKILL.md (acceptance criteria both met)

**2026-03-20T16:04:11Z**

CHECKPOINT 5/6: Self-check complete ✓ — grep of all plugins/dso/skills/ returns zero matches for workflow-config.conf. No additional files found with the anti-pattern in-scope.

**2026-03-20T16:04:16Z**

CHECKPOINT 6/6: Task complete ✓ — All 18 occurrences replaced across 3 files. Both acceptance criteria verified green. No discovered work items.
