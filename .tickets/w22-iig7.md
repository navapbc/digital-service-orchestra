---
id: w22-iig7
status: closed
deps: []
links: []
created: 2026-03-20T15:34:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-xzrw
---
# RED: Write structural validation test for epic-level calibration of agent-clarity.md

## Description

Create `tests/reviewers/test-agent-clarity-epic-calibration.sh` — a bash test script that validates agent-clarity.md contains epic-level calibration markers. The test uses named assertion functions for each structural check.

### Named assertion functions to implement:

1. `test_dimensions_reference_planners` — verify dimension definitions reference planners/story decomposition, not "developer agent...would build the right thing"
2. `test_anti_pattern_instruction_present` — verify the Instructions section contains guidance prohibiting penalization of missing file paths, shell commands, and implementation details (SC3)
3. `test_ambiguity_penalization_present` — verify the reviewer is instructed to penalize genuinely ambiguous specs: vague outcomes, undefined jargon, missing edge case coverage (SC4)
4. `test_copies_identical` — verify brainstorm and roadmap copies of agent-clarity.md are byte-identical
5. `test_scoring_scale_preserved` — verify the scoring scale table and JSON output format are preserved

### Files to create:
- `tests/reviewers/test-agent-clarity-epic-calibration.sh`

### TDD Requirement:
Run against original agent-clarity.md files → test FAILS (RED) because current dimensions reference "developer agent" and lack anti-pattern instruction.

### Escalation Policy
**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

## ACCEPTANCE CRITERIA

- [ ] Test file exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/reviewers/test-agent-clarity-epic-calibration.sh
- [ ] Test is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/reviewers/test-agent-clarity-epic-calibration.sh
- [ ] Test defines 5 named assertion functions
  Verify: grep -c '^test_\|^function test_' $(git rev-parse --show-toplevel)/tests/reviewers/test-agent-clarity-epic-calibration.sh | awk '{exit ($1 < 5)}'
- [ ] Running test against original files returns non-zero (RED)
  Verify: ! bash $(git rev-parse --show-toplevel)/tests/reviewers/test-agent-clarity-epic-calibration.sh

## Notes

**2026-03-21T03:46:18Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T03:46:22Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T03:47:02Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T03:47:05Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T03:47:14Z**

CHECKPOINT 5/6: Validation passed ✓ — tests return non-zero (RED state confirmed)

**2026-03-21T03:47:25Z**

CHECKPOINT 6/6: Done ✓ — All 4 AC verified: file exists, executable, 10 functions (>=5), returns exit 1 (RED)
