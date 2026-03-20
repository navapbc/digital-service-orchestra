---
id: dso-uqm6
status: open
deps: []
links: []
created: 2026-03-20T15:55:41Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bugk
---
# Update plugins/dso/docs/ markdown files: replace workflow-config.conf with dso-config.conf

Replace all references to 'workflow-config.conf' with '.claude/dso-config.conf' (or 'dso-config.conf' in prose) in all markdown documentation files under plugins/dso/docs/.

Files to update (10 files, ~40 occurrences total):
- plugins/dso/docs/CONFIG-RESOLUTION.md
- plugins/dso/docs/CONFIGURATION-REFERENCE.md
- plugins/dso/docs/decisions/adr-config-system.md
- plugins/dso/docs/FLAT-CONFIG-MIGRATION.md
- plugins/dso/docs/INSTALL.md
- plugins/dso/docs/MIGRATION-TO-PLUGIN.md
- plugins/dso/docs/PRE-COMMIT-TIMEOUT-WRAPPER.md
- plugins/dso/docs/WORKTREE-GUIDE.md
- plugins/dso/docs/workflows/COMMIT-WORKFLOW.md
- plugins/dso/docs/workflows/REVIEW-WORKFLOW.md

Replacement rules:
- 'workflow-config.conf' (bare filename) → 'dso-config.conf'
- Prose references 'place at repo root / workflow-config.conf' → '.claude/dso-config.conf'
- Path examples 'path/to/workflow-config.conf' → '.claude/dso-config.conf'
- Also update any prose describing placing config at repo root (per story Considerations note)

TDD Requirement: N/A — Unit test exemption applies (all 3 criteria met):
1. No conditional logic — purely structural text replacement
2. Any test would be a change-detector test (only asserts text content, not behavior)
3. Infrastructure-boundary-only — documentation files with no business logic
Verification is via grep acceptance criterion.

## Acceptance Criteria

- [ ] Zero occurrences of 'workflow-config.conf' remain in target docs
  Verify: test $(grep -r 'workflow-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/docs/ 2>/dev/null | grep -v workflow-config.example.conf | wc -l) -eq 0
- [ ] Replacement text uses '.claude/dso-config.conf' or 'dso-config.conf' as appropriate for context
  Verify: grep -r 'dso-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/docs/ | wc -l | awk '{exit ($1 < 5)}'

