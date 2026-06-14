# Behavioral Testing Standard

Reusable evaluation knowledge for any prompt that writes or reviews tests
(`generation/write-behavioral-test`, `review/review-test-quality`,
`review/review-code-deep-verification`). This is the authoritative, full version;
those prompts embed the operative subset they apply and cite this standard for the
complete rules and examples. It is grounded in four references:

- **Google's "unchanging test" principle** — a test should change only when the
  behavior it describes changes.
- **Khorikov's "resistance to refactoring" pillar** — tests must survive
  implementation-preserving refactoring unmodified.
- **Hatoum's refactoring litmus test** — if a test breaks when you refactor
  without changing behavior, the test is wrong.
- **Di Grazia et al., ASE 2025** — ~25% of LLM-generated test oracles are false
  positives when the LLM writes tests from implementation details rather than
  observable behavior.

---

## Rule 1 — Before writing: check for existing coverage

Search for tests that already exercise the behavior (by function/module/behavior
keyword); read the 1–2 most relevant test files; if one already covers the
behavior — even in a different file — do not write a duplicate. One authoritative
test per behavior, not coverage for its own sake.

## Rule 2 — What to test: observable behavior, not implementation

Write in **Given / When / Then**: given preconditions/inputs, when the
action/invocation, then the observable outcome (return value, exit code, file
written, emitted event). Constraints: one test, one behavior; no internal/private
names or intermediate state in assertions; assert on what the system produces for
its caller/environment, not how; do not assert on static-analysis-detectable
properties (naming, import order, formatting, types) — the linter/formatter/type
checker own those deterministically.

```
# Anti-pattern (do not do this)
assert result._normalize_path_called == True   # internal method name
assert result.intermediate_buffer == expected  # internal state

# Correct
assert normalize("/foo/bar/") == "/foo/bar"    # observable output
```

## Rule 3 — How to test: execute, don't inspect

Run the code under test; assert on its output/exit code/side effects.

- **Never read source files as assertions** (no `grep`/`cat` of the source to
  verify a line exists — that tests the text, not the behavior).
- **Never mock internal modules** (mocking a unit-internal module asserts on
  internal structure; it breaks on behavior-preserving reorganization).
- **Mock only external boundaries** — databases, network, third-party APIs, the
  system clock, nondeterministic/slow I/O. An internal helper is called for real;
  an HTTP client or DB driver is mocked.

## Rule 4 — After writing: refactoring litmus test

> Would this test break if someone renamed an internal variable, extracted a
> private method, or reorganized the module — *without* changing observable
> behavior?

If **yes**, it is a change-detector, not a behavior-verifier: replace the
assertion that targets the internal detail with one on the observable output it
computed, and re-apply until the answer is **no**.

| Assertion | Litmus | Reason |
|-----------|--------|--------|
| `assert parser._tokenize(input) == tokens` | Fails (change-detector) | `_tokenize` is internal |
| `assert parse(input) == expected_ast` | Passes | public output |
| `assert formatter.indent_level == 2` | Fails | internal state |
| `assert format(code) == expected_output` | Passes | observable output |
| `grep -c "def _helper" source.py` | Fails | reads source text |

## Rule 5 — Instruction files: test the structural boundary, not the content

Non-executable LLM instruction files (skills, prompts, agent definitions, hook
behavioral logic) cannot be deterministically tested for behavioral correctness —
an LLM's interpretation is probabilistic. Test ONLY the deterministic integration
interface: contract-schema validation (required headings/fields/markers),
referential integrity (referenced paths exist), shim/convention compliance,
syntax/parse checks, deployment prerequisites (executable bit).

**Not acceptable** for such files: existence-only assertions (`test -f file`);
`grep`-based content assertions on body prose (they test wording, not the
behavioral contract, and break on intent-preserving edits); `grep` on
*organizational* section headings.

**Heading interface vs. organization — and the non-human-consumer litmus.** A
grepped string is a legitimate contract test only when **something other than a
human or LLM reads that exact token**:

> Is the grepped string read by a non-human consumer (a parser/validator that
> branches on the value; a downstream `grep`/`awk`/`sed` selecting the token; a
> registry/manifest reader; a workflow runner branching on a literal)?
> YES → contract test (grep appropriate). NO → change-detector (it guards the
> author's wording, not behavior).

The LLM is **not** a non-human consumer here: LLMs are robust to paraphrase
("5-second"/"five seconds" behave identically), and whether the LLM actually obeys
an instruction is testable only by running it on a representative input — not by
grepping the prompt for "intent words."

| Pattern | Verdict |
|---------|---------|
| `grep -q "Inputs"` heading in a skill file | change-detector (rename preserves intent) |
| `grep -q "5-second"` in a prompt | change-detector (soft instruction, not a parsed constant) |
| `grep -qiE "rationali[sz]"` | change-detector (tests flavor of language) |
| `grep -q "<approved-tag>"` consumed by a CLI/hook | contract test (exact token) |
| YAML frontmatter `name:`/`model:` validated by a loader | contract test |
| `grep -q "<config-enum-value>"` branched on by a config reader | contract test |

### Rule 5 addendum — declarative configuration artifacts

For declarative configs that execute in a remote runtime (CI workflow YAML,
ruleset JSON, k8s manifests, Terraform, OpenAPI), apply Rule 5's structural
discipline, with one expansion: **running the format's authoritative validator IS
an acceptable behavioral test** (e.g. `actionlint <workflow>`, `kubectl apply
--dry-run=client`, `terraform validate`, an OpenAPI validator, JSON-schema
validation of a ruleset). A passing validator certifies parseability/schema
validity, not runtime behavior — pair it with an end-to-end check.

## Rule 6 — Environment-state-absent coverage

When the code under test consumes **runtime environment state** — git
config/identity, mounted worktrees/branches/refs outside the test's own repo,
environment variables that exist on a developer machine but not a clean CI runner
(`HOME`, identity vars, tokens, cloud profiles), or files/dirs present by default
on a dev machine but not a fresh container — the suite MUST include at least one
case where that state is explicitly **absent**, with the expected behavior under
absence documented in the test name/comment.

```python
def test_command_works_without_global_git_config(tmp_path, monkeypatch):
    fake_home = tmp_path / "fake-home"; fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    result = run(["git", "commit", "--allow-empty", "-m", "t"], cwd=str(tmp_path))
    assert result.returncode in (0, 128)   # document the expected behavior
```

**Applies when** the unit calls `git config`, `git worktree …`, `subprocess`/git
without an isolated `env=`/`HOME`, or any command whose behavior differs between a
configured dev machine and a minimal CI image. This extends Rule 3: the
developer's ambient environment is an external boundary — isolate it like a
network call. (Field-observed: multiple production-only defects passed all
developer tests because fixtures inherited the dev's global git config and
pre-existing worktrees, none of which exist on CI.)

---

## Compliance block

A test-writing prompt applying this standard should emit:

```json
{
  "behavioral_testing_compliance": {
    "rule1_coverage_checked": true, "existing_tests_found": [],
    "rule2_gwt_format": true,
    "rule3_no_source_reads": true, "rule3_mocks_at_boundaries_only": true,
    "rule4_litmus_passed": true, "change_detectors_rewritten": 0,
    "rule5_applied": true, "rule5_artifact_type": "executable | non-executable-instruction",
    "rule6_applied": true, "rule6_env_state_consumed": "git_config | worktrees | env_vars | none",
    "rule6_absent_state_test_written": true
  }
}
```

This standard is the single source of truth for test quality; neither task-level
instructions nor orchestrator prompts override it.
