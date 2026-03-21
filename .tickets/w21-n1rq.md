---
id: w21-n1rq
status: closed
deps: []
links: []
created: 2026-03-21T01:41:21Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-p7aa
---
# As a DSO practitioner, partial test results emit an unmissable structured continuation prompt

## Description

**What**: Update test-batched.sh and validate.sh to emit the Structured Action-Required Block when tests are incomplete, replacing the subtle NEXT: line with an unambiguous ACTION REQUIRED / RUN / DO NOT PROCEED format
**Why**: Prevents Pattern A — agents treating partial batched output as failure instead of continuing
**Scope**:
- IN: test-batched.sh output modification, validate.sh exit-2 output modification, validate.sh NEXT: detection pattern update (grep for new format), COMMIT-WORKFLOW.md NEXT: reference updates
- OUT: PreToolUse hook (sibling story); CLAUDE.md and SUB-AGENT-BOUNDARIES.md changes (sibling story)

## Done Definitions

- When this story is complete, test-batched.sh emits the Structured Action-Required Block to stdout when exiting with incomplete tests (state file with >=1 completed batch, final summary not yet printed)
  ← Satisfies: "test-batched.sh itself emits the Structured Action-Required Block when exiting with incomplete tests"
- When this story is complete, validate.sh emits the Structured Action-Required Block to stdout when exiting with code 2 (tests pending)
  ← Satisfies: "validate.sh itself emits the block when exiting with code 2"
- When this story is complete, validate.sh correctly detects incomplete test-batched.sh output using the new Structured Action-Required Block format (updating the internal grep pattern that previously matched NEXT:)
  ← Satisfies: "validate.sh itself emits the block when exiting with code 2" (prerequisite — validate.sh must detect partial runs to emit the block)
- When this story is complete, COMMIT-WORKFLOW.md references to NEXT: are updated to reflect the new Structured Action-Required Block format
  ← Satisfies: "test-batched.sh itself emits the Structured Action-Required Block" (downstream doc consistency)
- Unit tests written and passing for all new or modified logic

## ACCEPTANCE CRITERIA

- [ ] test-batched.sh emits the Structured Action-Required Block (ACTION REQUIRED / RUN / DO NOT PROCEED) to stdout when exiting with incomplete tests
  Verify: grep -q "ACTION REQUIRED" <(REPO_ROOT=$(git rev-parse --show-toplevel) && echo "exit" | timeout 5 bash "$REPO_ROOT/plugins/dso/scripts/test-batched.sh" --timeout=1 "sleep 10" 2>&1 || true)
- [ ] validate.sh emits the Structured Action-Required Block to stdout when exiting with code 2 (tests pending)
  Verify: grep -q "ACTION REQUIRED" <(REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/plugins/dso/scripts/validate.sh" --ci 2>&1 || true)
- [ ] validate.sh detects incomplete test-batched.sh output using new format (updated grep pattern from NEXT: to ACTION REQUIRED)
  Verify: grep -q "ACTION REQUIRED\|action.required" $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate.sh
- [ ] COMMIT-WORKFLOW.md references to NEXT: are updated to reflect Structured Action-Required Block format
  Verify: ! grep -q "^NEXT:" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md || grep -q "ACTION REQUIRED" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md
- [ ] Unit tests written and passing for all new or modified output logic
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5

## Considerations

- [Reliability] Existing consumers of test-batched.sh/validate.sh output may parse NEXT: lines — new format must not break existing integrations (validate.sh is the primary programmatic consumer via grep -q "^NEXT:")


## Notes

**2026-03-21T02:09:15Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T02:11:38Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T02:13:07Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T02:20:01Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T02:22:39Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T02:34:47Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/scripts/test-batched.sh, plugins/dso/scripts/validate.sh, plugins/dso/docs/workflows/COMMIT-WORKFLOW.md, runners. Tests: 56 pass.
