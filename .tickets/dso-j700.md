---
id: dso-j700
status: closed
deps: [dso-4f1i]
links: []
created: 2026-03-18T21:11:32Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-ffzi
---
# GREEN: Add red_test_dependency and exemption_justification dimensions to tdd.md; update review-criteria.md schema hash

Edit plugins/dso/skills/implementation-plan/docs/reviewers/plan/tdd.md: add two new dimensions — 'red_test_dependency' (checks each behavioral-content task has a preceding RED test task as a declared dependency) and 'exemption_justification' (checks each test-exempt task cites a valid criterion from the three unit exemption criteria or two integration exemption criteria). Update the dimensions JSON block to include these two fields. Include scoring guidance for each: what a 4 or 5 looks like vs below 4. Regenerate caller schema hash in plugins/dso/skills/implementation-plan/docs/review-criteria.md. Then: remove @pytest.mark.xfail from test_implementation_plan_tdd_reviewer.py AND rewrite each test body as a positive assertion with explicit failure message.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] All tests in test_implementation_plan_tdd_reviewer.py PASS with no @pytest.mark.xfail decorators
  Verify: python -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_tdd_reviewer.py -v 2>&1 | grep -q "passed" && ! grep -q "@pytest.mark.xfail" $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_tdd_reviewer.py
- [ ] tdd.md contains 'red_test_dependency' dimension
  Verify: grep -q "red_test_dependency" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/docs/reviewers/plan/tdd.md
- [ ] tdd.md contains 'exemption_justification' dimension
  Verify: grep -q "exemption_justification" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/docs/reviewers/plan/tdd.md
- [ ] review-criteria.md contains a valid schema hash (positive assertion)
  Verify: grep -qE "Caller schema hash.*[a-f0-9]{8}" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/docs/review-criteria.md
- [ ] review-criteria.md does NOT contain old hash ae8bfc7bd9a0d7e3
  Verify: ! grep -q "ae8bfc7bd9a0d7e3" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/docs/review-criteria.md
- [ ] tdd.md is referenced in SKILL.md Step 4 reviewer list
  Verify: grep -q "reviewers/plan/tdd.md" $(git rev-parse --show-toplevel)/plugins/dso/skills/implementation-plan/SKILL.md


## Notes

<!-- note-id: xjp23r4t -->
<!-- timestamp: 2026-03-18T22:01:25Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: TDD reviewer tdd.md updated with red_test_dependency and exemption_justification dimensions; all 4 tests pass GREEN
