---
id: w21-mrqh
status: in_progress
deps: []
links: []
created: 2026-03-21T22:11:03Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-8cw2
---
# RED: Write failing tests for ACLI integration wrapper

## Description

Write failing tests in `tests/scripts/test_acli_integration.py` that specify the behavior of `acli-integration.py` before it exists. Tests must fail (RED) because the module does not yet exist. Cover: subprocess invocation for create/update/get, retry logic on network failure, verify-after-create sequence.

TDD Requirement: This IS the RED test task. Tests fail because `acli-integration.py` does not exist. Named tests:
- `test_create_issue_calls_acli_subprocess` — asserts subprocess.run called with correct ACLI args for issue creation
- `test_update_issue_calls_acli_with_jira_key` — asserts update command includes the Jira key
- `test_get_issue_returns_parsed_json_output` — asserts parsed output dict contains expected fields
- `test_retry_on_subprocess_error_three_attempts` — asserts three retries with backoff delays (2s, 4s, 8s) when subprocess raises CalledProcessError
- `test_verify_after_create_calls_get_issue` — asserts create_issue calls get_issue after creation before returning

## ACCEPTANCE CRITERIA

- [ ] `tests/scripts/test_acli_integration.py` exists with at least 5 test functions
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_acli_integration.py && grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_acli_integration.py | awk '{exit ($1 < 5)}'
- [ ] Running tests returns non-zero exit (RED — module does not yet exist)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_acli_integration.py 2>&1; test $? -ne 0
- [ ] ruff check passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/tests/scripts/test_acli_integration.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/tests/scripts/test_acli_integration.py

## Notes

**2026-03-21T22:19:38Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T22:20:09Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T22:20:58Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T22:21:10Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T22:21:54Z**

CHECKPOINT 5/6: Validation passed ✓ — ruff check and format pass on test_acli_integration.py; pre-existing ruff issues in test_bridge_outbound.py (sibling RED task w21-3bqw, not in scope)

**2026-03-21T22:22:13Z**

CHECKPOINT 6/6: Done ✓ — All AC pass: AC1 (6 test functions), AC2 (exit 1), AC3 (ruff check clean), AC4 (ruff format clean)

**2026-03-21T22:56:03Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/scripts/test_acli_integration.py. Tests: RED state (6 errors, correct).
