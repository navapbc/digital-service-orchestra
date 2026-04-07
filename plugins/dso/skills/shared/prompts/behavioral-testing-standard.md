<!-- REVIEW-DEFENSE: No agent currently references this file by design. This is the walking skeleton
     story for the behavioral-testing-standard shared prompt. Sibling stories (80c9-df3c, 967e-f219,
     d82f-f58a, b669-fee9) in the same epic will update dso:red-test-writer, dso:red-test-evaluator,
     and the sprint/fix-bug dispatch prompts to load this standard. The file must exist before those
     stories can reference it. The "two parallel sources of truth" state is intentional and temporary
     — it will be resolved when the sibling stories are executed. -->

# Shared Behavioral Testing Standard

Standalone prompt fragment for test-writing agents. Applies to all test creation and review tasks across any skill that writes or evaluates tests. The standard is grounded in four research references:

- **Google's "unchanging test" principle** — a test should only change when the behavior it describes changes.
- **Khorikov's "resistance to refactoring" pillar** — tests must survive implementation-preserving refactoring without modification.
- **Sam Hatoum's refactoring litmus test** — if a test breaks when you refactor without changing behavior, the test is wrong.
- **Di Grazia et al. ASE 2025** — approximately 25% of LLM-generated test oracles produce false positives when the LLM writes tests from implementation details rather than from observable behavior.

---

## Rule 1 — Before Writing: Check for Existing Coverage

Before writing any new test, search for tests that already exercise the behavior.

1. Search the test directory for the function name, module name, or behavior keyword.
2. Read the 1–2 most relevant test files that surface.
3. If an existing test already covers the behavior — even in a different test file — do **not** write a duplicate test. Note the existing test in your output and move on.

**Rationale**: Duplicate tests for the same behavior create maintenance burden and cause confusion when behavior changes — both tests must be updated, often diverging over time. The goal is one authoritative test per behavior, not coverage for its own sake.

---

## Rule 2 — What to Test: Observable Behavior, Not Implementation

Write tests in **Given / When / Then** format. Each test covers exactly one behavior.

**Given**: the preconditions and inputs.
**When**: the action or invocation.
**Then**: the observable outcome — output value, exit code, file written, or side effect.

**Constraints:**

- **One test, one behavior.** Do not combine multiple behaviors in a single test case. If you need to assert two independent facts, write two tests.
- **No internal method names in assertions.** Assertions must not reference private functions, internal class names, or intermediate variables that are not part of the public interface.
- **Test observable outcomes.** Assert on what the system produces for its caller or environment: return values, stdout, exit codes, written files, emitted events. Do not assert on how the system produces them.

**Anti-pattern example** (do not do this):
```
assert result._normalize_path_called == True   # internal method name
assert result.intermediate_buffer == expected  # internal state
```

**Correct pattern:**
```
# Given a path with trailing slash
# When normalize() is called
# Then the returned path has no trailing slash
assert normalize("/foo/bar/") == "/foo/bar"
```

---

## Rule 3 — How to Test: Execute, Don't Inspect

Run the code under test and assert on its output, exit code, or side effects.

**Required:**
- Execute the function, script, or module under the conditions described in the test.
- Assert on the value returned, the exit code produced, the file written, or the state change observable from outside the module.

**Prohibited:**
- **Never read source files as test assertions.** Do not `grep` or `cat` the source file to verify that a function contains a particular line of code. This tests the text of the implementation, not its behavior.
- **Never mock internal modules.** Mocking a module that is internal to the unit under test asserts on the unit's internal structure, not its behavior. When the implementation is reorganized without changing behavior, the mock breaks.
- **Mock only external boundaries** — databases, network calls, third-party APIs, system clocks, and file I/O that would make tests non-deterministic or slow. Mock at the boundary where your code meets something outside your control.

**Examples of correct boundary mocking:**
- A HTTP client used to call an external API: mock it.
- A database driver: mock it.
- An internal helper function used by the module under test: do NOT mock it — call the real implementation.

---

## Rule 4 — After Writing: Refactoring Litmus Test

Before accepting any test as complete, apply the refactoring litmus test:

> **Would this test break if someone renamed an internal variable, extracted a private method, or reorganized the module structure — without changing observable behavior?**

If the answer is **yes**, the test is a change-detector, not a behavior-verifier. Change-detectors produce false positives (flagging safe refactoring as broken behavior) and erode trust in the test suite.

**When the litmus test fails, rewrite the test:**

1. Identify which assertion targets an internal name, structure, or detail.
2. Replace it with an assertion on the observable output that the internal detail was computing.
3. Re-apply the litmus test until the answer is **no**.

**Litmus test examples:**

| Test assertion | Litmus result | Reason |
|----------------|---------------|--------|
| `assert parser._tokenize(input) == tokens` | Fails — change-detector | `_tokenize` is internal; renaming it breaks the test without changing behavior |
| `assert parse(input) == expected_ast` | Passes | Asserts on the public output of the parser |
| `assert formatter.indent_level == 2` | Fails — change-detector | Internal state; behavior is the formatted string, not how it was tracked |
| `assert format(code) == expected_output` | Passes | Asserts on the observable formatted output |
| `grep -c "def _helper" source.py` | Fails — change-detector | Reads source text; any refactoring that renames or removes the helper breaks it |

---

## Usage by Test-Writing Agents

When dispatched to write tests for a story or task:

1. Read this file to load the standard.
2. Apply Rule 1 first — check for existing coverage before writing anything.
3. Draft tests using Rule 2 (Given/When/Then, one behavior per test).
4. Verify each test follows Rule 3 (execute, don't inspect; mock only external boundaries).
5. Apply Rule 4 litmus test to every assertion before submitting.
6. Include in your output a `behavioral_testing_compliance` block:

```json
{
  "behavioral_testing_compliance": {
    "rule1_coverage_checked": true,
    "existing_tests_found": [],
    "rule2_gwt_format": true,
    "rule3_no_source_reads": true,
    "rule3_mocks_at_boundaries_only": true,
    "rule4_litmus_passed": true,
    "change_detectors_rewritten": 0
  }
}
```

This standard is the single source of truth for behavioral test quality in this codebase. Neither story-level instructions nor orchestrator prompts may override it.
