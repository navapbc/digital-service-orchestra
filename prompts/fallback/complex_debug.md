# Complex Debug — Fallback Prompt

You are diagnosing a complex error that may involve multiple interacting components. This prompt provides full diagnostic context equivalent to what a specialized error-detective agent would receive. Approach this systematically — complex bugs often have non-obvious root causes.

## Error Context

**Error output**:
```
{error_output}
```

**Stack trace**:
```
{stack_trace}
```

**Affected files**:
{affected_files}

**Related errors** (other failures that may share a root cause):
{related_errors}

**Recent changes** (commits or file modifications preceding the failure):
{recent_changes}

**Additional context**:
{context}

## Diagnostic Framework

### Phase 1: Classify the Error

1. **Parse the stack trace**: Identify the exception type, the originating file and line, and the call chain. Determine if this is a runtime error (TypeError, ValueError), an infrastructure error (ConnectionError, TimeoutError), or a logic error (assertion failure, wrong result).

2. **Check for known issues**: Search `.claude/docs/KNOWN-ISSUES.md` for similar errors. If the error matches a known pattern, apply the documented fix.

3. **Correlate with recent changes**: Compare the affected files against recent changes. If the error appeared after a specific commit, that commit is the primary suspect.

### Phase 2: Isolate the Root Cause

4. **Distinguish symptom from cause**: The file where the error occurs is often not the file that caused it. Trace the data flow backwards: what provided the input that triggered the exception? Was it a caller, a configuration, or a database record?

5. **Check for cascading failures**: If there are related errors, determine whether they share a common root cause or are independent. Fix the upstream error first — downstream errors may resolve automatically.

6. **Reproduce minimally**: Write a failing test that isolates the root cause. This confirms your hypothesis and guards against regression: `cd app && poetry run pytest tests/unit/<path>::<test_name> --tb=short -q`.

### Phase 3: Fix and Validate

7. **Apply the minimal fix**: Change only what is necessary to resolve the root cause. Avoid refactoring or cleanup in the same change — those should be separate tasks.

8. **Search for the same anti-pattern**: After fixing, search the codebase for other instances of the same bug pattern. Create tracking tickets for each occurrence found.

9. **Run the full validation suite**: Ensure the fix does not introduce regressions.

10. **Document if novel**: If this error pattern is not in KNOWN-ISSUES.md and is likely to recur, note it for addition.

## Common Root Causes

- **Import errors after refactoring**: Circular imports or moved modules. Check `__init__.py` exports.
- **Type mismatches from config changes**: A `PydanticBaseEnvConfig` field changed type but callers still pass the old type.
- **Database schema drift**: Model fields added/removed without migration. Check SQLAlchemy model vs actual DB schema.
- **Mock leakage**: A `@patch` decorator in tests not properly scoped, affecting subsequent tests.
- **Pipeline state corruption**: An agent node writing to `PipelineState` with wrong keys or types.

## Verify:

After applying the fix, run:
```bash
cd app && poetry run pytest tests/ --tb=short -q
```
Expected: the original error no longer occurs, no new failures introduced.
