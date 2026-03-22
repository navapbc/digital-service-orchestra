---
id: dso-4u0s
status: in_progress
deps: [dso-fj1t]
links: []
created: 2026-03-22T03:27:34Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-d3gr
---
# As a developer, epic closure is blocked until all RED markers are removed from .test-index

## Description

**What**: Add a check that prevents closing an epic when .test-index still contains [RED] markers for stories in that epic. This ensures all RED tests have been implemented and pass before work is considered done.
**Why**: RED markers are transient — they should not persist beyond the epic that created them. Enforcing removal at closure ensures no gaps in test coverage survive the sprint.
**Scope**:
- IN: Epic closure validation that scans .test-index for RED markers, clear error message listing which entries still have markers
- OUT: Automatic marker removal (agents must explicitly remove markers after implementation)

## Done Definitions

- When this story is complete, attempting to close an epic that has .test-index entries with RED markers produces a clear error listing the stale markers
  ← Satisfies: "Epic closure is blocked until all RED markers are removed from .test-index"
- When this story is complete, closing an epic with no RED markers in .test-index succeeds normally
  ← Satisfies: backward compatibility
- When this story is complete, unit tests are written and passing for all new or modified logic

## Considerations

- [Reliability] The check must scan all .test-index entries, not just entries associated with the epic's stories — RED markers from this epic could reference any source file

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py
- [ ] `tk close` blocks when .test-index has RED markers
  Verify: grep -q "red_marker\|RED.*marker\|test-index.*marker" plugins/dso/scripts/tk
- [ ] `tk close` succeeds when .test-index has no RED markers (backward compat)
  Verify: grep -q "cmd_close" plugins/dso/scripts/tk
- [ ] Unit tests exist for RED marker closure check
  Verify: grep -c "red_marker\|epic.*close.*red\|test_.*red.*marker.*close\|test_.*close.*red" tests/scripts/test-tk-*.sh 2>/dev/null || grep -c "red_marker\|epic.*close.*red" tests/hooks/test-*.sh 2>/dev/null


## Notes

**2026-03-22T05:28:50Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T05:29:42Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T05:30:28Z**

CHECKPOINT 3/6: Tests written ✓ (5 pass, 2 fail - RED phase confirmed)

**2026-03-22T05:31:20Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T05:36:34Z**

CHECKPOINT 5/6: Validation passed ✓ (7/7 new tests pass, all existing tk tests pass)

**2026-03-22T05:36:42Z**

CHECKPOINT 6/6: Done ✓
