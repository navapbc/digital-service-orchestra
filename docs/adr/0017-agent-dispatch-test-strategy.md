# Agent-Dispatch Test Strategy — Structural Proxy

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-05-21

Technical Story: e26d-b59d-5484-4e1f (under epic a03c-d55e-1393-4f27) — Synthetic
end-to-end LLM dispatch tests verify brainstorm routing and verifier
refused-closure behavior.

## Context and Problem Statement

Epic a03c-d55e-1393-4f27 SC7 and SC9 specify behavioral tests that exercise
`/dso:brainstorm` (skill dispatch) routing and `/dso:completion-verifier`
(agent dispatch) refused-closure behavior. Story e26d-b59d-5484-4e1f is the
implementation vehicle for those tests.

The challenge: `/dso:brainstorm` and `/dso:completion-verifier` are invoked as
**SKILL dispatches** — Claude reads the `SKILL.md` (or agent definition file)
and follows the prose instructions. They are not script-level API clients.
Three candidate test approaches all fail to cleanly test "Claude interpreting
a SKILL.md":

- **Recorded-fixture LLM dispatches** (cassette/JSONL replay; precedent:
  `tests/mocks/jira-cassette-loader.py`). Trade-off: tests the script-level
  API caller, not the SKILL dispatch itself. SKILL invocations do not go
  through a script that can be mocked.
- **Mocked HTTP** (stdlib HTTP server stubbing the Anthropic endpoint;
  precedent: `tests/mocks/github-api-server.py`). Same trade-off as recorded
  fixtures.
- **Structural proxy** — exercise the rules/contracts that drive the SKILL
  dispatch decision, plus the deterministic helpers that run inside the
  dispatch. Trade-off: does not catch the "rules say X but Claude does Y"
  failure mode.

The structural proxy is the only option whose precedent is already in the
codebase (`verifier-corpus-replay.sh` + `tests/fixtures/verifier-corpus/`).
The other two would require new infrastructure with no project-internal
precedent for SKILL-dispatch testing specifically.

A SC9 constraint also applies: SC7 and SC9 verify the behavior of routing
decisions and rejection messages that are defined by Claude's interpretation
of structured rules in the SKILL files. Testing the rules themselves at the
source-of-truth level is closer to what SC7/SC9 actually verify than a
recorded LLM call would be.

## Decision Drivers

- The tests must be deterministic and runnable in CI without an API key.
- Tests must not be change-detectors (must not break when non-load-bearing
  prose is reworded). Per the `behavioral-testing-standard.md`, assertions
  target load-bearing surfaces only: file paths, heading literals that are
  referenced by name from other files, and cross-file dependency edges.
- Tests must include a regression-detection guarantee (DD6) — proof that the
  tests would actually fail if the routing rule or refused-closure flow
  regressed.
- Tests must follow the existing `tests/scripts/test-*.sh` shell-suite pattern
  so they are discovered by `tests/scripts/run-script-tests.sh` and run as
  part of `validate.sh --ci`.

## Considered Options

- **Approach A: Structural proxy with load-bearing anchors + sentinel-fail tests.**
  Tests assert that load-bearing surfaces (file paths, heading literals,
  cross-file references) are present. Each anchor has a paired sentinel-fail
  test that mutates the source file to remove the anchor and asserts the
  anchor assertion now fails — proving the anchor is load-bearing.
- **Approach B: Hybrid — Approach A plus a manual smoke-test recipe
  (`scripts/closure-checks-e2e-smoke.sh`) that operators run periodically
  with real LLM dispatch.** Same CI behavior as Approach A; adds a
  non-deterministic manual fidelity check.
- **Approach C: Recorded-fixture LLM dispatches.** Capture Claude's actual
  brainstorm dispatch response for one fixture ticket; replay in CI.
- **Approach D: Mocked HTTP endpoint stub.** Stand up a localhost server
  that mimics the Anthropic API; the SKILL dispatch script calls localhost.

## Decision Outcome

Chosen option: **Approach A — structural proxy with load-bearing anchors +
sentinel-fail tests.**

The project-wide pattern for agent-dispatch testing is: assert on the
**load-bearing structural surfaces** that drive the dispatch decision, and
exercise the **deterministic helpers** that run inside the dispatch flow.
Sentinel-fail tests (DD6) prove each anchor is load-bearing by mutating the
source file and asserting the anchor assertion fails on the mutated copy.

This pattern applies to all future tests that verify SKILL or agent dispatch
behavior in this codebase. Specifically:

1. Identify the load-bearing surfaces (file paths, heading literals, schema
   field names, cross-file references) that the dispatch reads.
2. Write anchor tests that assert each surface is present.
3. For each anchor, write a paired sentinel-fail test that confirms removing
   the anchor causes the assertion to fail.
4. Where a deterministic helper script runs inside the dispatch flow
   (e.g., `check-verifier-verdict.sh`, `check-manifest-completeness.sh`),
   exercise it with synthetic inputs and assert its documented exit codes.

### Positive consequences

- No API key required; runs in CI deterministically.
- Tests break exactly when load-bearing surfaces change — not when prose is
  reworded.
- Sentinel-fail tests document the regression-detection guarantee mechanically.
- Existing pattern (precedent: `verifier-corpus-replay.sh` + corpus fixtures)
  is extended, not replaced.

### Negative consequences

- Does not catch the "rules say X but Claude does Y" failure mode. Mitigated
  in practice by frequent dev-lifecycle brainstorm dispatches surfacing live
  routing failures via the normal feedback loop.
- Test maintenance: heading literals that the tests anchor on must be
  preserved when documents are reorganized. The trade-off is intentional —
  these headings are referenced by name from other contract files, so they
  are already load-bearing.

## Live-dispatch fidelity check (deferred)

A future story may add an opt-in `scripts/closure-checks-e2e-smoke.sh` recipe
that operators run with `ANTHROPIC_API_KEY` set to exercise real
`/dso:brainstorm` and `/dso:completion-verifier` dispatches against fixture
tickets. This is NOT a CI-blocking gate — it is a manual fidelity check that
operators can run when they suspect a Claude-side routing regression that the
structural proxy missed. It is out of scope for e26d-b59d-5484-4e1f because
no current failure mode requires it.

## Cross-references

- Story: e26d-b59d-5484-4e1f
- Epic: a03c-d55e-1393-4f27 (Closure Checks schema migration; SC7, SC9)
- Tests: `tests/scripts/test-closure-checks-e26d-routing.sh`,
  `tests/scripts/test-closure-checks-e26d-verifier.sh`
- Pattern reference: `plugins/dso/skills/shared/prompts/behavioral-testing-standard.md`
