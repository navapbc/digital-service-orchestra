---
id: w21-1bvu
status: in_progress
deps: [w21-cw8j, w21-kezk]
links: []
created: 2026-03-21T21:05:11Z
type: story
priority: 3
assignee: Joe Oakhart
parent: dso-2j6u
---
# As a developer, I can confirm all 5 callers produce schema-valid output from dedicated agents

## Description

**What**: Invoke each of the 5 callers (sprint epic evaluator, sprint story evaluator, brainstorm, fix-bug, resolve-conflicts) with realistic inputs and verify schema-valid JSON output on first attempt.
**Why**: Epic success criterion SC4 requires all 5 callers to produce schema-valid output. This story provides the validation signal that the extraction is complete and correct.
**Scope**:
- IN: Invoke each caller with a realistic ticket (not stubs). Record pass/fail per caller. Record results in epic notes.
- OUT: Automated regression test suite. Long-term monitoring.

## Done Definitions

- When this story is complete, each of the 5 callers has been invoked with realistic input and produced schema-valid JSON output on first attempt, with results recorded in epic notes
  ← Satisfies: "invoke each of the 4 complexity evaluator callers and the conflict analyzer caller at least once using realistic inputs"
- When this story is complete, the epic notes contain a pass/fail record for each caller with the input ticket ID and output JSON validation result
  ← Satisfies: "Record whether the agent response is valid JSON matching the schema"

## Considerations

- [Testing] Use existing open tickets as realistic inputs — do not create synthetic test tickets
- [Testing] Schema validation must check all required fields per the output schemas defined in each agent definition

## ACCEPTANCE CRITERIA

- [ ] Validation test script exists that invokes all 5 callers
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_agent_dispatch_validation.py || test -f $(git rev-parse --show-toplevel)/tests/skills/test_agent_dispatch_validation.sh
- [ ] Epic notes contain pass/fail results for each caller
  Verify: tk show dso-2j6u 2>&1 | grep -q "VALIDATION_RESULTS"


## Notes

**2026-03-21T22:50:34Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T22:51:28Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T22:52:32Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T22:53:30Z**

CHECKPOINT 4/6: Tests passed ✓ — 25/25 tests pass

**2026-03-21T22:53:43Z**

CHECKPOINT 6/6: Done ✓
