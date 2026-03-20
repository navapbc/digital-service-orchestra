---
id: w22-iig7
status: open
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
