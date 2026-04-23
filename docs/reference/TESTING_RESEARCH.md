# Test Bloat Elimination — Research Findings

**Date**: 2026-04-06
**Related epic**: Eliminate Test Bloat: Behavioral Testing Standards, Quality Gate, and Cleanup

---

## Research Thread 1: Test Bloat Detection Tools

### Language-Specific Tools

**PyNose** (JetBrains Research) — Python
- 17 test smells + Python-specific "Suboptimal Assert"
- pytest and unittest support, CLI mode
- 94% precision, 95.8% recall
- GitHub: JetBrains-Research/PyNose

**eslint-plugin-jest** — JavaScript/TypeScript
- ~50 rules including expect-expect, no-disabled-tests, no-conditional-expect
- Very actively maintained by jest-community

**eslint-plugin-testing-library** — JavaScript/TypeScript (React)
- 29 rules enforcing behavioral testing over implementation details
- no-container, no-node-access, prefer-screen-queries, prefer-user-event
- The strongest finding for behavioral vs structural test distinction (framework-specific)

**TSDetect** — Java
- 19 test smell types, 96% precision, 97% recall
- Academic origin (testsmells.org), moderate activity

### Language-Agnostic

**Semgrep (custom rules)** — 20+ languages
- AST-aware pattern matching can express custom rules for our specific anti-patterns
- Can detect: source-file-reading in tests, existence-only assertions, inspect.getsource usage
- Very actively maintained (Semgrep Inc.), large community
- **Recommended as the language-agnostic fallback**

**AgNose** — Multi-language via AST
- 8 test smells, framework-agnostic by design
- 96.9% precision, 87.5% recall
- Academic (2024-2025), early stage

### Key Gap
No tool specifically detects "change detector tests" out of the box. Semgrep custom rules are the most practical path for our specific anti-patterns.

---

## Research Thread 2: Claude Code Plugin Testing Patterns

### Claude Code Plugins on GitHub
**The honest answer: mostly no meaningful test suites exist.**

- **primeinc/claude-hooks** — The standout exception. Tests deterministic non-LLM components (frustration detector, bash command guards). No skill/prompt behavioral testing.
- **athola/claude-night-market** — Claims pytest suite across 22 plugins. Depth unconfirmed.
- **ivan-magda/claude-code-plugin-template** — CI/CD scaffolding, not behavior testing.
- No plugin found tests "when the LLM receives this skill definition, it produces correct behavior."

### Cursor / Copilot
- Cursor: No public framework for testing .cursorrules
- Copilot: Testing approach is manual — "use the editor play button to test your prompts"
- **Industry standard is still "try it and see"**

### LLM Prompt Testing Frameworks

| Framework | Approach | Maturity | Verdict |
|-----------|----------|----------|---------|
| DeepEval | pytest-native, probabilistic scoring, 50+ metrics | High | Best candidate if we wanted LLM-based eval |
| Braintrust | CI/CD quality gates via GitHub Action | High (commercial) | SaaS-dependent |
| Giskard | Auto-generated adversarial test cases | Medium-high | Complementary, not primary |
| Opik | Open-source eval platform with tracing | Medium | Lighter alternative to DeepEval |

### Docker-Based Testing (cagent VCR pattern)
- Record real LLM interaction as YAML cassette, replay deterministically
- Zero API cost on replay, millisecond execution
- **Rejected**: Any skill change invalidates the cassette — effectively a change detector test at workflow level

### Skill Testing Strategy (from analysis agent)

**Recommended layered strategy:**

| Layer | Approach | Gates | Catches |
|-------|----------|-------|---------|
| L2: Contract tests | Signal schema validation | Pre-commit | Signal format violations, interface drift |
| L3: Referential integrity | Cross-file reference linting | Pre-commit | Broken references to scripts, agents, contracts |

**Rejected approaches:**
- L1 (script behavior tests): Duplicates existing tests
- Docker E2E: Adds infrastructure overhead without solving non-determinism
- VCR/cassette: Change detector at workflow level
- Golden path traces: Replay problem fatal for CI gating

**Key insight**: Test what is deterministic deterministically. Accept that LLM reasoning quality cannot gate commits.

---

## Research Thread 3: Test Writing Prompts from Popular Plugins

### Finding 1: Sam Hatoum's CLAUDE.md (TCR + Behavioral Testing) ★ BEST FINDING
**URL**: https://gist.github.com/SamHatoum/8235db605e547754be4a7d5f7053abe7

- TDD with TCR (Test && Commit || Revert)
- **Behavioral vs structural distinction is explicit**
- **Litmus test**: "If I changed the internal data structure (Map to Array), would this test still pass?" If no → redesign
- Weak assertions forbidden (toBeDefined(), toBeTruthy())
- "Squint Test Pattern": SETUP → EXECUTE → VERIFY
- One test, one behavior, one commit
- 100% coverage but tests must be behavioral

### Finding 2: Instructure Canvas iOS (CLAUDE-unit-tests.md)
**URL**: https://github.com/instructure/canvas-ios/blob/master/CLAUDE-unit-tests.md

- "When creating NEW test files: DO NOT look for patterns in existing test files."
- Test naming: func test_subject_whenCondition_shouldExpectation()
- What NOT to test: compiler-generated conformances, private helpers, dependencies
- Constants: "Avoid 0 and 1; use meaningful values like 42 or 100."

### Finding 3: claude-flow Wiki (CLAUDE MD TDD)
**URL**: https://github.com/ruvnet/claude-flow/wiki/CLAUDE-MD-TDD

- Explicitly distinguishes behavioral (endorsed) vs structural (discouraged)
- Mutation testing with Stryker (80% minimum mutation score)
- Assertion density requirement: >=3 per test
- Speed constraint: Unit tests <1s total
- Given-When-Then + FIRST principles

### Finding 4: barisercan/cursorrules (TDD .mdc Rule for Cursor)
**URL**: https://github.com/barisercan/cursorrules/blob/main/test-driven-development.mdc

- Mandatory TDD: write tests BEFORE implementation
- Atomic steps with user verification gates
- Auto-test trigger on src/ file modification

### Finding 5: swingerman/atdd (Acceptance TDD Plugin) ★ NOTABLE
**URL**: https://github.com/swingerman/atdd

- Two parallel streams: acceptance tests (WHAT) + unit tests (HOW)
- **Spec Guardian agent** audits specs for implementation leakage
- Forbidden: class names, function names, database tables, API endpoints
- Good: "GIVEN there are no registered users. WHEN a user registers..."
- Bad: "GIVEN the UserService has an empty userRepository..."

### Finding 6-10: Less Notable
- minimaxir CLAUDE.md: Basic "write tests, mock externals" — no quality distinction
- OpenAI Codex AGENTS.md: "Prefer comparing entire objects over fields one by one"
- Copilot Instructions: Basic AAA pattern, one behavior per test
- sethdford/claude-skills: 5 anti-patterns including "testing private details"
- Anthropic Best Practices: Verification is "the single highest-leverage thing"

### Summary Matrix

| Source | Behavioral vs Structural | Test Bloat/Quality | TDD |
|--------|-------------------------|-------------------|-----|
| Sam Hatoum | Explicit litmus test | Strong | TCR |
| swingerman/atdd | Core purpose (2 streams) | Spec guardian + mutation | ATDD |
| claude-flow Wiki | Explicit (GWT) | Mutation + density | Yes |
| Canvas iOS | Implicit (public-only) | What-NOT-to-test list | No |
| obra/superpowers | 5 iron laws for AI tests | Strong | No |

---

## Research Thread 4: Test Review Prompts from Plugins

### Key Finding: No Major Tool Has Test Quality Review Built-In

| Tool | Test Quality Evaluation | Behavioral vs Structural |
|------|------------------------|-------------------------|
| Claude Code Review Plugin | None | None |
| Qodo PR-Agent | Binary "tests exist?" | None |
| Copilot Review | Basic checklist (AAA, naming) | None |
| CodeRabbit | Configurable path_instructions | None (customizable) |
| eslint-plugin-testing-library | 29 behavioral enforcement rules | Yes (React-specific) |

### Closest Approaches
1. **eslint-plugin-testing-library** — systematically enforces behavioral testing, but React-specific
2. **testdouble/test-smells "Invasion of Privacy"** — conceptual framework (tests private implementation details)
3. **Ruff PT008** — single rule on mock refactoring resilience
4. **testsmells.org "Sensitive Equality"** — detects toString()-based change detectors

### Notable Finding
~47% of Copilot-generated test cases contain at least one test smell (testsmells.org research).

---

## Research Thread 5: TDD Training Material

### Change Detector Tests
**Source**: Google Testing Blog, "Change-Detector Tests Considered Harmful" (2015)

Detection signals:
- Test breaks on refactoring that preserves behavior
- Test asserts method call order or internal delegation
- Test mirrors the implementation line-by-line

### Test Behavior, Not Implementation
**Source**: Google SWE Book Chapter 12 (Winters, Manshreck, Wright)

Five principles:
1. Strive for unchanging tests — only change when requirements change
2. Test via public APIs, not internal methods
3. Test state, not interactions (assert outputs, not mock call sequences)
4. Test behaviors, not methods
5. Make tests complete and concise (DAMP over DRY)

### Kent Beck on Test Quantity
"I get paid for code that works, not for tests, so my philosophy is to test as little as possible to reach a given level of confidence."

"If I don't typically make a kind of mistake (like setting the wrong variables in a constructor), I don't test for it."

### Martin Fowler on Too Much Testing
"The sign of too little testing is that you cannot confidently change your code. The sign of too much is spending more time changing tests than production code."

### Khorikov's Four Pillars (Unit Testing Principles, Manning 2020)
1. Protection against regressions — detects real bugs
2. **Resistance to refactoring** — no false positives when internals change (NON-NEGOTIABLE)
3. Fast feedback — executes quickly
4. Maintainability — easy to read

"The more the test is coupled to the implementation details of the SUT, the more false alarms it generates."

### Jay Fields on Test ROI
"Once a feature is complete it's often worth your time to examine the associated tests... any tests that were motivated solely by the development process should be considered for deletion."

### obra/superpowers 5 Iron Laws for AI-Written Tests
1. Never test mock behavior
2. Never add test-only methods to production classes
3. Never mock without understanding dependencies
4. Run test with real implementation FIRST, then add minimal mocking
5. Mock setup exceeding 50% of test code length = red flag

### Given/When/Then
Even without BDD frameworks, the GWT thinking pattern forces behavioral framing. If you cannot fill in the template without naming internal methods, you are testing implementation.

### When NOT to Write a Test

| Write a test when... | Skip when... |
|---|---|
| Code has conditional logic or branching | Trivial delegation with no logic |
| Bug would be hard to detect manually | Cost of test exceeds cost of bug |
| Code is at a public API boundary | Simple constructor/getter with no logic |
| Need confidence for future refactoring | Code is exploratory/prototype |
| Team tends to get this wrong (Beck) | You never make this kind of mistake |

---

## Research Thread 6: Research Papers on Test Effectiveness

### Coverage Is Not Strongly Correlated with Test Effectiveness
**Inozemtseva & Holmes, ICSE 2014 (ACM Distinguished Paper)**
- Coverage (statement, branch, modified condition) shows only low-to-moderate correlation with fault detection when controlling for suite size
- Validated across 5 large Java projects

### Mutation Testing Is a Better Proxy
**Just et al., FSE 2014**
- Statistically significant correlation between mutant detection and real fault detection, independent of coverage
- 357 real faults across 5 applications

**Petrovic et al., ICSE 2021 (Google)**
- 15 million mutants, 24,000 developers, 1,000+ projects
- Developers exposed to mutation testing write more tests over longer periods
- Mutants are empirically coupled with real faults

### LLMs Follow Implementation, Not Specification
**Di Grazia et al., ASE 2025** ★ CRITICAL FINDING
- LLMs generate assertions that confirm what code currently does, not what it should do
- ~25% of LLM-generated assertion oracles are false positives
- Naming conventions affect oracle quality by up to 16%

### Test Quality Drives Engineering Outcomes
**Athanasiou et al., IEEE TSE 2014**
- Test code quality has statistically significant positive correlation with issue handling throughput
- Teams with higher-quality tests fix bugs faster

### Test Smells Correlate with Defects
**Spadini et al. (2018-2021)**
- Tests with smells are more change-prone and defect-prone
- Production code tested by smelly tests is more defect-prone
- AI-generated tests susceptible to Assertion Roulette, Eager Test, Mystery Guest

### AI Over-Mocking
**Hora, "Are Coding Agents Generating Over-Mocked Tests?" (2025)**
- Coding agents generate more mocks than human developers
- Kent Beck: "LLMs make decisions seemingly at random, such as using mocks even though actual objects would be fine"

### Independent RED Test Writing Is Supported
Research supports the practice of having an independent agent write tests before implementation:
- Di Grazia (2025): LLMs follow implementation → independent writer can't do this because code doesn't exist yet
- Petrovic (2021): Independent test evaluation improves test quality
- The architectural separation (writer ≠ implementer) is a defense against tautological tests

---

## Synthesis

### Core Problem
Agents test **tasks** instead of **behavior**. "Rename X to Y" produces a test asserting X is gone, when the right test uses Y (fails until rename happens).

### Why Existing Guidance Fails
The RED test writer already has good rejection criteria, but:
1. Guidance exists in one agent but not others (fix-bug, sprint, review resolution)
2. The broader problem (bloated tests) encompasses more patterns than the one agent addresses
3. No enforcement mechanism catches tests that slip through

### Agreed Approach
1. **Shared 4-rule prompt** consumed by ALL test-writing paths (not just RED test writer)
2. **RED/GREEN/UPDATE classification** at implementation-plan level, with fix-bug integration
3. **Test quality review overlay** (opus) — catches bloat from any path
4. **Pre-commit gate** — configurable, language-specific tools + Semgrep fallback
5. **Promptfoo removal** — full cleanup including CI, docs, scripts, references
6. **Contract tests + referential integrity** — deterministic skill testing replacements
7. **Existing bloat cleanup** — triage and delete/replace

### Consolidated 4-Rule Prompt
1. **Before writing**: Is a new test needed, or should an existing test be updated? If existing tests cover this behavior, report "no new tests needed."
2. **What to test**: Frame as Given/When/Then — one test, one behavior. If you can't express it without naming internal methods, stop.
3. **How to test**: Execute the code under test and assert on observable outcomes. Never read source files in assertions. Mock only external boundaries, never internal collaborators.
4. **After writing**: Apply the refactoring litmus test — if extracting a helper method would break this test, rewrite it.

### Key Research-Backed Decisions
- Independent RED test writing is strongly supported (Di Grazia 2025, Petrovic 2021)
- Mutation testing as feedback signal is effective but out of scope for now
- Coverage is a weak proxy — don't optimize for it (Inozemtseva 2014)
- Test quality (not quantity) drives engineering outcomes (Athanasiou 2014)
- VCR/cassette pattern rejected — change detector at workflow level
- Docker E2E rejected — adds overhead without solving non-determinism
- Promptfoo/llm-rubric rejected — two layers of non-determinism, can't gate commits
