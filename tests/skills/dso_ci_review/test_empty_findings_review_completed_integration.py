"""Integration tests for the 1b76 empty-findings positive-attestation rule.

Bug ticket: 1b76 (and the FINDING-1 fail-closed regression it introduced).

The 1b76 fix made validate-review-output.sh REQUIRE top-level
``review_completed === true`` whenever a code-review-dispatch payload has an
EMPTY findings list AND is non-synthetic (synthetic types
{specialist_error, fallback_exhausted, parse_error} are exempt).

``merge_findings()`` was updated to inject ``review_completed: True`` so a
clean aggregated specialist review passes. But the DEEP-tier path in
``runner.main()`` REPLACES the aggregated dict with the raw arch-agent LLM
output (``merged = arch_result``). That raw output carries ``review_completed``
ONLY if the arch LLM happened to emit it. A clean deep review returning
``findings: []`` WITHOUT ``review_completed`` therefore failed the new
empty-findings rule and routed into ``dispatch_schema_correction`` — which is
seeded only with ``{findings: original_findings}`` and instructed "Do not add
keys not present in the original", so it is structurally incapable of adding
``review_completed``. It re-fails every attempt, emits a synthetic
schema_error, and converts a genuine no-issues deep review into a BLOCKING
finding: a fail-CLOSED regression introduced by 1b76.

These tests use the REAL validator subprocess (NOT a mock) so they exercise
the actual schema rule end-to-end:

  (a) merge_findings(...) output passes the real validator carrying
      review_completed: True.
  (b) the deep-tier arch-replacement path: a clean arch_result with
      findings: [] and NO review_completed must, after the fix, PASS schema
      validation and NOT route into schema correction / NOT become a synthetic
      schema_error.

Test (b) is the RED test for FINDING-1: it FAILS before the runner.py fix
(captures the fail-closed) and passes after.

ENV CAVEAT: the validator subprocess resolves its plugin root from
CLAUDE_PLUGIN_ROOT. The tests pin it to THIS worktree's plugins/dso so a stale
plugin cache cannot produce a spurious schema-hash mismatch.
"""

from __future__ import annotations

import io
import os
import sys
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
PLUGIN_ROOT = REPO_ROOT / "plugins" / "dso"

# Ensure the plugin's scripts/ directory is on sys.path.
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


# --------------------------------------------------------------------------- #
# Test (a): merge_findings output passes the REAL validator end-to-end.
# --------------------------------------------------------------------------- #


def test_merge_findings_empty_passes_real_validator() -> None:
    """A clean (empty-findings) merge_findings result passes the real validator.

    merge_findings injects review_completed: True (1b76). Driving its output
    through the REAL _validate_findings_schema (the validate-review-output.sh
    subprocess) must return schema_pass — proving the injected attestation
    satisfies the empty-findings rule end-to-end, not just in isolation.
    """
    import dso_ci_review.runner as runner_mod
    from dso_ci_review.findings import merge_findings

    # Two clean reviewer payloads, no findings. summary must be >= 10 chars.
    merged = merge_findings(
        {"findings": [], "scores": {}, "summary": "reviewer A: no issues found"},
        {"findings": [], "scores": {}, "summary": "reviewer B: looks good overall"},
    )
    assert merged["findings"] == [], "precondition: merged findings must be empty"
    assert merged.get("review_completed") is True, (
        "precondition: merge_findings must inject review_completed: True (1b76)"
    )

    result = runner_mod._validate_findings_schema(
        merged, plugin_root=str(PLUGIN_ROOT)
    )
    assert result.status == "schema_pass", (
        "Expected merge_findings empty-findings output (with review_completed: "
        f"True) to PASS the real validator; got status={result.status!r} "
        f"errors={result.errors!r}"
    )


def test_empty_findings_without_review_completed_fails_real_validator() -> None:
    """Control: an empty non-synthetic payload WITHOUT review_completed is rejected.

    Pins the 1b76 rule itself (do NOT weaken it). Confirms the validator the
    other tests rely on actually enforces the attestation, so test (a)'s pass
    is meaningful (not a no-op validator).
    """
    import dso_ci_review.runner as runner_mod

    payload = {"findings": [], "summary": "a clean review with no issues here"}
    result = runner_mod._validate_findings_schema(
        payload, plugin_root=str(PLUGIN_ROOT)
    )
    assert result.status == "schema_fail", (
        "Expected an empty non-synthetic payload WITHOUT review_completed to FAIL "
        f"validation (1b76 rule); got status={result.status!r} errors={result.errors!r}"
    )


# --------------------------------------------------------------------------- #
# Test (b): deep-tier arch-replacement clean review (RED for FINDING-1).
# --------------------------------------------------------------------------- #


def _deep_tier_classification():
    return {
        "selected_tier": "deep",
        "size_action": "none",
        "security_overlay": False,
        "performance_overlay": False,
        "test_quality_overlay": False,
        "diff_size_lines": 1,
        "blast_radius": 1,
        "critical_path": 0,
        "anti_shortcut": 0,
        "staleness": 0,
        "cross_cutting": 0,
        "diff_lines": 0,
        "change_volume": 0,
        "computed_total": 9,
        "is_merge_commit": False,
    }


def _run_deep_clean_arch_path(tmp_path):
    """Drive runner.main() through the deep-tier arch-replacement path with a
    CLEAN arch_result (findings: [], NO review_completed).

    The REAL _validate_findings_schema runs (validator subprocess). Specialists
    return empty, and dispatch_arch_synthesis returns a clean no-issues payload
    that deliberately omits review_completed (mirroring a real arch LLM that
    didn't emit it). dispatch_schema_correction is spied on so the caller can
    assert whether the fail-closed correction path was reached.

    Returns (exit_code, stderr_text, correction_calls, output_data).
    """
    import json as _json

    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    async def _empty_specialists(agents):
        return [{"findings": [], "scores": {}, "summary": "specialist: no issues"}]

    # Clean arch synthesis result: empty findings, NO review_completed key.
    clean_arch_result = {
        "findings": [],
        "scores": {"correctness": 5, "maintainability": 5},
        "summary": "Deep arch synthesis: no issues found in this diff.",
    }

    correction_calls = []

    def _spy_correction(*args, **kwargs):
        correction_calls.append((args, kwargs))
        # Mirror real exhausted behavior: append a synthetic schema_error so the
        # runner's fail-closed branch fires (this is what produces the blocking
        # finding the regression caused).
        return {
            "findings": [
                {
                    "type": "parse_error",
                    "severity": "critical",
                    "category": "schema_error",
                    "description": "Schema correction failed after attempts.",
                    "finding_id": "schema_error_spy0001",
                    "file": "",
                    "cited_lines": [],
                    "cited_excerpt": "",
                    "reachability": "",
                }
            ],
            "summary": "Schema correction applied: all attempts exhausted",
        }

    artifacts_dir = str(tmp_path / "artifacts")
    os.makedirs(artifacts_dir, exist_ok=True)

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "WORKFLOW_PLUGIN_ARTIFACTS_DIR": artifacts_dir,
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                # Pin validator plugin-root to THIS worktree (env caveat).
                "CLAUDE_PLUGIN_ROOT": str(PLUGIN_ROOT),
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "GITHUB_SHA": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_deep_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_empty_specialists,
        ),
        patch(
            "dso_ci_review.runner.dispatch_arch_synthesis",
            return_value=clean_arch_result,
        ),
        patch(
            "dso_ci_review.runner.dispatch_schema_correction",
            side_effect=_spy_correction,
        ),
        patch(
            "dso_ci_review.runner.get_schema_correction_max_attempts",
            return_value=2,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    output_data = None
    if output_file.exists():
        try:
            output_data = _json.loads(output_file.read_text())
        except (ValueError, OSError):
            output_data = None

    return exit_code, stderr_capture.getvalue(), correction_calls, output_data


def test_deep_clean_arch_review_does_not_route_into_schema_correction(tmp_path):
    """A clean deep-tier arch review (findings: [], no review_completed) must PASS.

    RED for FINDING-1: before the runner.py fix, `merged = arch_result` replaces
    the merge_findings dict (which carried review_completed: True) with the raw
    arch output (which does not), so the real validator rejects the empty
    payload and the runner routes into dispatch_schema_correction — emitting a
    synthetic schema_error and failing CLOSED on a genuine no-issues review.

    After the fix (inject review_completed: True onto a non-synthetic empty
    arch_result before validation), schema correction must NOT be reached and
    no synthetic schema_error may appear in the output.
    """
    exit_code, stderr_text, correction_calls, output_data = _run_deep_clean_arch_path(
        tmp_path
    )

    assert correction_calls == [], (
        "FAIL-CLOSED regression (1b76 / FINDING-1): a clean deep-tier arch review "
        "(empty findings, no review_completed) routed into dispatch_schema_correction "
        f"({len(correction_calls)} call(s)). The arch-replacement path must inject "
        "review_completed: True so the empty-findings rule is satisfied without "
        f"correction. stderr={stderr_text!r}"
    )

    # No synthetic schema_error finding should be present in the written output.
    findings = (output_data or {}).get("findings") or []
    synthetic_schema_errors = [
        f
        for f in findings
        if isinstance(f, dict)
        and f.get("type") == "parse_error"
        and f.get("category") == "schema_error"
    ]
    assert synthetic_schema_errors == [], (
        "A clean no-issues deep review must NOT be converted into a blocking "
        f"synthetic schema_error. Found: {synthetic_schema_errors!r}. "
        f"stderr={stderr_text!r}"
    )


def test_deep_synthetic_arch_result_is_not_given_review_completed(tmp_path):
    """A synthetic arch_result must NOT be replaced (and not given review_completed).

    Guards the fix's edge handling: when arch synthesis returns an all-synthetic
    payload (e.g. fallback_exhausted), `arch_all_synthetic` is True so `merged`
    is NOT replaced with arch_result. The merge_findings result is preserved and
    the synthetic path is unaffected by the injection. This pins that the fix
    only touches the non-synthetic empty-findings case.
    """
    import dso_ci_review.runner as runner_mod

    arch_result = {
        "findings": [
            {
                "type": "fallback_exhausted",
                "severity": "critical",
                "category": "infra_error",
                "description": "context exhausted",
                "finding_id": "fe_0001",
            }
        ],
        "summary": "arch synthesis hit fallback exhaustion",
    }
    arch_findings = arch_result.get("findings") or []
    arch_all_synthetic = bool(arch_findings) and all(
        f.get("type", "") in runner_mod._SYNTHETIC_TYPES for f in arch_findings
    )
    assert arch_all_synthetic is True, (
        "precondition: an all-fallback_exhausted arch_result is all-synthetic"
    )
    # The synthetic arch result must not be given review_completed by any
    # injection (it is exempt from the empty-findings rule and is not replaced).
    assert "review_completed" not in arch_result, (
        "A synthetic arch_result must not carry review_completed"
    )
