# E2E Test Fix — Fallback Prompt

You are debugging an end-to-end test failure. E2E tests exercise the full application stack (HTTP requests, database, file storage, pipeline execution) and failures often involve environmental issues, timing problems, or integration mismatches that unit tests do not catch.

## Failure Context

**Test command**: `{test_command}`
**Exit code**: `{exit_code}`
**Last stderr output**:
```
{stderr_tail}
```
**Recently changed files**:
{changed_files}

**Additional context**:
{context}

## Diagnostic Steps

1. **Classify the failure type**: Determine whether this is a test infrastructure issue (DB not running, ports in use, missing env vars), a timing/race condition, an assertion failure from changed behavior, or a genuine regression.

2. **Check environment prerequisites**: E2E tests require a running database, correct ports, and specific environment variables. Verify `make db-status` shows a healthy database. Check that `APP_PORT` is not conflicting with another process.

3. **Examine the stderr output**: Look for connection refused errors (infrastructure), timeout errors (timing), assertion mismatches (logic), or import errors (dependency).

4. **Correlate with changed files**: If the changed files touch routes, middleware, or database models, the E2E failure is likely a direct consequence. If no relevant files changed, suspect environmental drift.

5. **Reproduce in isolation**: Run the single failing test with verbose output: `cd app && poetry run pytest <test_file>::<test_name> -v --tb=long -s`.

6. **Check for fixture contamination**: E2E tests sharing database state can cause order-dependent failures. Look for missing cleanup in fixtures or tests that assume an empty database.

7. **Inspect network and timing**: If the failure involves HTTP calls, check for missing `wait_for` logic or insufficient timeouts in the test setup.

## Fix Strategy

- If the exit code is non-zero but stderr is empty, the test runner itself may have crashed — check for syntax errors in test files or conftest.
- If stderr shows `ConnectionRefusedError`, ensure the test database and application server are running before the test suite.
- If stderr shows assertion failures, compare the expected vs actual values and trace back to the code change that altered the behavior.
- Apply the minimal fix that addresses the root cause. Do not add `sleep` calls or retry loops unless the failure is genuinely timing-related.
- After fixing, run the full E2E suite to ensure no other tests broke: `make test-e2e`.

## Verify:

Run the original test command to confirm the fix:
```bash
{test_command}
```
Expected: exit code 0, all assertions pass.
