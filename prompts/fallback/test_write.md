# Test Writing — Fallback Prompt

You are writing tests for existing code. Follow the project's TDD conventions and ensure tests are deterministic, isolated, and assert meaningful behavior rather than implementation details.

## Test Target

**Target to test**: `{test_target}`
**Test type**: `{test_type}`
**Source files under test**:
{source_files}

**Additional context**:
{context}

## Test Writing Guidelines

1. **Identify the public interface**: Read the source files and identify the public methods, functions, or endpoints that should be tested. Do not test private/internal methods directly — test them through the public API.

2. **Determine test boundaries**: For unit tests, mock external dependencies (database, LLM clients, file I/O). For integration tests, use real database fixtures. For E2E tests, exercise the full stack.

3. **Follow existing test patterns**: Look at neighboring test files in the same `tests/` subdirectory. Match the fixture usage, assertion style, and file naming conventions already in use.

4. **Write the RED test first**: Each test should fail before implementation changes (if applicable). Name tests descriptively: `test_<function>_<scenario>_<expected_outcome>`.

5. **Cover the critical paths**:
   - Happy path: normal inputs produce expected outputs
   - Edge cases: empty inputs, boundary values, None/null handling
   - Error cases: invalid inputs raise appropriate exceptions
   - State transitions: if the code manages state, test before and after

6. **Assert behavior, not implementation**: Assert on return values, side effects, and raised exceptions. Avoid asserting on call counts or internal variable values unless testing interaction contracts.

7. **Use appropriate fixtures**: Use `@pytest.fixture` for setup/teardown. Never use `autouse=True` for database fixtures. Prefer explicit fixture dependencies.

8. **Ensure isolation**: Each test must be independent. No test should depend on another test's side effects or execution order. Clean up any created resources.

9. **Check assertion density**: Each test should have at least one meaningful assertion. The project enforces assertion density via `make check-assertion-density`.

10. **Place tests correctly**: Unit tests go in `tests/unit/` mirroring the `src/` structure. Integration tests go in `tests/integration/`. E2E tests go in `tests/e2e/`.

## Verify:

Run the newly written tests to confirm they execute correctly:
```bash
cd app && poetry run pytest <test_file> --tb=short -q
```
Expected: all tests pass (GREEN), or fail for the right reason if implementation is pending (RED).
