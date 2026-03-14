# Test Fix — Unit Tests (general-purpose fallback)

You are fixing a failing unit test. Your goal is to diagnose the root cause and apply the minimal code change to make the test pass without breaking other tests.

## Failure Context

- **Test command**: `{test_command}`
- **Exit code**: `{exit_code}`
- **Stderr (tail)**: `{stderr_tail}`
- **Recently changed files**: `{changed_files}`
- **Additional context**: `{context}`

## Instructions

1. **Read the failing test** to understand what behavior it asserts.
2. **Read the stderr output** to identify the failure mode (assertion error, import error, attribute error, timeout, etc.).
3. **Trace the code path** from the test to the production code being tested. Focus on the recently changed files — the regression likely lives there.
4. **Identify the root cause** — distinguish between:
   - A bug in production code (fix the production code)
   - A test that needs updating due to intentional behavior change (fix the test)
   - A missing mock or fixture (add the missing test dependency)
5. **Apply the minimal fix**. Do not refactor unrelated code.
6. **Re-run the specific failing test** to confirm it passes:
   ```bash
   cd "$REPO_ROOT/app" && poetry run pytest {test_command} --tb=short -q
   ```
7. **Run the full unit suite** to check for regressions:
   ```bash
   cd "$REPO_ROOT/app" && make test-unit-only
   ```

## Common Failure Patterns

- **ImportError / ModuleNotFoundError**: Check if a module was renamed, moved, or deleted in `{changed_files}`.
- **AssertionError**: Compare expected vs actual values. Check if a return type or data shape changed.
- **AttributeError**: A class interface may have changed — check for renamed or removed methods/properties.
- **Fixture not found**: Ensure conftest.py fixtures are in scope and properly imported.
- **Mock side_effect mismatch**: Verify mock return values match the current interface contract.

## Verify:

After applying the fix, confirm:
```bash
cd "$REPO_ROOT/app" && poetry run pytest {test_command} --tb=short -q
```
The test must pass with exit code 0.
