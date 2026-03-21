---
id: w21-hbjx
status: closed
deps: [w21-mrqh]
links: []
created: 2026-03-21T22:11:03Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-8cw2
---
# Implement acli-integration.py ACLI subprocess wrapper

## Description

Create `plugins/dso/scripts/acli-integration.py`.

Functions: `create_issue(ticket_data, acli_cmd=None)`, `update_issue(jira_key, ticket_data, acli_cmd=None)`, `get_issue(jira_key, acli_cmd=None)`. All accept injectable `acli_cmd` parameter defaulting to `['acli']` for testability.

Retry with exponential backoff: 3 attempts at 2s/4s/8s intervals on subprocess.CalledProcessError.

`create_issue` calls `get_issue` after creation (verify-after-create) and raises if issue not found.

Sets ACLI JVM flag `-Duser.timezone=UTC` via JAVA_TOOL_OPTIONS env var in subprocess call.

No new runtime dependencies — uses subprocess, json, time, os from stdlib.

TDD Requirement: Task w21-mrqh's tests (`test_create_issue_calls_acli_subprocess`, `test_update_issue_calls_acli_with_jira_key`, `test_get_issue_returns_parsed_json_output`, `test_retry_on_subprocess_error_three_attempts`, `test_verify_after_create_calls_get_issue`) must pass GREEN after this task.

## ACCEPTANCE CRITERIA

- [ ] `plugins/dso/scripts/acli-integration.py` exists and is importable via importlib
  Verify: python3 -c 'import importlib.util, pathlib; spec = importlib.util.spec_from_file_location("acli_integration", pathlib.Path("$(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py")); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)'
- [ ] `create_issue`, `update_issue`, `get_issue` functions exist
  Verify: python3 -c 'import importlib.util, pathlib; spec = importlib.util.spec_from_file_location("acli_integration", pathlib.Path("$(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py")); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); assert hasattr(mod, "create_issue") and hasattr(mod, "update_issue") and hasattr(mod, "get_issue")'
- [ ] All 5 RED tests from w21-mrqh pass (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_acli_integration.py -q --tb=short
- [ ] ruff check passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py
- [ ] No secrets/credentials hardcoded — acli_cmd and jira config passed as parameters only
  Verify: ! grep -qE 'JIRA_TOKEN|JIRA_API_TOKEN|password\s*=' $(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py
- [ ] When all 3 retry attempts are exhausted, CalledProcessError is re-raised (not swallowed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_acli_integration.py::test_retry_on_subprocess_error_three_attempts -q
- [ ] verify-after-create: when get_issue returns no issue after creation, an exception is raised (SYNC event is NOT written)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_acli_integration.py::test_verify_after_create_calls_get_issue -q

## Notes

**2026-03-21T23:10:25Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T23:10:42Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T23:10:46Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T23:11:19Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T23:11:32Z**

CHECKPOINT 5/6: Validation passed — 6 tests pass, ruff clean ✓

**2026-03-21T23:11:52Z**

CHECKPOINT 6/6: Done ✓
