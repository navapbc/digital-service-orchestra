# Brainstorm Replay Test Harness

This directory contains the deterministic brainstorm replay test harness for the Digital Service Orchestra plugin.

## Approach

The harness uses a **recorded-transcript approach** — not live LLM invocation. Tests assert stable, deterministic outputs against known inputs without calling any LLM APIs.

- **Fixtures** (`fixtures/`) capture ticket-store state used as test inputs.
- **Golden-output helpers** (`helpers/`) provide assertion utilities for comparing outputs against expected values.
- **Test runners** (`test-*.sh`) are executable shell scripts that run individual test suites.

## Skipping LLM-Dependent Tests

Set `SKIP_LLM_REPLAY=1` to skip any tests that require live LLM invocation:

```bash
SKIP_LLM_REPLAY=1 bash tests/brainstorm/test-trivial-replay.sh
```

CI environments that lack LLM credentials should set this variable.

## Running Tests

```bash
# Run all harness tests
bash tests/brainstorm/test-trivial-replay.sh

# Skip LLM-dependent assertions
SKIP_LLM_REPLAY=1 bash tests/brainstorm/test-trivial-replay.sh
```
