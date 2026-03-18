# Flaky Test Reporting — Digital Service Orchestra

> **When to read this file**: Before wiring flaky test detection into your CI pipeline. Covers the `report-flaky-tests.sh` script: what patterns it detects, how to call it, and the output it produces.

---

## Overview

`.claude/scripts/dso report-flaky-tests.sh` parses a JUnit XML test results
file and emits GitHub Actions warning annotations for any tests identified as
flaky. The script is **informational-only**: it always exits 0 regardless of
whether flaky tests are found, so it never blocks a CI job.

The script is implemented in pure bash with no external tool dependencies beyond
standard POSIX utilities (`wc`, `tr`).

---

## Detection Patterns

The script detects flakiness via four independent patterns. All four are checked
on every run; a test may match more than one pattern, but is only reported once.

### Pattern 1 — `<rerun>` element (pytest-rerunfailures)

**Trigger**: A `<testcase>` block contains a `<rerun>` child element and does
**not** contain a `<failure>` element.

The absence of `<failure>` alongside a `<rerun>` means the test ultimately
passed after one or more retries — the definition of a flaky test.

**Typical producer**: pytest with the `pytest-rerunfailures` plugin and
`--reruns N --junitxml=results.xml`.

**XML example**:

```xml
<testcase classname="tests.test_upload" name="test_upload_succeeds" time="0.12">
  <rerun message="AssertionError: expected 200, got 500" time="0.08">
    AssertionError: expected 200, got 500
  </rerun>
  <!-- No <failure> element — test passed on retry → flaky -->
</testcase>
```

---

### Pattern 2 — `<flakyFailure>` / `<flakyError>` elements (Maven Surefire)

**Trigger**: A `<testcase>` block contains a `<flakyFailure>` or `<flakyError>`
child element.

Maven Surefire uses these dedicated elements to distinguish flaky runs (failed
on first attempt but passed on retry) from deterministic failures.

**Typical producer**: Maven projects using the Surefire plugin with
`rerunFailingTestsCount > 0`.

**XML example**:

```xml
<testcase classname="com.example.UploadTest" name="testUploadSucceeds" time="0.25">
  <flakyFailure message="Expected 200 but was 500" type="java.lang.AssertionError">
    java.lang.AssertionError: Expected 200 but was 500
  </flakyFailure>
  <!-- Test ultimately passed → flakyFailure element is present → flaky -->
</testcase>
```

The `<flakyError>` variant is treated identically and covers non-assertion
errors (exceptions) that were retried and passed.

---

### Pattern 3 — `flaky="true"` attribute (Bazel)

**Trigger**: The `<testcase>` opening tag contains a `flaky="true"` attribute.

Bazel's test runner sets this attribute on any test that passed on at least one
attempt but failed on others within the same invocation, matching the
`--flaky_test_attempts` flag behaviour.

**Typical producer**: Bazel with `--flaky_test_attempts=N` and JUnit XML output.

**XML example**:

```xml
<testcase classname="//src:upload_test" name="test_upload_succeeds"
          time="0.30" flaky="true">
  <!-- flaky="true" attribute directly flags the test as flaky -->
</testcase>
```

---

### Pattern 4 — Duplicate testcase entries with mixed pass/fail (generic retry frameworks)

**Trigger**: The same `classname::name` key appears more than once in the XML
file — once with a `<failure>` child element and once without.

Some test frameworks (JUnit 4 runners, custom retry wrappers, certain Node.js
reporters) produce duplicate `<testcase>` entries when a test is retried: one
entry for each attempt. A test that failed on one attempt but passed on another
appears as a duplicate with mixed failure/pass state.

This is the most generic pattern and acts as a catch-all for frameworks that do
not use the dedicated elements above.

**Typical producer**: JUnit 4 with a retry rule, Node.js jest-circus with
retries enabled, or any framework that appends rather than replaces testcase
entries.

**XML example**:

```xml
<!-- First attempt: failed -->
<testcase classname="tests.test_upload" name="test_upload_succeeds" time="0.11">
  <failure message="AssertionError: expected 200, got 500">
    AssertionError: expected 200, got 500
  </failure>
</testcase>

<!-- Second attempt: passed (same classname + name, no <failure>) -->
<testcase classname="tests.test_upload" name="test_upload_succeeds" time="0.09">
</testcase>
```

---

## Usage

```bash
.claude/scripts/dso report-flaky-tests.sh <results-file.xml>
```

**Arguments**:

| Argument | Description |
|----------|-------------|
| `<results-file.xml>` | Path to the JUnit XML file produced by your test runner |

**Exit codes**:

| Code | Meaning |
|------|---------|
| `0` | Always — the script never exits non-zero (see Exit-0 Contract below) |
| `1` | Usage error only: called with no arguments |

**Standard output**:

- If no flaky tests are detected: `No flaky tests detected.`
- If flaky tests are detected:
  ```
  Found N flaky test(s):
    - classname::testname
    - ...
  ```
  Each flaky test also emits a `::warning::` GitHub Actions annotation on a
  separate line.

---

## Exit-0 Contract

The script always exits 0 when a valid (or missing) results file is provided.
This is an intentional, load-bearing contract:

- **Flaky tests are informational**, not failures. A flaky test passed on at
  least one attempt, so the test suite outcome is still valid.
- **CI jobs must not be blocked** by flakiness reporting. The script is a
  diagnostic overlay, not a quality gate.
- **GitHub Actions warnings** are surfaced in the PR/workflow summary UI without
  failing the workflow step.

If you want to enforce a zero-flaky-test policy, add a separate gate that counts
warning annotations or parses the script's stdout — do not rely on the exit code.

---

## Requirements

- **bash** >= 4.0 (associative arrays used for Pattern 4)
- No external tools required beyond standard POSIX utilities (`wc`, `tr`)
- The JUnit XML file must be readable and well-formed enough for line-by-line
  bash pattern matching (no strict XML parsing is performed)

---

## CI Integration Example

The following snippet shows how to add flaky test reporting to a GitHub Actions
workflow after a pytest step that produces JUnit XML output.

```yaml
# .github/workflows/ci.yml

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run tests
        run: |
          cd app
          poetry run pytest tests/unit/ \
            --reruns 1 --reruns-delay 0 \
            --junitxml=test-results.xml

      - name: Report flaky tests
        if: always()   # run even if the test step fails
        run: |
          .claude/scripts/dso report-flaky-tests.sh app/test-results.xml

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: app/test-results.xml
```

**Key points**:

- `if: always()` ensures the reporting step runs even when tests fail, so you
  see flakiness annotations on failing runs too.
- The script path assumes the plugin is installed at the repo root. Adjust the path if your layout differs.
- The `::warning::` annotations appear inline in the GitHub Actions step log and
  in the workflow summary. No additional configuration is required to surface
  them as PR annotations.

---

## Relationship to Project-Level Documentation

For project-specific context (how pytest-rerunfailures is configured in this
project's CI, how to run `make test-flaky-check` locally, and common flakiness
root causes), see `.claude/docs/FLAKY-TEST-INFRASTRUCTURE.md`.
