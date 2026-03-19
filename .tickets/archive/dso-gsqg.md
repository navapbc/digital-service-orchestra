---
id: dso-gsqg
status: closed
deps: []
links: []
created: 2026-03-18T21:11:38Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-ffzi
---
# RED: Write failing tests for ACCEPTANCE-CRITERIA-LIBRARY.md new categories

Create tests/skills/test_implementation_plan_ac_library.py with xfail tests asserting: (a) 'Category: RED Test Task' present in plugins/dso/docs/ACCEPTANCE-CRITERIA-LIBRARY.md — fails because not yet added; (b) 'Category: Test-Exempt Task' present — fails; (c) justification criterion text present within the test-exempt category — fails. All @pytest.mark.xfail(strict=True). Suite stays green (all XFAIL).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] tests/skills/test_implementation_plan_ac_library.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_ac_library.py
- [ ] File contains >=3 @pytest.mark.xfail-marked tests
  Verify: grep -c '@pytest.mark.xfail' $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_ac_library.py | awk '{exit ($1 < 3)}'
- [ ] Running tests shows XFAIL results
  Verify: python -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_implementation_plan_ac_library.py -v 2>&1 | grep -q 'XFAIL'


## Notes

<!-- note-id: i6x9svnl -->
<!-- timestamp: 2026-03-18T21:54:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test_implementation_plan_ac_library.py. Tests: 3 xfail (RED phase complete). All AC verify commands pass.

<!-- note-id: 4jm4q32f -->
<!-- timestamp: 2026-03-18T21:54:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: tests/skills/test_implementation_plan_ac_library.py — 3 xfail RED tests created
