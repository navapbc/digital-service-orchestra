# Shared Behavioral Testing Standard

Standalone prompt fragment for test-writing agents. Applies to all test creation and review tasks across any skill that writes or evaluates tests. This is a 6-rule standard (with a Rule 5 addendum covering remote-runtime declarative configuration artifacts) grounded in four research references:

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

**The non-human-consumer test (extension of bug 725c-5159 — bug acff-b6eb-fp01):**

The two-question test above generalizes beyond headings to any grep-on-prose assertion. Restated as a single litmus:

> **Is the grepped string read by something other than a human (or an LLM)?**
> If YES: contract test — grep is appropriate.
> If NO: change-detector — grep guards the author's choice of wording, not behavior.

A non-human consumer is one of:
- A parser, validator, or schema-checker that branches on the exact value.
- A grep/awk/sed downstream of the file that selects on the same token.
- A registry / manifest reader (`.test-index`, `required-checks.txt`, plugin loader reading YAML keys).
- A workflow runner that branches on a literal token (CI step name parsed by `gh workflow run`, ruleset enum value).

The LLM is NOT a non-human consumer for the purpose of this rule. Two reasons:

1. **LLMs are robust to paraphrasing.** "5-second" / "five-second" / "five seconds" / "5 sec" all produce the same downstream behavior. A test that breaks on the rewrite catches no real regression.
2. **What the LLM does with a prompt is unverifiable by grep.** Whether the LLM actually behaves per the instruction is empirically testable only by running the LLM with a representative input and asserting the output. Grepping the prompt for "intent words" is a proxy that doesn't measure the intent.

The defense "the LLM consumes this prompt, so the prose IS the contract" does not rescue prose-grep from being a change-detector. The LLM's consumption is fuzzy; the test's match is exact. The two are mismatched.

**Common misapplications to avoid:**

| Pattern | Verdict | Why |
|---|---|---|
| `grep -q "Inputs"` in `SKILL.md` | Change-detector | "Inputs" is a heading word; renaming to "Required Inputs" preserves intent. |
| `grep -q "5-second"` in `SKILL.md` | Change-detector | The duration is a soft instruction to the LLM, not a parsed constant. |
| `grep -qiE "rationali[sz]"` (anti-rationalization language) | Change-detector | Tests for the *flavor* of warning language, not a parsed token. |
| `grep -q "baseline, adoption rate, A/B test"` (example list) | Change-detector | Examples are illustrative; any synonyms preserve intent. |
| `grep -q "design:approved"` in a script | Contract test | Exact tag token consumed by ticket CLI / hook. |
| `grep -q "<<inferred:"` in `SKILL.md` | Contract test | Token literally parsed by orchestrator regex elsewhere. |
| YAML frontmatter `name:` / `model:` / `description:` validation | Contract test | Plugin loader reads these field names. |
| `grep -q "dso.workflow=ci-pr"` in `dso-config.conf` | Contract test | Exact enum value branched on by `read-config.sh`. |

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

## Rule 6 — Environment-State-Absent Coverage

When the code under test consumes **runtime environment state** — git configuration, mounted worktrees, environment variables, file or directory presence outside the test's own `tmp_path` — the test suite MUST include at least one case where that state is explicitly **absent**, and the code's expected behavior under that absence is documented in the test name or comment.

**What counts as runtime environment state:**
- Git user identity (`user.name`, `user.email`) from global or system config
- Pre-existing git worktrees, branches, or refs outside the test's own repository
- Environment variables that may be set on a developer's machine but not in a clean CI runner (e.g., `HOME`, `GIT_AUTHOR_NAME`, `GIT_COMMITTER_EMAIL`, `GITHUB_TOKEN`, `AWS_PROFILE`)
- Files or directories that exist by default on a developer machine but not in a fresh container or minimal CI image

**Required test pattern when Rule 6 applies:**

```python
# Python — isolate HOME and git identity
def test_command_works_without_global_git_config(tmp_path, monkeypatch):
    # Given an isolated HOME with no git config
    fake_home = tmp_path / "fake-home"
    fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    # When the command runs
    result = run_command(["git", "commit", "--allow-empty", "-m", "test"], cwd=str(tmp_path))
    # Then it must either succeed (if it sets identity) or fail with a clear error (not a cryptic exit 128)
    assert result.returncode in (0, 128)  # document the expected behavior
```

```bash
# Bash — isolate HOME and git identity
test_advisory_lock_no_global_git_config() {
    local fake_home
    fake_home=$(mktemp -d)
    HOME="$fake_home" GIT_CONFIG_NOSYSTEM=1 \
        bash "${LOCK_SCRIPT}" --repo-root "${TEST_REPO}" || true
    # assert expected behavior with clean environment
}
```

**Detection heuristic for test-writing agents** — Rule 6 applies when the function, module, or script under test calls any of:
- `git config` (reads identity, remote, or local settings)
- `git worktree add` / `git worktree list` / `git worktree remove`
- `subprocess.run(["git", ...])` without setting `env=` or without a config-isolated `HOME`
- Any external command whose behavior differs between a configured developer machine and a minimal CI image

**Interaction with Rule 3** — Rule 6 extends Rule 3's "mock only external boundaries" guidance: the developer's ambient environment IS an external boundary. Tests that inherit `HOME`, `GIT_AUTHOR_NAME`, or pre-existing worktrees are importing uncontrolled state from the host machine, equivalent to making a real network call. Isolate it the same way you would isolate a network call.

**Rationale:** Three production-only defects in epic 4047 (5be7, 96c5, bbf0) passed all developer tests because the test fixtures inherited the developer's global git config and pre-existing worktrees. None of these conditions exist on CI runners. The fix cost was three separate PRs + CI cycle each. The Rule 6 test would have caught all three at unit-test time.

---

## Usage by Test-Writing Agents

When dispatched to write tests for a story or task:

1. Read this file to load the standard.
2. Apply Rule 1 first — check for existing coverage before writing anything.
3. Draft tests using Rule 2 (Given/When/Then, one behavior per test).
4. Verify each test follows Rule 3 (execute, don't inspect; mock only external boundaries).
5. Apply Rule 4 litmus test to every assertion before submitting.
6. If the artifact under test is a non-executable instruction file (skill, prompt, agent definition, hook behavioral logic), apply Rule 5: test only the structural boundary (contract schema, referential integrity, shim compliance, syntax checks, deployment prerequisites). Do NOT write content assertions or existence-only checks.
7. Apply Rule 6: if the code under test consumes runtime environment state (git config, mounted worktrees, env vars, file/directory presence outside tmp_path), include at least one test case where that state is explicitly absent.
8. Include in your output a `behavioral_testing_compliance` block:

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
    "rule5_structural_boundary_only": true,
    "rule6_applied": true,
    "rule6_env_state_consumed": "git_config | worktrees | env_vars | none",
    "rule6_absent_state_test_written": true
  }
}
```

This standard is the single source of truth for behavioral test quality in this codebase. Neither story-level instructions nor orchestrator prompts may override it.
