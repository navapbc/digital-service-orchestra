---
name: tdd-workflow
description: Test-Driven Development workflow for bug fixes
user-invocable: true
---

# TDD Bug Fix Workflow

Use Test-Driven Development to ensure bug fixes are correct and prevent regression.


## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)
FORMAT_CHECK_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.format_check)
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — replaces `make test` in RED, GREEN, REFACTOR, and VALIDATE steps
- `LINT_CMD` — replaces `make lint` in VALIDATE step
- `FORMAT_CHECK_CMD` — replaces `make format-check` in VALIDATE step

## The Red-Green-Refactor Cycle

```
Cycle: RED (Write failing test) → GREEN (Minimal fix) → REFACTOR (Clean up) → VALIDATE (Full test suite) → Done
```

**Why TDD for bugs?**
- The failing test proves you understand the bug
- The passing test proves your fix works
- The test prevents the bug from recurring

## Steps

### 1. RED: Write a Failing Test

Create a test that reproduces the bug before writing any fix code.

```python
# tests/unit/test_<module>.py

def test_bug_<description>():
    """Reproduce: <link to issue or description>"""
    # Arrange: Set up conditions that trigger the bug
    input_data = create_invalid_input()

    # Act: Call the function/method
    result = function_under_test(input_data)

    # Assert: Verify expected (correct) behavior
    assert result == expected_correct_behavior
```

Run the test to confirm it fails:

```bash
make test  # Should see your new test FAIL
```

**Important**: If the test passes immediately, your test does not capture the bug. Rethink the assertion.

### 2. GREEN: Implement Minimal Fix

- Change ONLY what is necessary to make the test pass
- No refactoring, no "improvements", no new features
- Resist scope creep

```bash
make test  # Should PASS
```

### 3. REFACTOR: Clean Up (Optional)

Only refactor if code quality issues are obvious:
- Remove duplication introduced by the fix
- Improve variable names
- Extract helper functions if logic is complex

**Rule**: Tests must still pass after refactoring.

```bash
make test  # Should still PASS
```

### 4. VALIDATE: Full Test Suite

Run the complete validation to ensure no regressions:

```bash
# Quick validation
make format-check && make lint && make test

# Full CI validation (recommended before commit)
# Use Bash timeout: 960000 (16 min) — smart CI wait can poll up to 15 min
${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh --ci
```

## Example

**Bug report**: "Email validation accepts `user@` without domain"

### Step 1: RED - Write the failing test (/dso:tdd-workflow)

```python
# tests/unit/services/test_email_validation.py
import pytest
from src.services.validation import validate_email, ValidationError

def test_email_rejects_missing_domain():
    """Bug: system accepts emails without domain part after @"""
    with pytest.raises(ValidationError):
        validate_email("user@")
```

Run test:
```bash
make test
# FAILED tests/unit/services/test_email_validation.py::test_email_rejects_missing_domain
```

The test fails because the current code does not validate the domain part.

### Step 2: GREEN - Implement minimal fix (/dso:tdd-workflow)

```python
# src/services/validation.py
import re

def validate_email(email: str) -> bool:
    """Validate email format.

    Raises:
        ValidationError: If email format is invalid
    """
    # Pattern requires: local-part @ domain . tld
    if not re.match(r"^[\w\.-]+@[\w\.-]+\.\w+$", email):
        raise ValidationError("Invalid email format")
    return True
```

Run test:
```bash
make test
# PASSED tests/unit/services/test_email_validation.py::test_email_rejects_missing_domain
```

### Step 3: VALIDATE - Full test suite (/dso:tdd-workflow)

```bash
make format-check && make lint && make test
# All checks pass

# Use Bash timeout: 960000 (16 min) — smart CI wait can poll up to 15 min
${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh --full --ci
# Full validation passes
```

## Common Pitfalls

| Pitfall | Problem | Solution |
|---------|---------|----------|
| Test passes immediately | Test does not capture the bug | Rethink the assertion; verify test fails with current code |
| Fixing more than the bug | Scope creep; risk of introducing new bugs | Stay focused; create separate issues for other problems |
| Skipping the failing test | No proof you understand the bug | The failing test is essential; always start with RED |
| Large refactor during GREEN | Mixing concerns; harder to debug | Keep GREEN minimal; refactor separately in REFACTOR step |
| Not running full validation | May introduce regressions elsewhere | Always run `make lint && make test` before commit |
| Committing without CI check | CI may catch issues local tests miss | Wait for `$(git rev-parse --show-toplevel)/scripts/ci-status.sh --wait` to return success |

## Test Location Guidelines

| Bug Location | Test Location |
|--------------|---------------|
| `src/api/{feature}/` | `tests/unit/api/{feature}/` |
| `src/services/{service}/` | `tests/unit/services/{service}/` |
| `src/extraction/` | `tests/unit/extraction/` |
| `src/output/` | `tests/unit/output/` |
| Integration issues | `tests/integration/` |
| UI/workflow issues | `tests/e2e/` |

## Quick Reference Commands

```bash
# Run specific test file
poetry run pytest tests/unit/path/to/test_file.py -v

# Run specific test function
poetry run pytest tests/unit/path/to/test_file.py::test_function_name -v

# Run with output shown
poetry run pytest -v -s

# Run and stop on first failure
poetry run pytest -x

# Full validation (use Bash timeout: 960000 — smart CI wait can take up to 15 min)
${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh --full --ci
```
