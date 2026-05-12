# Shared Behavioral Testing Standard

Standalone prompt fragment for test-writing agents. Applies to all test creation and review tasks across any skill that writes or evaluates tests. This is a 5-rule standard (with a Rule 5 addendum covering remote-runtime declarative configuration artifacts) grounded in four research references:

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
- **Do not assert on static-analysis-detectable properties.** Tests must not verify naming conventions, import order, formatting, type annotations, unused variables, or other properties that the project's linter, formatter, or type checker already enforce. Static analysis handles these deterministically; tests duplicating them produce noise and break when lint configuration changes rather than when behavior changes.

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

## Rule 5 — Instruction Files: Test the Structural Boundary, Not the Content

Non-executable LLM instruction files — skills, prompts, agent definitions, and hook behavioral logic — cannot be deterministically tested for behavioral correctness. An LLM's interpretation of an instruction is probabilistic; writing assertions about whether the instruction "works" produces tests that are either tautological or non-deterministic.

**Testing boundary for non-executable artifacts:**

Test ONLY at the deterministic integration interface. Acceptable structural test categories:

| Category | What is tested | Example |
|----------|---------------|---------|
| **Contract schema validation** | Required section headings, mandatory fields, structural markers | `## Purpose` section exists in contract files |
| **Referential integrity** | Paths referenced in instruction files point to files that exist | `check-referential-integrity.sh` on skills/prompts |
| **Shim compliance** | No direct plugin script paths; use `.claude/scripts/dso <name>` shim | `check-shim-refs.sh` on instruction files |
| **Syntax checks** | File is parseable as its format (YAML, JSON, Markdown) | `python3 -c "import yaml; yaml.safe_load(open(f))"` |
| **Deployment prerequisites** | File is executable where required | `test -x script.sh` |

**NOT acceptable for non-executable instruction files:**

- `test -f <instruction-file>` as a standalone assertion — existence-only checks are change-detector tests that break when files are renamed or reorganized without changing behavior.
- `grep`-based content assertions that check whether a specific phrase, word, or sentence appears in instruction file body text — these test the text of the implementation, not its behavioral contract. They break on any edit that preserves intent but changes wording.
- `grep`-based section-heading assertions on instruction files (e.g., `grep -q "^## Severity Calibration Rubric" reviewer-base.md`) UNLESS the heading is a tooling-parsed structural marker (see "Heading interface vs. heading organization" below) — organizational headings are content; renaming or restructuring them is a safe refactor that should not break tests.

**Heading interface vs. heading organization (clarification of Rule 5 — bug 725c-5159):**

A section heading is part of the structural contract ONLY when it is parsed or referenced by tooling outside the file itself. Apply this two-question test before adding a heading-grep assertion:

1. Does any script, hook, validator, or other automated consumer parse this heading by name? (e.g., `validate-review-output.sh`, `check-shim-refs.sh`, an MCP probe, a contract validator)
2. Is the heading published in a contract document (`docs/contracts/*.md`) or referenced by a stable external schema?

If either is `yes`: the heading IS the interface — grep is appropriate, like `## SUB-AGENT-GUARD` (parsed by skill-dispatch logic) or `## Purpose` in a contract file (required by contract schema validation).

If both are `no`: the heading is organizational content. Renaming `## Severity Calibration Rubric` to `## Calibration Rules` is a safe refactor that preserves intent — a test that breaks on that rename is a change-detector test (Rule 4), not a structural assertion. Replace it with a behavioral test that submits a finding and asserts the validator/agent applies the calibration as expected.

**What this rule prohibits and why:**

```bash
# PROHIBITED: grep on instruction content (tests wording, not behavior)
grep -q "always use" ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md

# PROHIBITED: existence-only test with no structural contract purpose
test -f ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md

# ALLOWED: structural contract check (section heading is the interface)
grep -q "^## SUB-AGENT-GUARD" ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md

# ALLOWED: referential integrity (path existence is the contract)
test -f ".claude/scripts/dso"  # shim-exempt: illustrative example in documentation
```

**Rationale:** Behavioral correctness for LLM instruction content cannot be deterministically tested — the LLM's response to an instruction depends on context, model version, and sampling parameters. Tests that assert on instruction wording produce false positives on safe edits and erode trust in the test suite. The structural boundary (schema, integrity, compliance, syntax) is deterministic and provides real regression protection.

### Rule 5 Addendum — Declarative Configuration Artifacts

Declarative configs that execute in remote runtimes (GitHub Actions workflows, Ruleset JSON, Kubernetes manifests, Terraform, cron schedules, OpenAPI specs) cannot be deterministically executed locally. Apply Rule 5's structural-boundary discipline, with one expansion: when the format has an authoritative validator, running the validator IS an acceptable behavioral test.

| Artifact | Validator-based test |
|---|---|
| `.github/workflows/*.yml` | `actionlint <file>` |
| GitHub Ruleset JSON | `gh api ... --method GET --silent` round-trip, or JSON-schema validation |
| Kubernetes manifests | `kubectl apply --dry-run=client -f <file>` |
| Terraform | `terraform validate` |
| OpenAPI specs | `openapi-spec-validator <file>` |

A passing validator certifies parseability and schema validity — not runtime behavior. Pair it with the brainstorm executable-artifact SC for end-to-end verification.

---

## Usage by Test-Writing Agents

When dispatched to write tests for a story or task:

1. Read this file to load the standard.
2. Apply Rule 1 first — check for existing coverage before writing anything.
3. Draft tests using Rule 2 (Given/When/Then, one behavior per test).
4. Verify each test follows Rule 3 (execute, don't inspect; mock only external boundaries).
5. Apply Rule 4 litmus test to every assertion before submitting.
6. If the artifact under test is a non-executable instruction file (skill, prompt, agent definition, hook behavioral logic), apply Rule 5: test only the structural boundary (contract schema, referential integrity, shim compliance, syntax checks, deployment prerequisites). Do NOT write content assertions or existence-only checks.
7. Include in your output a `behavioral_testing_compliance` block:

```json
{
  "behavioral_testing_compliance": {
    "rule1_coverage_checked": true,
    "existing_tests_found": [],
    "rule2_gwt_format": true,
    "rule3_no_source_reads": true,
    "rule3_mocks_at_boundaries_only": true,
    "rule4_litmus_passed": true,
    "change_detectors_rewritten": 0,
    "rule5_applied": true,
    "rule5_artifact_type": "executable | non-executable-instruction",
    "rule5_structural_boundary_only": true
  }
}
```

This standard is the single source of truth for behavioral test quality in this codebase. Neither story-level instructions nor orchestrator prompts may override it.
