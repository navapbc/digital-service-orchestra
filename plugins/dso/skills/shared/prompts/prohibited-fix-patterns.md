# Prohibited Fix Patterns

Shared anti-pattern catalog consumed by sub-agent prompts in `/dso:sprint`, `/dso:fix-bug`, and `/dso:debug-everything`. These six patterns are **never** acceptable ways to make tests pass. They hide the root cause rather than fixing it. Treat any impulse to use them as a signal that you need to investigate deeper.

## 1. Skipping or removing tests

Removing or skipping a failing test hides the real failure instead of fixing it.

```python
# PROHIBITED
@pytest.mark.skip(reason="flaky")
def test_important_behavior():
    ...
```

Do this instead: Fix the underlying code so the test passes. If the test is genuinely wrong, update the assertion to reflect the correct expected behavior and document why.

## 2. Loosening assertions

Weakening assertions so a test passes without fixing the underlying logic masks the bug.

```python
# PROHIBITED — changed from assertEqual to assertIn just to pass
assert result in [expected, None]  # was: assert result == expected
```

Do this instead: Fix the implementation so the original assertion holds. If the spec changed, update the assertion to the new correct value with a comment explaining the change.

## 3. Broad exception handlers

Catching broad exceptions swallows errors and hides the root cause, making tests appear to pass when they should fail.

```python
# PROHIBITED
try:
    result = do_something()
except Exception:
    pass  # silently ignore all failures
```

Do this instead: Catch only the specific exception you expect and handle it correctly. Let unexpected exceptions propagate so failures are visible.

## 4. Downgrading error severity

Changing an assertion or error to a warning so execution continues covers up a genuine failure.

```python
# PROHIBITED
# was: assert result == expected
import warnings
warnings.warn(f"result {result!r} does not match {expected!r}")
```

Do this instead: Fix the root cause so the assertion passes. If severity genuinely changed, document the reasoning explicitly.

## 5. Commenting out failing code

Commenting out the code that causes a failure hides the defect without resolving it.

```python
# PROHIBITED
# assert check_integrity(data), "data integrity check failed"
```

Do this instead: Understand why the check fails and fix the underlying data or logic so the check passes.

## 6. Reverting and retrying without investigating

Reverting a fix attempt and trying a different approach without understanding WHY the tests failed leads to repeated failures of the same kind.

```python
# PROHIBITED pattern (behavioral, not code):
# Attempt 1: change X → tests fail → revert
# Attempt 2: change Y → tests fail → revert
# Attempt 3: change Z → tests fail → revert
# Result: "needs more care" / deferred
```

Do this instead: When tests fail after your change, investigate the specific test failures BEFORE reverting. Read the failing test, trace the dependency chain, and understand what your change broke and why. The next attempt must be informed by the previous failure's root cause.
