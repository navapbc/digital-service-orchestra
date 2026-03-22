---
id: w22-tho5
status: in_progress
deps: [w22-ond9, w22-ybey]
links: []
created: 2026-03-21T16:59:29Z
type: story
priority: 3
assignee: Joe Oakhart
parent: w22-anm2
---
# Update project docs to reflect CI workflow generation

## Description

**What**: Update CLAUDE.md and relevant docs to document CI workflow generation, placement options, and integration with project-setup.
**Why**: Future agents need accurate awareness of the generation capability and user-facing prompts.
**Scope**:
- IN: CLAUDE.md architecture section, project-setup skill documentation updates
- OUT: New documentation files (update existing only)

## Done Definitions

- When this story is complete, CLAUDE.md references CI workflow generation from discovered suites and the placement prompt options
  ← Satisfies: "project documentation is accurate"

## ACCEPTANCE CRITERIA

- [ ] CLAUDE.md architecture section references ci-generator.sh and its role in project-setup
  Verify: grep -q "ci-generator" CLAUDE.md
- [ ] CLAUDE.md documents the placement prompt options (fast-gate, separate, skip)
  Verify: grep -q "ci_placement" CLAUDE.md
- [ ] CLAUDE.md documents the project-detect.sh --suites integration
  Verify: grep -q "project-detect.sh" CLAUDE.md
- [ ] No new documentation files created (updates to existing only)
- [ ] Changes pass ruff check and ruff format

## Notes

<!-- note-id: qm6hj912 -->
<!-- timestamp: 2026-03-22T18:46:53Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: i0ie2pvi -->
<!-- timestamp: 2026-03-22T18:47:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 1dmek2cs -->
<!-- timestamp: 2026-03-22T18:47:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓

<!-- note-id: 9y923vso -->
<!-- timestamp: 2026-03-22T18:47:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: xvzk7wca -->
<!-- timestamp: 2026-03-22T18:47:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: g77w5303 -->
<!-- timestamp: 2026-03-22T18:47:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
