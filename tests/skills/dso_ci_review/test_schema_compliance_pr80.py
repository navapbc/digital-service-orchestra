"""Integration tests: PR-80 diff schema-compliance verification.

Testing mode: GREEN — exercises runner.py as a subprocess against the real PR-80 diff
fixture and asserts that the S-A + S-B + S-C changes produce zero parse_error findings
and 100% schema compliance on cited_excerpt and reachability fields.

These tests require a real ANTHROPIC_API_KEY and are skipped when the key is absent.
They are excluded from the normal unit test run via ``pytest -m "not integration"``.

Story 0ba6-2bc9-74b6-44aa (S-D): verification run against PR-80 diff fixture.
Bug d42d-8126: originally 8 of 11 findings were schema-invalid (missing cited_excerpt
or reachability). These tests verify the fix is durable.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
FIXTURE_DIFF_PR80 = REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus" / "pr-80.diff"

_SYNTHETIC_TYPES = frozenset({"specialist_error", "fallback_exhausted", "parse_error"})


def _run_runner_with_pr80(tmp_path: Path) -> dict:
    """Invoke dso_ci_review.runner as a subprocess with the PR-80 diff fixture.

    Returns the parsed findings JSON dict from the output file.

    Raises:
        pytest.skip: if ANTHROPIC_API_KEY is not set.
        AssertionError: if the runner exits non-zero or output is invalid JSON.
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        pytest.skip(
            "ANTHROPIC_API_KEY not set — skipping PR-80 schema-compliance integration test"
        )

    assert FIXTURE_DIFF_PR80.exists(), (
        f"PR-80 diff fixture not found at {FIXTURE_DIFF_PR80}. "
        "Run: gh pr diff 80 > tests/fixtures/ci-review-corpus/pr-80.diff"
    )

    output_file = tmp_path / "pr80_findings.json"

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(FIXTURE_DIFF_PR80),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "ANTHROPIC_API_KEY": api_key,
        "CI_REVIEW_PROVIDER": "anthropic",
        # Ensure a predictable, cost-bounded invocation
        "DSO_REVIEW_CYCLE": "1",
        "DSO_CI_REVIEW_DRY_RUN": "",
        "DSO_CI_REVIEW_REGION_SPLIT": "",
        "GITHUB_EVENT_NAME": "",
        "GITHUB_REF": "",
        "GITHUB_TOKEN": "",
        "PR_NUMBER": "",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/local/bin"),
    }

    _timeout_sec = int(os.environ.get("DSO_PR80_INTEGRATION_TIMEOUT_SEC", "1800"))
    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=_timeout_sec,
    )

    # Do NOT assert returncode == 0 here. runner.py exits non-zero when blocking
    # findings are present, which is a legitimate output state — real LLM calls
    # produce variable findings across runs, so the returncode is intrinsically
    # non-deterministic for an integration test that hits the live API
    # (bug f2bf-2b6c). The schema-compliance assertions below operate on the
    # written findings JSON, independent of runner exit code. We still require
    # the output file to exist so we can validate its schema; if the runner
    # crashed before writing, that is a real failure and the assertion below
    # surfaces it with the captured stdout/stderr for debugging.

    assert output_file.exists(), (
        f"runner.py did not write output file to {output_file} "
        f"(returncode={result.returncode}).\n"
        f"stdout: {result.stdout!r}\n"
        f"stderr: {result.stderr!r}"
    )

    return json.loads(output_file.read_text())


@pytest.fixture(scope="session")
def pr80_result(tmp_path_factory):
    """Session-scoped fixture: run the PR-80 integration once and share across tests.

    Skips the entire session if ANTHROPIC_API_KEY is absent, so individual tests
    don't need their own API-key guards. Uses tmp_path_factory (session-scoped)
    instead of tmp_path (function-scoped) to avoid fixture-scope conflicts.
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        pytest.skip(
            "ANTHROPIC_API_KEY not set — skipping PR-80 schema-compliance integration test"
        )
    tmp_path = tmp_path_factory.mktemp("pr80")
    return _run_runner_with_pr80(tmp_path)


@pytest.mark.integration
def test_pr80_zero_synthetic_schema_errors(pr80_result):
    """
    Given: PR-80 diff fixture at tests/fixtures/ci-review-corpus/pr-80.diff;
           ANTHROPIC_API_KEY set; S-A/S-B/S-C changes applied to runner.py
    When: runner.py is invoked as a subprocess with DSO_CI_REVIEW_DIFF_PATH=pr-80.diff
    Then: findings JSON contains zero entries with type="parse_error"

    Verifies that the schema-correction pipeline introduced in S-A/S-B/S-C eliminates
    synthetic parse_error findings that previously appeared when LLM output had missing
    cited_excerpt or reachability fields (bug d42d-8126).
    """
    findings = pr80_result.get("findings", [])

    parse_errors = [f for f in findings if f.get("type") == "parse_error"]
    assert len(parse_errors) == 0, (
        f"Expected zero parse_error findings; got {len(parse_errors)}:\n"
        + "\n".join(json.dumps(f, indent=2) for f in parse_errors)
    )


@pytest.mark.integration
def test_pr80_100_percent_schema_compliance(pr80_result):
    """
    Given: PR-80 diff fixture at tests/fixtures/ci-review-corpus/pr-80.diff;
           ANTHROPIC_API_KEY set; S-A/S-B/S-C changes applied to runner.py
    When: runner.py invoked as subprocess, real LLM call produces findings
    Then: (a) every non-synthetic finding has cited_excerpt with len >= 5 chars;
          (b) every finding with severity in {critical, important, fragile} has
              reachability with len >= 20 chars

    Non-synthetic = finding where type not in {specialist_error, fallback_exhausted,
    parse_error}. Verifies 100% schema compliance as required by story 0ba6-2bc9 (S-D).
    """
    findings = pr80_result.get("findings", [])

    non_synthetic = [f for f in findings if f.get("type") not in _SYNTHETIC_TYPES]

    # (a) cited_excerpt must be >= 5 non-whitespace chars (mirrors validator: strip() first)
    cited_violations = [
        f for f in non_synthetic if len(f.get("cited_excerpt", "").strip()) < 5
    ]
    assert len(cited_violations) == 0, (
        f"Expected 100% cited_excerpt compliance (len >= 5); "
        f"{len(cited_violations)} violation(s) found:\n"
        + "\n".join(
            f"  severity={f.get('severity')!r} cited_excerpt={f.get('cited_excerpt')!r} "
            f"description={f.get('description', '')[:80]!r}"
            for f in cited_violations
        )
    )

    # (b) reachability must be >= 20 chars for critical/important/fragile
    _REACHABILITY_SEVERITIES = {"critical", "important", "fragile"}
    reachability_required = [
        f for f in non_synthetic if f.get("severity") in _REACHABILITY_SEVERITIES
    ]
    reachability_violations = [
        f for f in reachability_required if len(f.get("reachability", "").strip()) < 20
    ]
    assert len(reachability_violations) == 0, (
        f"Expected 100% reachability compliance (len >= 20) for "
        f"critical/important/fragile findings; "
        f"{len(reachability_violations)} violation(s) found:\n"
        + "\n".join(
            f"  severity={f.get('severity')!r} reachability={f.get('reachability')!r} "
            f"description={f.get('description', '')[:80]!r}"
            for f in reachability_violations
        )
    )
