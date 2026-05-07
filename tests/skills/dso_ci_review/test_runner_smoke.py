"""
Smoke test for dso_ci_review.runner module.

Tests the subprocess invocation path end-to-end using dry-run mode and
the get_provider() routing path (ConfigError / AuthError exits).
Also verifies the atomic write behavior (DD3): output is written via temp+rename,
so no partial file is observable to concurrent parsers.

Pipeline tests mock classify_tier() and async_dispatch_specialists() to exercise
the full classify → dispatch → merge → output flow without real LLM calls.
"""

import json
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus"


def test_runner_produces_findings_json(fixture_diff_path, tmp_path):
    """
    Given: a fixture diff file and DSO_CI_REVIEW_OUTPUT_PATH set to a temp file
    When: dso_ci_review.runner is invoked as a subprocess in dry-run mode
    Then: exit code is 0, output file exists and contains valid JSON with a 'findings' list
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(fixture_diff_path.read_text())
    output_file = tmp_path / "findings.json"

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "DSO_CI_REVIEW_DRY_RUN": "1",
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }

    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )

    assert result.returncode == 0, (
        f"runner exited {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )

    # DSO_CI_REVIEW_OUTPUT_PATH was set — runner MUST write to the file, not stdout
    assert output_file.exists(), (
        f"output file not written to {output_file}. stdout={result.stdout!r}"
    )

    parsed = json.loads(output_file.read_text())
    assert "findings" in parsed, f"'findings' key missing from output: {parsed}"
    assert isinstance(parsed["findings"], list), (
        f"'findings' must be a list, got {type(parsed['findings'])}"
    )


def test_runner_writes_atomically(fixture_diff_path, tmp_path):
    """
    Given: DSO_CI_REVIEW_OUTPUT_PATH set to a file in a temp directory
    When: dso_ci_review.runner completes successfully in dry-run mode
    Then: no .tmp file remains in the output directory (temp+rename was used atomically)
         AND the output file contains valid JSON (not a partial write)

    This test verifies DD3: atomic write via temp file + os.replace() so that parsers
    never observe a partially-written file.
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(fixture_diff_path.read_text())
    output_file = tmp_path / "findings.json"

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "DSO_CI_REVIEW_DRY_RUN": "1",
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }

    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )

    assert result.returncode == 0, (
        f"runner exited {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )

    # No .tmp files should remain — temp file was renamed to final path
    leftover_tmp = list(tmp_path.glob("*.tmp"))
    assert leftover_tmp == [], (
        f"Leftover .tmp files found after atomic write: {leftover_tmp}. "
        "os.replace() must remove the temp file by renaming it to the final path."
    )

    # Output file must be fully valid JSON (not truncated / partially written)
    assert output_file.exists(), f"output file not written to {output_file}"
    content = output_file.read_text()
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        raise AssertionError(
            f"Output file is not valid JSON — partial write suspected: {exc}\n"
            f"Content: {content!r}"
        ) from exc
    assert "findings" in parsed, f"'findings' key missing from output: {parsed}"


def test_runner_output_goes_to_file_not_stdout(fixture_diff_path, tmp_path):
    """
    Given: DSO_CI_REVIEW_OUTPUT_PATH is set
    When: dso_ci_review.runner completes in dry-run mode
    Then: stdout is empty (output written to file, not stdout)

    Verifies that the atomic-write path does not accidentally duplicate output to stdout.
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(fixture_diff_path.read_text())
    output_file = tmp_path / "findings.json"

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "DSO_CI_REVIEW_DRY_RUN": "1",
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }

    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "", (
        f"stdout should be empty when DSO_CI_REVIEW_OUTPUT_PATH is set, "
        f"got: {result.stdout!r}"
    )


def test_runner_config_error_exits_1(fixture_diff_path, tmp_path):
    """
    Given: no CI_REVIEW_PROVIDER configured and no DSO_CI_REVIEW_DRY_RUN
    When: dso_ci_review.runner is invoked with a non-empty diff
    Then: exit code is 1 and stderr contains ERROR: provider auth: (defaulting to anthropic, API key absent)
    (verifies get_provider() ConfigError path is reached, not hardcoded anthropic import)
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(fixture_diff_path.read_text())

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        # No CI_REVIEW_PROVIDER, no DSO_CI_REVIEW_DRY_RUN
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }

    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )

    assert result.returncode == 1, (
        f"Expected exit code 1 (ConfigError), got {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )
    assert "ERROR: provider" in result.stderr, (
        f"Expected 'ERROR: provider ...' in stderr, got: {result.stderr!r}"
    )


def test_runner_auth_error_exits_1(fixture_diff_path, tmp_path):
    """
    Given: CI_REVIEW_PROVIDER=anthropic but ANTHROPIC_API_KEY absent
    When: dso_ci_review.runner is invoked with a non-empty diff
    Then: exit code is 1 and stderr contains 'ERROR: provider auth:'
    (verifies get_provider() AuthError path is reached)
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(fixture_diff_path.read_text())

    env = {
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "CI_REVIEW_PROVIDER": "anthropic",
        # ANTHROPIC_API_KEY deliberately absent
        "PATH": "/usr/bin:/bin:/usr/local/bin",
    }

    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )

    assert result.returncode == 1, (
        f"Expected exit code 1 (AuthError), got {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )
    assert "ERROR: provider auth:" in result.stderr, (
        f"Expected 'ERROR: provider auth:' in stderr, got: {result.stderr!r}"
    )


# ---------------------------------------------------------------------------
# Pipeline tests — mock classify_tier and async_dispatch_specialists
# ---------------------------------------------------------------------------

import sys as _sys  # noqa: E402 — import used for PYTHONPATH manipulation in module scope

_sys.path.insert(0, str(SCRIPTS_DIR))


def test_runner_pipeline_standard_tier(tmp_path):
    """
    Given: a non-empty diff and mocked classify_tier (standard) + async_dispatch_specialists
    When: runner.main() is called in-process
    Then: classify_tier is called once, async_dispatch_specialists is called with 1 agent,
          merge_findings merges the results, and _write_output emits the merged dict.

    Exit code: this test fixture returns an "important" severity finding from the standard
    reviewer, so the severity gate (bug f2c7-257e) correctly blocks with exit 1. The
    pipeline-shape assertions below (classify called once, 1 agent dispatched, output
    written, JSON shape) remain the intent of this test; the exit code is incidental.
    """

    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/foo.py b/foo.py\n+added line\n"
    output_file = tmp_path / "findings.json"

    tier_result = {
        "selected_tier": "standard",
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
        "computed_total": 1,
        "is_merge_commit": False,
    }
    specialist_findings = [
        {
            "findings": [
                {
                    "severity": "important",
                    "description": "test finding",
                    "cited_lines": ["foo.py:1"],
                }
            ],
            "scores": {"correctness": 3},
            "summary": "one issue",
        }
    ]

    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)

    captured_agents: list = []

    async def mock_dispatch(agents):
        captured_agents.extend(agents)
        return specialist_findings

    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
            },
        ),
        patch(
            "dso_ci_review.runner.classify_tier", return_value=tier_result
        ) as mock_classify,
        patch(
            "dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch
        ),
    ):
        exit_code = runner_mod.main()

    # Severity gate (bug f2c7-257e): the fixture returns an "important" finding,
    # so exit 1 is the correct outcome — the pipeline ran end-to-end and the
    # gate correctly identified the blocking severity.
    assert exit_code == 1, (
        f"Expected exit code 1 (important finding blocks), got {exit_code}"
    )
    mock_classify.assert_called_once_with(diff_text)

    # 1 agent for standard tier
    assert len(captured_agents) == 1
    assert captured_agents[0]["agent_id"] == "code-reviewer-standard"

    parsed = json.loads(output_file.read_text())
    assert "findings" in parsed
    assert len(parsed["findings"]) == 1
    assert parsed["findings"][0]["severity"] == "important"


def test_runner_pipeline_deep_tier_dispatches_three_agents(tmp_path):
    """
    Given: classify_tier returns 'deep' tier
    When: runner.main() is called in-process
    Then: async_dispatch_specialists is called with exactly 3 agents
         (correctness, verification, hygiene) and findings are merged.
    """
    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/auth/login.py b/auth/login.py\n+token = secret\n" * 10

    tier_result = {
        "selected_tier": "deep",
        "size_action": "none",
        "security_overlay": True,
        "performance_overlay": False,
        "test_quality_overlay": False,
        "diff_size_lines": 10,
        "blast_radius": 1,
        "critical_path": 3,
        "anti_shortcut": 0,
        "staleness": 0,
        "cross_cutting": 0,
        "diff_lines": 1,
        "change_volume": 0,
        "computed_total": 7,
        "is_merge_commit": False,
    }

    correctness_findings = {
        "findings": [
            {
                "severity": "critical",
                "description": "auth flaw",
                "cited_lines": ["auth/login.py:1"],
            }
        ],
        "scores": {"correctness": 1},
        "summary": "auth issue",
    }
    verification_findings = {
        "findings": [],
        "scores": {"verification": 3},
        "summary": "ok",
    }
    hygiene_findings = {
        "findings": [
            {
                "severity": "important",
                "description": "style",
                "cited_lines": ["auth/login.py:2"],
            }
        ],
        "scores": {"hygiene": 2},
        "summary": "style",
    }

    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "findings.json"

    captured_agents: list = []

    async def mock_dispatch(agents):
        captured_agents.extend(agents)
        return [correctness_findings, verification_findings, hygiene_findings]

    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
            },
        ),
        patch("dso_ci_review.runner.classify_tier", return_value=tier_result),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch
        ),
    ):
        exit_code = runner_mod.main()

    # Severity gate (bug f2c7-257e): fixture returns critical + important findings,
    # so exit 1 is correct. Pipeline-shape assertions below remain the test's intent.
    assert exit_code == 1, (
        f"Expected exit code 1 (critical + important block), got {exit_code}"
    )

    # 3 agents dispatched for deep tier
    assert len(captured_agents) == 3
    agent_ids = {a["agent_id"] for a in captured_agents}
    assert agent_ids == {
        "code-reviewer-deep-correctness",
        "code-reviewer-deep-verification",
        "code-reviewer-deep-hygiene",
    }

    parsed = json.loads(output_file.read_text())
    assert "findings" in parsed
    # Merged: correctness (1) + verification (0) + hygiene (1) = 2 findings
    assert len(parsed["findings"]) == 2
    # Scores are min-merged
    assert parsed["scores"]["correctness"] == 1
    assert parsed["scores"]["verification"] == 3
    assert parsed["scores"]["hygiene"] == 2


def test_runner_exits_1_when_all_specialists_fail(tmp_path):
    """
    Given: all specialists return specialist_error findings (e.g. ModuleNotFoundError)
    When: runner.main() is called in-process
    Then: exit code is 1 and stderr contains a message about specialist failure

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_exits_1_when_all_specialists_fail]

    Covers fcea-6e83: runner exits 0 (PASS) even when every specialist dispatch fails,
    allowing a silently no-op'd review job to satisfy the required-status check.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/foo.py b/foo.py\n+added line\n"
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "findings.json"

    tier_result = {
        "selected_tier": "standard",
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
        "computed_total": 1,
        "is_merge_commit": False,
    }

    # All specialists fail — simulates ModuleNotFoundError: No module named 'litellm'
    all_error_findings = [
        {
            "findings": [
                {
                    "type": "specialist_error",
                    "agent_id": "code-reviewer-standard",
                    "severity": "important",
                    "category": "correctness",
                    "description": (
                        "Specialist code-reviewer-standard failed: "
                        "ModuleNotFoundError: No module named 'litellm'"
                    ),
                    "cited_lines": [],
                }
            ]
        }
    ]

    async def mock_dispatch(agents):
        return all_error_findings

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
            },
        ),
        patch("dso_ci_review.runner.classify_tier", return_value=tier_result),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 1, (
        f"Expected exit code 1 when all specialists fail, got {exit_code}. "
        "runner.main() must detect all-specialist-error and return 1 "
        "(fcea-6e83: silent exit-0 lets broken review satisfy required-status check)."
    )
    stderr_text = stderr_capture.getvalue()
    assert "specialist" in stderr_text.lower(), (
        f"Expected a message about specialist failures in stderr, got: {stderr_text!r}"
    )


# ---------------------------------------------------------------------------
# Tier model config tests — Fix C (c86e-e177)
# ---------------------------------------------------------------------------


def test_build_agents_for_tier_reads_standard_model_from_config(tmp_path):
    """
    Given: dso-config.conf sets model.standard=claude-sonnet-4-6
    When: _build_agents_for_tier("standard", ...) is called with that config path
    Then: the agent model is claude-sonnet-4-6, not the haiku default

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_build_agents_for_tier_reads_standard_model_from_config]

    Covers c86e-e177 Fix C: tier-appropriate models read from dso config, matching
    local review tiers (haiku=light, sonnet=standard/deep). Not hardcoded.
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "model.light=claude-haiku-4-5-20251001\n"
        "model.standard=claude-sonnet-4-6\n"
        "model.deep=claude-opus-4-6\n"
    )

    agents = runner_mod._build_agents_for_tier(
        "standard", "diff text", {}, config_path=str(config_file)
    )
    assert len(agents) == 1
    assert agents[0]["model"] == "claude-sonnet-4-6", (
        f"standard tier should use claude-sonnet-4-6 from config; "
        f"got {agents[0]['model']!r}. _build_agents_for_tier must accept config_path "
        f"and read model.standard from it (c86e-e177 Fix C)."
    )


def test_build_agents_for_tier_reads_light_model_from_config(tmp_path):
    """
    Given: dso-config.conf sets model.light=claude-haiku-4-5-20251001
    When: _build_agents_for_tier("light", ...) is called with that config path
    Then: the agent model is claude-haiku-4-5-20251001

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_build_agents_for_tier_reads_light_model_from_config]
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "model.light=claude-haiku-4-5-20251001\n"
        "model.standard=claude-sonnet-4-6\n"
        "model.deep=claude-opus-4-6\n"
    )

    agents = runner_mod._build_agents_for_tier(
        "light", "diff text", {}, config_path=str(config_file)
    )
    assert len(agents) == 1
    assert agents[0]["model"] == "claude-haiku-4-5-20251001"


def test_build_agents_for_tier_reads_deep_model_from_config(tmp_path):
    """
    Given: dso-config.conf sets model.deep=claude-opus-4-6
    When: _build_agents_for_tier("deep", ...) is called with that config path
    Then: all three deep agents use claude-opus-4-6

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_build_agents_for_tier_reads_deep_model_from_config]
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "model.light=claude-haiku-4-5-20251001\n"
        "model.standard=claude-sonnet-4-6\n"
        "model.deep=claude-opus-4-6\n"
    )

    agents = runner_mod._build_agents_for_tier(
        "deep", "diff text", {}, config_path=str(config_file)
    )
    assert len(agents) == 3
    for agent in agents:
        assert agent["model"] == "claude-opus-4-6", (
            f"deep tier agent {agent['agent_id']!r} should use claude-opus-4-6; "
            f"got {agent['model']!r}"
        )


def test_build_agents_for_tier_falls_back_to_tier_defaults_when_config_absent(tmp_path):
    """
    Given: a config file that does NOT set model.standard
    When: _build_agents_for_tier("standard", ...) is called with that config path
    Then: the agent uses the hardcoded tier default for standard (sonnet), not haiku

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_build_agents_for_tier_falls_back_to_tier_defaults_when_config_absent]

    Covers c86e-e177 Fix C: even without config, standard tier should default to
    sonnet (not haiku) to match local review tier defaults.
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("# no model.standard key\n")

    agents = runner_mod._build_agents_for_tier(
        "standard", "diff text", {}, config_path=str(config_file)
    )
    assert len(agents) == 1
    # Standard tier default must be sonnet, not haiku
    assert agents[0]["model"] != "claude-haiku-4-5-20251001", (
        f"standard tier default should NOT be haiku; "
        f"got {agents[0]['model']!r}. Standard tier must default to sonnet "
        f"to match local review tiers (c86e-e177 Fix C)."
    )


def test_runner_warns_on_all_synthetic_findings(tmp_path, capsys):
    """
    Given: all findings are synthetic (fallback_exhausted type)
    When: runner.main() completes
    Then: exit code is 0 (fail-open) and stderr contains WARNING about synthetic findings

    Covers e840-327f: runner silently succeeds with all-synthetic findings,
    giving no signal to operators that review content is missing.
    """
    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/foo.py b/foo.py\n+added line\n"
    output_file = tmp_path / "findings.json"
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)

    tier_result = {
        "selected_tier": "light",
        "size_action": "none",
        "security_overlay": False,
        "performance_overlay": False,
        "test_quality_overlay": False,
        "diff_size_lines": 1,
        "blast_radius": 0,
        "critical_path": 0,
        "anti_shortcut": 0,
        "staleness": 0,
        "cross_cutting": 0,
        "diff_lines": 0,
        "change_volume": 0,
        "computed_total": 0,
        "is_merge_commit": False,
    }
    synthetic_findings = [
        {
            "findings": [
                {
                    "type": "fallback_exhausted",
                    "severity": "informational",
                    "category": "error",
                    "description": "LLM returned unparseable prose",
                    "cited_lines": ["foo.py:1"],
                }
            ],
            "scores": {},
            "summary": "Review inconclusive: all findings are synthetic.",
        }
    ]

    async def mock_dispatch(agents):
        return synthetic_findings

    import io
    import contextlib

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
            },
        ),
        patch("dso_ci_review.runner.classify_tier", return_value=tier_result),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch
        ),
        contextlib.redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 0, (
        f"Expected exit code 0 (fail-open for fallback_exhausted), got {exit_code}. "
        f"stderr: {stderr_capture.getvalue()!r}"
    )
    stderr_text = stderr_capture.getvalue()
    assert "WARNING" in stderr_text and "synthetic" in stderr_text.lower(), (
        f"Expected WARNING about synthetic findings in stderr, got: {stderr_text!r}"
    )


# ---------------------------------------------------------------------------
# Severity gate + PR comment posting tests — bug f2c7-257e
# ---------------------------------------------------------------------------
#
# Bug: ci-llm-review-runner.sh returned 4 important + 2 fragile findings on
# PR #62 yet the job exited 0 and posted no PR comments. enforcement.strategy=ci
# became silently non-enforcing.
#
# RED markers:
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_exits_1_on_important_finding]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_exits_1_on_fragile_finding]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_exits_1_on_critical_finding]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_exits_0_on_minor_only]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_exits_0_on_no_findings]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_skips_blocking_for_specialist_errors]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_posts_pr_review_when_findings]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_skips_pr_post_on_push_event]


def _make_findings_dispatch(findings_list):
    """Build a mock async_dispatch_specialists return value from a list of findings dicts."""

    async def _mock(agents):
        return [{"findings": findings_list}]

    return _mock


def _standard_tier_classification():
    return {
        "selected_tier": "standard",
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
        "computed_total": 1,
        "is_merge_commit": False,
    }


def _run_main_with(diff_path, output_path, dispatch_findings, env_extra=None):
    """Run runner.main() with a mocked dispatch returning the given findings.

    Returns (exit_code, stderr_text).
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    env = {
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_path),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_path),
        "CI_REVIEW_PROVIDER": "anthropic",
        "ANTHROPIC_API_KEY": "test-key",
        # Suppress real GitHub Actions env that would otherwise leak in via
        # patch.dict(clear=False) and trigger an unintended `gh pr comment`
        # subprocess call when these tests run inside a CI job. Tests that
        # need the PR-event path opt in via env_extra below.
        "GITHUB_EVENT_NAME": "",
        "GITHUB_REF": "",
        "GITHUB_TOKEN": "",
        "PR_NUMBER": "",
    }
    if env_extra:
        env.update(env_extra)

    stderr_capture = io.StringIO()
    with (
        patch.dict("os.environ", env, clear=False),
        patch(
            "dso_ci_review.runner.classify_tier",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_make_findings_dispatch(dispatch_findings),
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()
    return exit_code, stderr_capture.getvalue()


def test_runner_exits_1_on_important_finding(tmp_path):
    """Important findings MUST block — exit 1, matching local record-review.sh enforcement."""
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    findings = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "real issue",
            "cited_lines": ["foo:1"],
        }
    ]
    exit_code, stderr = _run_main_with(diff_file, out, findings)
    assert exit_code == 1, (
        f"important finding must block (exit 1); got {exit_code}. stderr={stderr!r}"
    )


def test_runner_exits_1_on_fragile_finding(tmp_path):
    """Fragile is treated as important per CLAUDE.md rule 11 / reviewer-base.md."""
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    findings = [
        {
            "severity": "fragile",
            "category": "correctness",
            "description": "unverifiable ref",
            "cited_lines": ["foo:1"],
        }
    ]
    exit_code, stderr = _run_main_with(diff_file, out, findings)
    assert exit_code == 1, (
        f"fragile finding must block (exit 1); got {exit_code}. stderr={stderr!r}"
    )


def test_runner_exits_1_on_critical_finding(tmp_path):
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    findings = [
        {
            "severity": "critical",
            "category": "correctness",
            "description": "must fix",
            "cited_lines": ["foo:1"],
        }
    ]
    exit_code, stderr = _run_main_with(diff_file, out, findings)
    assert exit_code == 1, (
        f"critical finding must block; got {exit_code}. stderr={stderr!r}"
    )


def test_runner_exits_0_on_minor_only(tmp_path):
    """Minor findings alone should NOT block — match local reviewer behavior."""
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    findings = [
        {
            "severity": "minor",
            "category": "hygiene",
            "description": "nit",
            "cited_lines": ["foo:1"],
        }
    ]
    exit_code, stderr = _run_main_with(diff_file, out, findings)
    assert exit_code == 0, (
        f"minor-only findings must not block; got {exit_code}. stderr={stderr!r}"
    )


def test_runner_exits_0_on_no_findings(tmp_path):
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    exit_code, _ = _run_main_with(diff_file, out, [])
    assert exit_code == 0, f"empty findings must not block; got {exit_code}"


def test_runner_skips_blocking_for_specialist_errors(tmp_path):
    """specialist_error / fallback_exhausted are infra issues — handled by existing
    all-error gate (exit 1 only when all are errors); MUST NOT also count as
    blocking severity findings (would double-count and break the warning path)."""
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    findings = [
        {
            "type": "specialist_error",
            "severity": "important",  # synthetic findings carry severity but should not block
            "category": "correctness",
            "description": "litellm import failed",
            "cited_lines": [],
        },
        {
            "severity": "minor",
            "category": "hygiene",
            "description": "real but minor",
            "cited_lines": ["foo:1"],
        },
    ]
    exit_code, stderr = _run_main_with(diff_file, out, findings)
    # Synthetic findings warn but do not block; minor real finding does not block.
    assert exit_code == 0, (
        f"synthetic important findings must not block (only real ones do); "
        f"got {exit_code}. stderr={stderr!r}"
    )


def test_runner_posts_pr_review_when_findings(tmp_path):
    """Each blocking finding must be posted as its own PR comment, so the team
    can resolve/respond to them independently in the GitHub PR UI.

    Uses GITHUB_EVENT_NAME=pull_request + GITHUB_REF=refs/pull/123/merge to simulate
    PR context; mocks subprocess.run to capture each gh CLI invocation.
    """
    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    findings = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "needs fix A",
            "cited_lines": ["foo:1"],
        },
        {
            "severity": "fragile",
            "category": "correctness",
            "description": "shaky reference B",
            "cited_lines": ["foo:7"],
        },
        {
            "severity": "critical",
            "category": "correctness",
            "description": "real bug C",
            "cited_lines": ["foo:12"],
        },
    ]

    captured_calls = []

    def _capture_run(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        from subprocess import CompletedProcess

        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/123/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
    }

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _capture_run
        # Real exception types so the runner's `except` clauses match by identity
        # if the stub ever raises (currently it doesn't).
        import subprocess as _real_subprocess

        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [
        c for c in captured_calls if "gh" in (c[0] if isinstance(c, list) else c)
    ]
    assert len(gh_calls) == len(findings), (
        f"Expected one gh pr comment call per blocking finding "
        f"({len(findings)} total); got {len(gh_calls)}: {gh_calls!r}"
    )

    # Each call body should reference exactly one finding (the i/N counter).
    bodies = [c[c.index("--body") + 1] if "--body" in c else "" for c in gh_calls]
    for i, body in enumerate(bodies, 1):
        assert f"finding {i}/{len(findings)}" in body, (
            f"Comment {i} body missing the finding-index marker; got: {body!r:.200}"
        )


def test_runner_partial_post_failure_continues_remaining_findings(tmp_path):
    """When one gh comment call fails, the remaining findings still post.

    Covers the per-finding loop's continue-on-error semantics: a transient
    network blip on comment 2 of 3 must not suppress comments 1 and 3.
    """
    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    findings = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "first finding",
            "cited_lines": ["foo:1"],
        },
        {
            "severity": "important",
            "category": "correctness",
            "description": "second finding (post fails)",
            "cited_lines": ["foo:7"],
        },
        {
            "severity": "important",
            "category": "correctness",
            "description": "third finding",
            "cited_lines": ["foo:12"],
        },
    ]

    captured_calls = []
    call_count = {"n": 0}

    def _flaky_run(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        call_count["n"] += 1
        from subprocess import CalledProcessError, CompletedProcess

        if call_count["n"] == 2:
            raise CalledProcessError(
                returncode=1, cmd=cmd, output="", stderr="simulated network error"
            )
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/123/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
    }

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        import subprocess as _real_subprocess

        mock_subprocess.run.side_effect = _flaky_run
        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [
        c for c in captured_calls if "gh" in (c[0] if isinstance(c, list) else c)
    ]
    assert len(gh_calls) == 3, (
        f"Expected runner to attempt all 3 comment posts even when #2 fails; "
        f"got {len(gh_calls)} attempts: {gh_calls!r}"
    )


def test_runner_skips_pr_post_on_push_event(tmp_path):
    """When GITHUB_EVENT_NAME != pull_request, runner must NOT attempt to post a PR review."""
    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    out = tmp_path / "out.json"
    findings = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "x",
            "cited_lines": ["foo:1"],
        }
    ]

    captured_calls = []

    def _capture_run(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        from subprocess import CompletedProcess

        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "push",
        "GITHUB_TOKEN": "token-stub",
    }

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _capture_run
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [
        c for c in captured_calls if "gh" in (c[0] if isinstance(c, list) else c)
    ]
    assert not gh_calls, (
        f"runner must NOT post PR review on push events; captured gh calls: {gh_calls!r}"
    )
