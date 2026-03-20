---
id: dso-wmjr
status: open
deps: []
links: []
created: 2026-03-20T15:56:20Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bugk
---
# Update CLAUDE.md: replace workflow-config.conf with dso-config.conf

Replace all references to 'workflow-config.conf' in CLAUDE.md with the new canonical path '.claude/dso-config.conf'.

File to update: CLAUDE.md (2 occurrences)

Current occurrences (from grep):
- Line 61: mentions 'workflow-config.conf' in the Architecture section describing config key behavior
- Line 75: mentions 'workflow-config.conf' in the Critical Rules section

Replacement rules:
- 'workflow-config.conf' → 'dso-config.conf' (bare filename in prose)
- If referenced with path context → '.claude/dso-config.conf'

TDD Requirement: N/A — Unit test exemption applies (all 3 criteria met):
1. No conditional logic — pure text replacement in agent instructions file
2. Any test would be a change-detector test
3. Infrastructure-boundary-only — project instructions file, no business logic

## Acceptance Criteria

- [ ] Zero occurrences of 'workflow-config.conf' in CLAUDE.md
  Verify: test $(grep -c 'workflow-config.conf' $(git rev-parse --show-toplevel)/CLAUDE.md 2>/dev/null) -eq 0
- [ ] Updated references use 'dso-config.conf' or '.claude/dso-config.conf'
  Verify: grep 'dso-config.conf' $(git rev-parse --show-toplevel)/CLAUDE.md | wc -l | awk '{exit ($1 < 1)}'

