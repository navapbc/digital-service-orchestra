# Test Bloat Elimination — Brainstorm Session Log

**Date**: 2026-04-06
**Epic**: Eliminate Test Bloat: Behavioral Testing Standards, Quality Gate, and Cleanup
**Related epics**: dso-4s8r (Cleanup tests), a978-bf1c (Migrate skill evals to 3-tier testing pyramid), e677-34da (Docker-based E2E Workflow Tests)

---

## Problem Statement (User)

We have a problem with test quality. Tests don't meaningfully protect us from regression or validate the behavior we're building:
- Tests that check to make sure the old class doesn't exist after renaming
- Tests that break because code is refactored despite there being no behavioral changes
- An ever increasing number of tests that increase maintenance burden and test run time without delivering value

Three parts to this epic:
1. Maintain a TDD approach without adding test bloat by updating agent prompts that write tests
2. Add better validation to guard against test bloat without adding too much friction to commit
3. Clean up bloated tests currently in the project

Tests are primarily written by: RED test writer agent, fix-bug skill, implementation agents in sprint, and code review resolution loop.

---

## Initial Codebase Exploration

### Test Suite State
- **583 total test files** across shell and Python
- 289 in tests/scripts/, 123 in tests/hooks/, 104 in tests/skills/, 9 in tests/agents/
- ~40+ tests in tests/skills/ and tests/agents/ are pure change-detection

### Bloat Examples Identified (deleted in Epic 902a-393b)
1. `test_fix_bug_skill.py` (1,368 lines) — 20+ tests all grepping SKILL.md for string presence
2. `test_brainstorm_gap_analysis.py` (197 lines) — fuzzy phrase matching on markdown
3. `test-reviewer-dimension-names.sh` (50 lines) — grepping agent .md for quoted dimension names
4. `test-reviewer-light-checklist.sh` (193 lines) — 15+ section heading presence checks
5. `test_fix_cascade_recovery_handoff.py` (116 lines) — command string pattern matching

### RED Test Writer Already Has Rejection Criteria
The RED test writer agent prompt (red-test-writer.md) already explicitly rejects these patterns:
- "Reads source file contents via cat/grep/awk and asserts on string patterns" → REJECTED
- "Checks file existence or file structure without executing the code" → REJECTED
- "Asserts on internal variable names, function signatures, or code structure" → REJECTED

The guidance exists in one agent but not others. The bloated tests exist despite the guidance.

---

## Related Epics Analysis

- **dso-4s8r** ("Cleanup tests") — empty placeholder, no description
- **a978-bf1c** ("Migrate skill evals to 3-tier testing pyramid") — proposes replacing llm-rubric with grep-based structural tests as Tier 1 — exactly the bloat pattern we're trying to eliminate. Its premise is flawed.
- **e677-34da** ("Docker-based E2E Workflow Tests") — empty placeholder for Docker-based skill tests
- **c13f-6196** ("Test gate observability") — addresses test gate visibility but not root cause

---

## Key User Clarifications

### On eval infrastructure
"The eval system should likely be scrapped as too flaky to be useful. We need gating mechanisms to prevent regression, not signals that can be ignored."

### On scope
"While this project is skills-focused, most host projects of this plugin will not be. Skills are one facet of test bloat and may require a specific solution, but our scope also includes language-agnostic mechanisms to prevent test bloat."

### On the root cause
"Agents are told to practice TDD and they do it by producing a test for the rename task instead of a test for the desired outcome of a functional behavior using the new name. The right outcome is probably updating tests to use the new name (making them RED until the rename task is complete) rather than creating a new test that is only useful during the migration itself."

### On the OpenAI approach vs our L2/L3
OpenAI captures JSONL execution traces (which tools called, what args, what order) and writes deterministic assertions against those events. Our L2/L3 was purely static analysis. The key difference: OpenAI tests what the system actually did at runtime.

### On VCR/cassette pattern
"Rejected because any change to the skill invalidates the test. That's essentially a change detector test, not a regression test."

### On Docker E2E
Critically evaluated: Docker E2E adds infrastructure overhead without solving LLM non-determinism; if you mock the LLM, it collapses to script testing with Docker overhead.

### On the prompt strategy
User wanted us to refine the prompt strategy together, not jump ahead. Requested research on:
1. Test writing prompts used by popular plugin projects on GitHub
2. Test review prompts used by popular plugins on GitHub
3. TDD training material on meaningful tests vs anti-patterns
4. Research papers on what makes a good automated test

### On configuration
"Add a config value for language-specific test bloat detection tools, with fallback to semgrep. Semgrep should be listed as a dependency. Onboarding should install semgrep and configure language-specific tools."

### On the RED/GREEN/UPDATE testing model
"The problem may be that the tests aren't RED when the test writer examines them. Sometimes a successful outcome is 'behavior doesn't change and everything still passes.' Do we need to shift this up the pipeline and have implementation-plan make a judgement call on whether a given task requires RED testing (it involves a change in behavior) or whether it only requires GREEN testing (it involves changes to implementation without changing behavior)?"

### On fix-bug integration
"Implementation-plan is building new functionality, and commonly has behavioral testing requirements. Fix-bug is resolving an issue, not changing the intended behavior. Fix-bug will frequently need to write implementation-based tests in order to experimentally validate its root cause hypothesis. These tests must be allowed, but should be marked as scaffolding so they can be removed later."

### On test quality review overlay
"What if we shift test review to be a review overlay like security or performance? The overlay could use opus. Changes to test files is a clear signal to activate the overlay."

### On the consolidated prompt
User requested rolling original principles 5 (mock only external boundaries) and 6 (one test, one behavior) into the "how to test" rule. Added back "never read source files in assertions" which was lost. Final 4-rule prompt agreed.

### On RED test evaluation
"Do we also need to update the RED test reviewer?" — Yes, the dso:red-test-evaluator needs parallel update.

### On independent RED test writing
"Is our practice of having an independent agent write RED tests before implementation supported by research?" — Strongly supported by Di Grazia et al. (ASE 2025) finding that LLMs follow actual implementation rather than expected behavior. Independent RED writer can't do this because the code doesn't exist yet.

---

## Approaches Considered

### Option A: Test Quality Gate + Agent Prompt Reform (Selected, Refined)
- Shared behavioral testing standard as prompt fragment
- Test quality review overlay (opus)
- Pre-commit gate with language-specific tools + Semgrep fallback
- Cleanup existing bloat
- Scrap eval infrastructure

### Option B: Review-Layer Enforcement Only (Rejected)
- Relies on reviewer quality — same models that wrote bloated tests would review them
- No protection against bloat from resolution loop

### Option C: Test Lifecycle Management (Elements Incorporated)
- Scaffolding test tagging incorporated into fix-bug integration
- Test observability deferred to separate epic (c13f-6196)

---

## Final Approved Spec

### Success Criteria (13)
1. Shared 4-rule behavioral testing standard consumed by all test-writing paths
2. Implementation-plan RED/GREEN/UPDATE testing mode classification
3. Sprint orchestrator consumes testing_mode field
4. RED test writer "no new tests needed" exit path
5. Fix-bug RED/GREEN/UPDATE integration with scaffolding test support
6. Test quality review overlay (opus, triggered by test file changes)
7. Sprint-level test review removed (replaced by overlay, coordinated deployment)
8. Configurable pre-commit gate (language-specific tools + Semgrep fallback, avoid false positives)
9. Semgrep dependency + onboarding with graceful degradation
10. RED test evaluator alignment
11. Existing bloat cleanup
12. Eval infrastructure removal (configs, runner, CI, commit guard, docs, dependency, references)
13. Contract tests + referential integrity linting for skill testing

### Scenario Analysis (9 surviving)
- 2 critical: concurrent overlay/sprint-review conflict, eval infrastructure migration
- 3 high: Semgrep install failure, scaffolding marker blocking, sprint orchestrator not consuming mode
- 4 medium: referential integrity cascade, marker cleanup, timeout ceiling, eval remnants
