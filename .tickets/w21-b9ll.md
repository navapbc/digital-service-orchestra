---
id: w21-b9ll
status: closed
deps: []
links: []
created: 2026-03-20T00:41:03Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bzvu
---
# RED: Write failing tests for conditional prompt sections in project-setup SKILL.md

Write failing Python tests in tests/skills/test_project_setup_skill_conditional_prompts.py asserting that project-setup/SKILL.md Step 3 contains the conditional prompting sections for database keys, infrastructure keys, staging keys, and worktree.python_version auto-detection.

TDD REQUIREMENT (RED task): Tests must FAIL before implementation tasks run. Each assertion checks for text that does not yet exist in SKILL.md.

Test assertions to write:
1. test_skill_has_database_conditional_section: assert SKILL.md contains a conditional database keys prompting section (gated on DB detection output)
2. test_database_section_conditioned_on_db_detection: assert SKILL.md references detection output field (db_detected or docker_db_detected) as gating condition for database prompts
3. test_skill_has_infrastructure_conditional_section: assert SKILL.md contains conditional infrastructure key prompts section
4. test_skill_has_required_tools_guidance: assert SKILL.md Step 3 contains guidance text explaining required_tools controls CLI tool checks at session start and their absence produces warnings or errors
5. test_skill_has_port_inference_instructions: assert SKILL.md contains instructions for inferring port numbers from docker-compose/env including variable substitution default extraction (pattern: dollar-brace VAR:-default-brace)
6. test_skill_has_staging_conditional_section: assert SKILL.md contains conditional staging.url prompt gated on staging config detection
7. test_skill_has_python_version_autodetection: assert SKILL.md references auto-detecting Python version from pyproject.toml, .python-version, or python3 binary

File location: tests/skills/test_project_setup_skill_conditional_prompts.py
Pattern: Follow tests/skills/test_fix_bug_skill.py using pathlib.Path to load SKILL.md and assert string content requirements.

test-exempt: N/A — this IS the test task.

## Acceptance Criteria

- [ ] tests/skills/test_project_setup_skill_conditional_prompts.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_project_setup_skill_conditional_prompts.py
- [ ] Test file contains at least 7 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_project_setup_skill_conditional_prompts.py | awk '{exit ($1 < 7)}'
- [ ] All tests FAIL before implementation (RED state confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_project_setup_skill_conditional_prompts.py 2>&1; test $? -ne 0
- [ ] make lint passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint
- [ ] make format-check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make format-check
- [ ] NOTE (gap-analysis): Test field name assertions for detection output (e.g., db_detected, DETECT_APP_PORT) must be confirmed against the finalized dso-r2es output schema before implementation tasks start. Implementer must check project-detect.sh output schema doc and use actual field names.
  Verify: grep -q 'DETECT_\|_detected\|db_detected' $(git rev-parse --show-toplevel)/tests/skills/test_project_setup_skill_conditional_prompts.py


## Notes

**2026-03-20T01:19:03Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T01:21:26Z**

CHECKPOINT 2/6: Code patterns understood ✓ — using pathlib.Path pattern from test_fix_bug_skill.py; detect schema uses db_present field (from test-project-detect.sh); SKILL.md Step 3 is the target section; no conditional sections exist yet (RED)

**2026-03-20T01:23:11Z**

CHECKPOINT 3/6: Tests written ✓ — created tests/skills/test_project_setup_skill_conditional_prompts.py with 7 test functions covering: database conditional section, db_present gating condition, infrastructure section, required_tools guidance, port inference with variable substitution, staging conditional section, python version auto-detection

**2026-03-20T01:23:35Z**

CHECKPOINT 4/6: Implementation complete ✓ — all 7 tests FAIL as expected (RED state confirmed). Exit code 1. Each test fails with AssertionError showing the content is not yet in SKILL.md.

**2026-03-20T01:25:19Z**

CHECKPOINT 5/6: Validation passed ✓ — ruff format --check: 44 files already formatted; ruff check: All checks passed!

**2026-03-20T01:26:04Z**

CHECKPOINT 6/6: Done ✓ — AC results: AC1 PASS (file exists), AC2 PASS (7 test functions), AC3 PASS (all 7 tests FAIL as expected, pytest exit 1), AC4 PASS (make lint → ruff check: All checks passed!), AC5 PASS (format-check: 44 files already formatted), AC6-note PASS (db_present, db_detected, docker_db_detected references in test file). No discovered work.
