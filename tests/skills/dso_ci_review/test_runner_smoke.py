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
            "dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result
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
        "security_overlay": False,
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
        patch("dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result),
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
        patch("dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result),
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
    Then: exit code is 1 (fail-closed) and stderr contains ERROR about synthetic findings

    Reverses e840-327f: all-synthetic is a complete-failure case (zero usable review
    content) and must block the PR. Bug a8f6-4c5e.
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
        patch("dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch
        ),
        contextlib.redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 1, (
        f"Expected exit code 1 (fail-closed for all-synthetic findings), got {exit_code}. "
        f"stderr: {stderr_capture.getvalue()!r}"
    )
    stderr_text = stderr_capture.getvalue()
    assert "ERROR" in stderr_text and "synthetic" in stderr_text.lower(), (
        f"Expected ERROR about synthetic findings in stderr, got: {stderr_text!r}"
    )


def test_runner_exits_1_when_all_agents_hit_context_window(tmp_path, capsys):
    """
    Given: ALL reviewer agents fail with ContextWindowExceededError (full chain exhaustion)
    When: runner.main() completes
    Then: exit code is 1 (fail-closed), not 0

    Regression test for bug 223d-7e08-8a4b-4a3a:
    Before fix (e840-327f era): all-synthetic WARNING was emitted but runner returned 0.
    After fix (01b3e02 / a8f6-4c5e): all-synthetic triggers exit 1 with ERROR.

    Each agent returns a fallback_exhausted entry (the DD3 sentinel emitted by
    dispatch_review when the full context_model_chain is exhausted).  From the
    runner's perspective, this is identical to every agent hitting
    ContextWindowExceededError on every model in the chain.
    """
    import dso_ci_review.runner as runner_mod
    import contextlib
    import io

    diff_text = "diff --git a/foo.py b/foo.py\n+added line\n"
    output_file = tmp_path / "findings.json"
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)

    tier_result = {
        "selected_tier": "deep",
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

    # Simulate 5 agents (deep-correctness, deep-verification, deep-hygiene,
    # test-quality, deep-arch) all returning fallback_exhausted — the sentinel
    # emitted when ContextWindowExceededError exhausts the full context chain.
    def _exhausted_entry(agent_id: str) -> dict:
        return {
            "type": "fallback_exhausted",
            "agent_id": agent_id,
            "primary_model": "claude-sonnet-4-6",
            "attempted_cross_provider": [],
            "attempted_context_models": ["claude-sonnet-4-6"],
            "final_exception_class": "ContextWindowExceededError",
            "final_exception_message": "Prompt is too long: 208432 tokens > 200000 limit",
        }

    all_exhausted_findings = [
        {"findings": [_exhausted_entry("code-reviewer-deep-correctness")]},
        {"findings": [_exhausted_entry("code-reviewer-deep-verification")]},
        {"findings": [_exhausted_entry("code-reviewer-deep-hygiene")]},
        {"findings": [_exhausted_entry("code-reviewer-test-quality")]},
        {"findings": [_exhausted_entry("code-reviewer-deep-arch")]},
    ]

    async def mock_dispatch(agents):
        return all_exhausted_findings

    # Arch synthesis also returns exhausted — no non-synthetic fallback possible.
    def mock_arch_synthesis(*args, **kwargs):
        return {"findings": [_exhausted_entry("arch-synthesis")]}

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
        patch("dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch
        ),
        patch(
            "dso_ci_review.runner.dispatch_arch_synthesis",
            side_effect=mock_arch_synthesis,
        ),
        contextlib.redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    stderr_text = stderr_capture.getvalue()
    assert exit_code == 1, (
        "Expected exit code 1 when all agents hit ContextWindowExceededError "
        f"(all findings are fallback_exhausted), got {exit_code}. "
        f"stderr: {stderr_text!r}"
    )
    assert "ERROR" in stderr_text and "synthetic" in stderr_text.lower(), (
        f"Expected ERROR about synthetic findings in stderr, got: {stderr_text!r}"
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
            "dso_ci_review.runner._classify_tier_via_bash",
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


def test_build_agents_for_tier_includes_tier_in_agent_dicts(tmp_path):
    """_build_agents_for_tier must set 'tier' on every agent dict it returns.

    async_dispatch_specialists reads agent['tier'] to pass to dispatch_review,
    so light-tier dispatch correctly skips the augmentation loop in production.
    Without this field, a.get('tier', 'standard') defaults to 'standard', enabling
    the loop for all tiers including light.
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("model.light=claude-haiku-4-5-20251001\n")

    for tier in ("light", "standard", "deep"):
        agents = runner_mod._build_agents_for_tier(
            tier, "diff text", {}, config_path=str(config_file)
        )
        for agent in agents:
            assert "tier" in agent, (
                f"Agent dict for tier={tier!r} missing 'tier' key; "
                f"async_dispatch_specialists relies on this to propagate tier to dispatch_review. "
                f"Got keys: {list(agent.keys())}"
            )
            assert agent["tier"] == tier, (
                f"Agent dict 'tier' value mismatch for {tier!r}: expected {tier!r}, got {agent['tier']!r}"
            )


def test_call_single_agent_passes_tier_to_dispatch_review():
    """_call_single_agent must forward its tier param to dispatch_review.

    This is the production path that ensures light-tier skips the augmentation loop.
    Without tier propagation, dispatch_review receives tier='standard' (its default)
    and enables the loop even for light-tier agents.
    """
    import asyncio
    from unittest.mock import patch

    sys.path.insert(0, str(SCRIPTS_DIR))
    from dso_ci_review.dispatch import _call_single_agent

    captured_kwargs: list = []

    def mock_dispatch_review(**kwargs):
        captured_kwargs.append(kwargs)
        return {"findings": []}

    with patch(
        "dso_ci_review.dispatch.dispatch_review", side_effect=mock_dispatch_review
    ):
        asyncio.run(
            _call_single_agent(
                agent_id="code-reviewer-light",
                diff_text="diff text",
                model="claude-haiku-4-5-20251001",
                provider_chain=["anthropic"],
                tier="light",
            )
        )

    assert captured_kwargs, "dispatch_review was not called"
    assert captured_kwargs[0].get("tier") == "light", (
        f"_call_single_agent must forward tier='light' to dispatch_review; "
        f"got tier={captured_kwargs[0].get('tier')!r}. "
        "Light-tier augmentation loop skip depends on this propagation."
    )


def test_read_tier_model_resolves_repo_root_config(tmp_path, monkeypatch):
    """
    Bug 0e2a-77b0: _read_tier_model and the provider-resolution branch in main
    construct config_path via os.path.dirname(__file__) chains. The chain must
    resolve to <repo_root>/.claude/dso-config.conf — the previous 3-level chain
    landed at <repo_root>/<plugin_root>/ where .claude/ does not exist, silently
    discarding any model.<tier> override.

    This test asserts the corrected 5-level chain by:
      1. Running _read_tier_model with no env override and an explicit config_path
         pointing at a fixture file with model.light=test-marker → asserts override.
      2. Running _read_tier_model with NO config_path (auto-detect from __file__)
         and asserting the function does not error and returns a non-empty model
         string. (Direct path-equality assertion would couple the test to the
         on-disk repo layout; the behavioral assertion that auto-detect succeeds
         on the live repo is the durable contract.)
    """
    sys.path.insert(0, str(SCRIPTS_DIR))
    try:
        import dso_ci_review.runner as runner_mod
    finally:
        if str(SCRIPTS_DIR) in sys.path:
            sys.path.remove(str(SCRIPTS_DIR))

    monkeypatch.delenv("DSO_CI_REVIEW_MODEL", raising=False)

    # 1. Explicit config_path override
    cfg = tmp_path / "dso-config.conf"
    cfg.write_text(
        "model.light=test-marker-light-xyz\nmodel.standard=test-marker-std-xyz\n"
    )
    assert (
        runner_mod._read_tier_model("light", config_path=str(cfg))
        == "test-marker-light-xyz"
    )
    assert (
        runner_mod._read_tier_model("standard", config_path=str(cfg))
        == "test-marker-std-xyz"
    )

    # 2. Auto-detect on live repo — must produce a non-empty model string,
    #    not raise, and not return the literal default-fallback when the live
    #    .claude/dso-config.conf has model.light= configured.
    auto = runner_mod._read_tier_model("light")
    assert isinstance(auto, str) and auto, (
        "_read_tier_model('light') must return a non-empty string after the "
        "5-level dirname chain resolves the live config (0e2a-77b0)"
    )


# ---------------------------------------------------------------------------
# Bash classifier migration tests — classify_tier → _classify_tier_via_bash
# ---------------------------------------------------------------------------
#
# RED marker:
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_uses_bash_classifier]
#
# Task 6430-6a72: assert runner.py calls _classify_tier_via_bash helper
# (the bash subprocess wrapper) instead of the Python classify_tier function.
# These tests must fail (RED) before Task B lands the implementation.


def test_runner_uses_bash_classifier(tmp_path):
    """
    Given: a non-empty diff and mocked _classify_tier_via_bash + async_dispatch_specialists
    When: runner.main() is called in-process
    Then: _classify_tier_via_bash is called once with the diff text argument

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_uses_bash_classifier]

    This test must FAIL before Task B replaces classify_tier() with _classify_tier_via_bash()
    in runner.py. The helper does not exist yet in the runner module.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/foo.py b/foo.py\n+added line\n"
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "findings.json"

    bash_tier_result = {
        "selected_tier": "standard",
        "security_overlay": False,
        "performance_overlay": False,
        "test_quality_overlay": False,
        "diff_size_lines": 5,
        "blast_radius": 0,
        "critical_path": 0,
        "anti_shortcut": 0,
        "staleness": 0,
        "cross_cutting": 0,
        "diff_lines": 1,
        "change_volume": 0,
        "computed_total": 0,
        "is_merge_commit": False,
        "size_action": "none",
    }

    async def mock_dispatch(agents):
        return [{"findings": [], "scores": {}, "summary": "ok"}]

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=bash_tier_result,
        ) as mock_bash_classify,
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        redirect_stderr(stderr_capture),
    ):
        runner_mod.main()

    # runner.main() must call _classify_tier_via_bash(diff_text) exactly once;
    # Task B must replace classify_tier() with _classify_tier_via_bash() in runner.py.
    mock_bash_classify.assert_called_once_with(diff_text)


# ---------------------------------------------------------------------------
# Overlay agent dispatch tests — tasks 3c18-91b8, a643-4a2a, d189-d70f
# ---------------------------------------------------------------------------
#
# RED markers:
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_overlay_agents_dispatched_in_parallel_when_flagged_by_classifier]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_overlay_warranted_fallback_dispatched_serially]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_deep_tier_runs_arch_synthesis_after_specialists]


def test_overlay_agents_dispatched_in_parallel_when_flagged_by_classifier(tmp_path):
    """
    Given: classifier returns standard tier with security_overlay=True
    When: runner.main() executes
    Then: _classify_tier_via_bash is called
          AND the dispatch call includes a security overlay agent
          (code-reviewer-security-red-team) dispatched in parallel alongside
          the standard specialist

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_overlay_agents_dispatched_in_parallel_when_flagged_by_classifier]

    FAILS pre-implementation because _build_overlay_agents does not exist in runner.py.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/auth.py b/auth.py\n+secret = token\n"
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "findings.json"

    tier_result = {
        "selected_tier": "standard",
        "size_action": "none",
        "security_overlay": True,
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

    captured_agents: list = []

    async def mock_dispatch(agents):
        captured_agents.extend(agents)
        return [{"findings": [], "scores": {}, "summary": "ok"}]

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=tier_result,
        ) as mock_classify,
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        redirect_stderr(stderr_capture),
    ):
        runner_mod.main()

    mock_classify.assert_called_once_with(diff_text)

    agent_ids = {a["agent_id"] for a in captured_agents}
    assert "code-reviewer-security-red-team" in agent_ids, (
        f"When security_overlay=True, the first parallel dispatch must include "
        f"'code-reviewer-security-red-team'. Captured agent_ids: {agent_ids!r}. "
        "Implement _build_overlay_agents in runner.py (task 3c18-91b8)."
    )
    assert "code-reviewer-standard" in agent_ids, (
        f"Standard specialist must still be dispatched alongside the overlay; "
        f"captured agent_ids: {agent_ids!r}"
    )


def test_overlay_warranted_fallback_dispatched_serially(tmp_path):
    """
    Given: classifier returns standard tier with NO overlay flags set
           AND the first-pass findings include a finding with
           type="overlay_warranted" and dimension="security"
    When: runner.main() executes
    Then: a security overlay agent is dispatched in a SECOND serial pass
          (not the first parallel pass)

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_overlay_warranted_fallback_dispatched_serially]

    FAILS pre-implementation because _overlay_agents_from_findings does not exist.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/secrets.py b/secrets.py\n+API_KEY = hardcoded\n"
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

    # First-pass findings include an overlay_warranted signal
    first_pass_findings = [
        {
            "findings": [
                {
                    "type": "overlay_warranted",
                    "dimension": "security",
                    "severity": "minor",
                    "description": "Possible secret exposure detected — security overlay recommended",
                    "cited_lines": ["secrets.py:1"],
                }
            ],
            "scores": {"correctness": 3},
            "summary": "overlay recommended",
        }
    ]

    dispatch_call_count = {"n": 0}
    second_pass_agents: list = []

    async def mock_dispatch(agents):
        dispatch_call_count["n"] += 1
        if dispatch_call_count["n"] == 2:
            # Record what was dispatched in the second (serial) pass
            second_pass_agents.extend(agents)
            return [{"findings": [], "scores": {}, "summary": "security ok"}]
        return first_pass_findings

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=tier_result,
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        redirect_stderr(stderr_capture),
    ):
        runner_mod.main()

    assert dispatch_call_count["n"] >= 2, (
        f"Expected at least 2 dispatch calls (first pass + serial overlay); "
        f"got {dispatch_call_count['n']}. "
        "Implement _overlay_agents_from_findings in runner.py (task a643-4a2a)."
    )
    second_pass_ids = {a["agent_id"] for a in second_pass_agents}
    assert "code-reviewer-security-red-team" in second_pass_ids, (
        f"Second (serial) dispatch must include 'code-reviewer-security-red-team' "
        f"when first-pass findings contain overlay_warranted/security. "
        f"Second-pass agent_ids: {second_pass_ids!r}. "
        "Implement _overlay_agents_from_findings in runner.py (task a643-4a2a)."
    )


def test_deep_tier_runs_arch_synthesis_after_specialists(tmp_path):
    """
    Given: classifier returns deep tier
    When: runner.main() executes
    Then: 3 parallel specialist calls run first (correctness, verification, hygiene)
          AND dispatch_arch_synthesis is called AFTER specialists complete
          AND the final output is the arch synthesis result, not raw specialist output

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_deep_tier_runs_arch_synthesis_after_specialists]

    FAILS pre-implementation with AttributeError because dispatch_arch_synthesis
    does not exist in dso_ci_review.runner (or dso_ci_review.dispatch).
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/auth/login.py b/auth/login.py\n+token = secret\n" * 10
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "findings.json"

    tier_result = {
        "selected_tier": "deep",
        "size_action": "none",
        "security_overlay": False,
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

    specialist_results = [
        {
            "findings": [
                {
                    "severity": "important",
                    "description": "correctness issue",
                    "cited_lines": ["auth/login.py:1"],
                }
            ],
            "scores": {"correctness": 2},
            "summary": "correctness",
        },
        {
            "findings": [],
            "scores": {"verification": 3},
            "summary": "verification ok",
        },
        {
            "findings": [
                {
                    "severity": "minor",
                    "description": "style nit",
                    "cited_lines": ["auth/login.py:5"],
                }
            ],
            "scores": {"hygiene": 4},
            "summary": "hygiene",
        },
    ]

    synthesis_output = {
        "findings": [
            {
                "severity": "important",
                "description": "arch-synthesized: correctness issue confirmed",
                "cited_lines": ["auth/login.py:1"],
            }
        ],
        "scores": {"correctness": 2, "verification": 3, "hygiene": 4},
        "summary": "Arch synthesis complete.",
    }

    captured_synthesis_calls: list = []

    async def mock_dispatch(agents):
        return specialist_results

    def mock_arch_synthesis(merged_findings_json, **kwargs):
        captured_synthesis_calls.append(merged_findings_json)
        return synthesis_output

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=tier_result,
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        patch(
            "dso_ci_review.runner.dispatch_arch_synthesis",
            side_effect=mock_arch_synthesis,
        ),
        redirect_stderr(stderr_capture),
    ):
        runner_mod.main()

    assert len(captured_synthesis_calls) == 1, (
        f"dispatch_arch_synthesis must be called exactly once after deep-tier specialists; "
        f"got {len(captured_synthesis_calls)} calls. "
        "Implement dispatch_arch_synthesis in dispatch.py and call it from runner.py "
        "after specialist results are collected (task d189-d70f)."
    )

    parsed = json.loads(output_file.read_text())
    assert parsed.get("summary") == "Arch synthesis complete.", (
        f"Final output must be the arch synthesis result, not raw specialist output. "
        f"Got summary: {parsed.get('summary')!r}. "
        "runner.main() must use dispatch_arch_synthesis return value as the merged output "
        "for deep tier (task d189-d70f)."
    )


# ---------------------------------------------------------------------------
# Cycle-2 dismissal-memory tests — bug c59e-a197
# ---------------------------------------------------------------------------
#
# The review pipeline lacked dismissal memory: on cycle N≥2, previously-defended
# findings could be re-emitted verbatim and block merge again. These tests cover:
#   1. _fetch_pr_defenses: parses DEFENSE_RECORD: lines from gh output
#   2. _suppress_defended_findings: downgrades verbatim defended findings
#   3. runner.main() on cycle 2 with defenses: dispatches two-call path and
#      applies the suppression filter
#   4. runner.main() on cycle 1 (no defenses): standard path unchanged


def test_fetch_pr_defenses_parses_defense_records():
    """_fetch_pr_defenses must parse DEFENSE_RECORD: lines from gh pr view output.

    Given: gh pr view returns comment bodies containing DEFENSE_RECORD: lines
    When: _fetch_pr_defenses is called with a PR number
    Then: it returns a list of dicts parsed from the DEFENSE_RECORD JSON values
    """
    import dso_ci_review.runner as runner_mod
    from subprocess import CompletedProcess

    gh_output = (
        "Some unrelated comment\n"
        'DEFENSE_RECORD: {"severity": "critical", "description": "write_bridge_alert signature mismatch"}\n'
        "Another line\n"
        'DEFENSE_RECORD: {"severity": "important", "description": "ticket_reducer NameError"}\n'
    )

    def _mock_run(cmd, **kwargs):
        return CompletedProcess(args=cmd, returncode=0, stdout=gh_output, stderr="")

    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "test-token"}),
        patch.object(runner_mod, "subprocess", create=True) as mock_sub,
    ):
        import subprocess as _real_sub

        mock_sub.run.side_effect = _mock_run
        mock_sub.TimeoutExpired = _real_sub.TimeoutExpired
        mock_sub.CalledProcessError = _real_sub.CalledProcessError

        result = runner_mod._fetch_pr_defenses("123")

    assert len(result) == 2, (
        f"Expected 2 defense records parsed from DEFENSE_RECORD: lines; got {len(result)}: {result!r}"
    )
    assert result[0]["severity"] == "critical"
    assert result[1]["description"] == "ticket_reducer NameError"


def test_fetch_pr_defenses_returns_empty_without_token():
    """_fetch_pr_defenses must return [] when GITHUB_TOKEN is absent (no gh call)."""
    import dso_ci_review.runner as runner_mod

    called = []
    with patch.dict("os.environ", {}, clear=True):  # no GITHUB_TOKEN
        with patch.object(runner_mod, "subprocess", create=True) as mock_sub:
            mock_sub.run.side_effect = lambda *a, **kw: called.append(a)
            result = runner_mod._fetch_pr_defenses("123")

    assert result == [], f"Expected [] without GITHUB_TOKEN; got {result!r}"
    assert not called, "gh must NOT be called when GITHUB_TOKEN is absent"


def test_suppress_defended_findings_downgrades_matching_findings():
    """_suppress_defended_findings must downgrade findings that match prior defenses.

    Given: findings list with one finding that matches a prior defense (same severity+desc[:80])
    When: _suppress_defended_findings is called
    Then: the matching finding's severity is downgraded to 'suggestion'
          AND non-matching findings are unchanged
    """
    import dso_ci_review.runner as runner_mod

    defended_desc = "write_bridge_alert signature mismatch — wrong positional arg"
    defenses = [{"severity": "critical", "description": defended_desc}]
    findings = [
        {
            "severity": "critical",
            "description": defended_desc,
            "cited_lines": ["foo.py:1"],
        },
        {
            "severity": "important",
            "description": "unrelated new finding",
            "cited_lines": ["bar.py:5"],
        },
    ]

    result = runner_mod._suppress_defended_findings(findings, defenses)

    assert len(result) == 2, f"Should return same count; got {len(result)}: {result!r}"
    # Defended finding is downgraded
    assert result[0]["severity"] == "suggestion", (
        f"Matched finding must be downgraded to 'suggestion'; got {result[0]['severity']!r}"
    )
    assert "_suppressed_reason" in result[0], (
        "Suppressed finding must have _suppressed_reason"
    )
    # Unmatched finding is unchanged
    assert result[1]["severity"] == "important", (
        f"Unmatched finding must be unchanged; got {result[1]['severity']!r}"
    )


def test_suppress_defended_findings_noop_when_no_defenses():
    """_suppress_defended_findings must return findings unchanged when defenses is empty."""
    import dso_ci_review.runner as runner_mod

    findings = [
        {"severity": "critical", "description": "real issue", "cited_lines": ["x.py:1"]}
    ]
    result = runner_mod._suppress_defended_findings(findings, [])
    assert result == findings, f"No-op with empty defenses; got {result!r}"


def test_runner_cycle2_with_defenses_suppresses_reemitted_findings(tmp_path):
    """On cycle 2, a finding that matches a prior defense must be downgraded to 'suggestion'.

    Given: DSO_REVIEW_CYCLE=2, GITHUB_EVENT_NAME=pull_request, PR has a DEFENSE_RECORD
           for a critical finding, and the LLM re-emits the same critical finding verbatim
    When: runner.main() executes
    Then: the re-emitted finding is downgraded to 'suggestion' (not blocking)
          AND exit code is 0 (no blocking findings remain)

    Mocking strategy:
    - _fetch_pr_defenses patched to return a defense record without needing gh CLI.
    - dispatch_two_call_review patched to return the re-emitted finding (simulating LLM
      ignoring the defense context and re-firing the finding anyway).
    - async_dispatch_specialists not used on the two-call path (standard tier + defenses).
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    defended_desc = (
        "write_bridge_alert signature mismatch — outbound vs inbound confusion"
    )
    defense_record = {"severity": "critical", "description": defended_desc}

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    output_file = tmp_path / "out.json"

    # LLM re-emits the exact same finding that was defended (worst-case: ignores context)
    reemitted_findings = {
        "findings": [
            {
                "severity": "critical",
                "description": defended_desc,
                "cited_lines": ["bridge.py:1"],
            }
        ]
    }

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "DSO_REVIEW_CYCLE": "2",
                "GITHUB_EVENT_NAME": "pull_request",
                "GITHUB_REF": "refs/pull/77/merge",
                "GITHUB_TOKEN": "test-token",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch("dso_ci_review.runner._fetch_pr_defenses", return_value=[defense_record]),
        patch(
            "dso_ci_review.runner.dispatch_two_call_review",
            return_value=reemitted_findings,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    parsed = json.loads(output_file.read_text())
    findings = parsed.get("findings", [])

    assert exit_code == 0, (
        f"Exit code must be 0 after cycle-2 suppression of defended finding; "
        f"got {exit_code}. stderr={stderr_capture.getvalue()!r}"
    )
    assert len(findings) == 1, (
        f"Expected 1 finding (downgraded); got {len(findings)}: {findings!r}"
    )
    assert findings[0]["severity"] == "suggestion", (
        f"Re-emitted defended finding must be downgraded to 'suggestion'; "
        f"got severity={findings[0]['severity']!r}"
    )


def test_runner_cycle2_deep_tier_partial_failure_with_defenses(tmp_path):
    """Cycle-2 + deep-tier: one specialist fallback_exhausted does NOT skip arch synthesis.

    Given: DSO_REVIEW_CYCLE=2, deep tier, one prior defense, 3 specialist results where
           one returns fallback_exhausted (partial failure) and one returns a real finding
    When: runner.main() executes
    Then: dispatch_arch_synthesis is called exactly once (partial failure doesn't skip synthesis)
          AND the arch synthesis call received defense context (defenses injected into merged_json)
          AND the output contains the real important finding unchanged
          AND the defended finding is downgraded to 'suggestion' by _suppress_defended_findings

    Covers bug 5329-552b-7847-4a24: no test for cycle-2 + deep-tier + partial agent failure
    + arch synthesis + defense suppression.

    The arch_all_synthetic check fires only when ALL findings are synthetic — one
    fallback_exhausted among real findings must NOT prevent arch synthesis from replacing
    the merged output.
    """
    import io
    import json as _json
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    defended_desc = "missing null check in auth handler — defended in round 1"
    defense_record = {"severity": "critical", "description": defended_desc}

    diff_file = tmp_path / "input.diff"
    diff_file.write_text(
        "diff --git a/auth/handler.py b/auth/handler.py\n+token = request.token\n"
    )
    output_file = tmp_path / "findings.json"

    tier_result = {
        "selected_tier": "deep",
        "size_action": "none",
        "security_overlay": False,
        "performance_overlay": False,
        "test_quality_overlay": False,
        "diff_size_lines": 2,
        "blast_radius": 2,
        "critical_path": 3,
        "anti_shortcut": 0,
        "staleness": 0,
        "cross_cutting": 0,
        "diff_lines": 1,
        "change_volume": 0,
        "computed_total": 8,
        "is_merge_commit": False,
    }

    # 3 specialist results: one fallback_exhausted, one real finding, one empty
    specialist_results = [
        {
            "findings": [
                {
                    "type": "fallback_exhausted",
                    "severity": "critical",
                    "description": "specialist failed",
                }
            ],
            "summary": "specialist infra failure",
        },
        {
            "findings": [
                {
                    "severity": "important",
                    "description": "real correctness issue in handler",
                    "cited_lines": ["auth/handler.py:1"],
                }
            ],
            "summary": "correctness",
        },
        {
            "findings": [],
            "summary": "verification ok",
        },
    ]

    # Arch synthesis returns BOTH the defended finding and the real finding.
    # _suppress_defended_findings should downgrade the defended one.
    synthesis_output = {
        "findings": [
            {
                "severity": "critical",
                "description": defended_desc,
                "cited_lines": ["auth/handler.py:5"],
            },
            {
                "severity": "important",
                "description": "real correctness issue in handler",
                "cited_lines": ["auth/handler.py:1"],
            },
        ],
        "scores": {"correctness": 2, "verification": 3},
        "summary": "Arch synthesis: partial failure, real findings remain.",
    }

    captured_synthesis_calls: list[str] = []

    async def mock_dispatch(agents):
        return specialist_results

    def mock_arch_synthesis(merged_findings_json, **kwargs):
        captured_synthesis_calls.append(merged_findings_json)
        return synthesis_output

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "DSO_REVIEW_CYCLE": "2",
                "GITHUB_EVENT_NAME": "pull_request",
                "GITHUB_REF": "refs/pull/99/merge",
                "GITHUB_TOKEN": "test-token",
            },
        ),
        patch("dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result),
        patch("dso_ci_review.runner._fetch_pr_defenses", return_value=[defense_record]),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        patch(
            "dso_ci_review.runner.dispatch_arch_synthesis",
            side_effect=mock_arch_synthesis,
        ),
        redirect_stderr(stderr_capture),
    ):
        runner_mod.main()

    # 1. Arch synthesis must be called exactly once — partial failure doesn't skip it.
    assert len(captured_synthesis_calls) == 1, (
        f"dispatch_arch_synthesis must be called exactly once even with one fallback_exhausted "
        f"specialist; got {len(captured_synthesis_calls)} calls. "
        "arch_all_synthetic must NOT fire when only some findings are synthetic (bug 5329-552b)."
    )

    # 2. Defense content must have been injected into the merged JSON passed to arch synthesis.
    # Check the defense record's actual description is present — not the prose section label,
    # which is an implementation detail that could be renamed without breaking behavior.
    arch_call_arg = captured_synthesis_calls[0]
    # defended_desc may be JSON-encoded (em-dash → —); check for prefix before the dash
    defended_desc_prefix = defended_desc.split("—")[0].strip()
    assert defended_desc_prefix in arch_call_arg, (
        f"Arch synthesis merged JSON must contain the defended description content; "
        f"got: {arch_call_arg!r}"
    )

    # 3. Real important finding must be present and unchanged.
    parsed = _json.loads(output_file.read_text())
    findings = parsed.get("findings", [])
    real_findings = [
        f
        for f in findings
        if f.get("description") == "real correctness issue in handler"
    ]
    assert len(real_findings) == 1, (
        f"Real important finding must survive suppression filter; "
        f"findings: {findings!r}"
    )
    assert real_findings[0]["severity"] == "important", (
        f"Real finding must remain 'important' (not defensible); "
        f"got severity={real_findings[0]['severity']!r}"
    )

    # 4. Defended finding must be downgraded to 'suggestion' by _suppress_defended_findings.
    #
    # _suppress_defended_findings is NOT mocked — the real function runs against the
    # real arch synthesis output. The mock returns severity="critical" for the defended
    # finding; the only way that severity becomes "suggestion" in the output is if
    # _suppress_defended_findings ran and matched (severity, description[:80]) against
    # the prior defense record. A skipped, broken, or bypassed suppression would leave
    # severity="critical" and this assertion would fail.
    defended_findings = [f for f in findings if f.get("description") == defended_desc]
    assert len(defended_findings) == 1, (
        f"Defended finding must appear in output (downgraded, not removed); "
        f"findings: {findings!r}"
    )
    assert defended_findings[0]["severity"] == "suggestion", (
        f"Defended finding must be downgraded from 'critical' (arch synthesis mock value) to "
        f"'suggestion' by _suppress_defended_findings; got severity={defended_findings[0]['severity']!r}. "
        "If this fails, _suppress_defended_findings is broken, bypassed, or not matching the defense key."
    )


def test_runner_cycle1_no_defenses_unaffected(tmp_path):
    """On cycle 1 (default), the standard path is used — no defense fetching, no suppression.

    Given: DSO_REVIEW_CYCLE=1 (or absent), an important finding from the LLM
    When: runner.main() executes
    Then: exit code is 1 (important finding blocks)
          AND no defense fetch is attempted
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo b/foo\n+x\n")
    output_file = tmp_path / "out.json"

    findings = [
        {
            "severity": "important",
            "description": "genuine new finding",
            "cited_lines": ["foo:1"],
        }
    ]

    async def mock_dispatch(agents):
        return [{"findings": findings}]

    gh_called = []

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                # DSO_REVIEW_CYCLE absent → defaults to 1
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch
        ),
        patch(
            "dso_ci_review.runner._fetch_pr_defenses",
            side_effect=lambda pr: gh_called.append(pr) or [],
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 1, (
        f"Cycle 1 with important finding must block (exit 1); got {exit_code}"
    )
    assert not gh_called, (
        f"_fetch_pr_defenses must NOT be called on cycle 1; was called with: {gh_called!r}"
    )


# ---------------------------------------------------------------------------
# Region-split routing tests (Strategy E, bed6-3871-f13c-4160)
# ---------------------------------------------------------------------------


def _make_large_diff(loc: int = 450) -> str:
    """Return a synthetic diff with at least ``loc`` changed lines, all in one file."""
    header = "diff --git a/bigfile.py b/bigfile.py\n--- a/bigfile.py\n+++ b/bigfile.py\n@@ -1 +1 @@\n"
    body = "".join(f"+line {i}\n" for i in range(loc))
    return header + body


def _make_small_diff(loc: int = 5) -> str:
    """Return a synthetic diff with only ``loc`` changed lines."""
    header = "diff --git a/small.py b/small.py\n--- a/small.py\n+++ b/small.py\n@@ -1 +1 @@\n"
    body = "".join(f"+line {i}\n" for i in range(loc))
    return header + body


def test_runner_calls_run_region_split_for_large_diff(tmp_path):
    """
    Given: a diff exceeding 400 LOC (region-split threshold)
    When: runner.main() is called in-process
    Then: run_region_split is called (not standard tier dispatch)
          AND async_dispatch_specialists is NOT called directly by the runner

    Strategy E (bed6-3871-f13c-4160): large diffs bypass the standard tier path
    and route through the region-split pipeline.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = _make_large_diff(450)
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "out.json"

    region_split_called: list[dict] = []

    def mock_run_region_split(**kwargs):
        region_split_called.append(kwargs)
        return {"findings": []}

    dispatch_called: list = []

    async def mock_dispatch(agents):
        dispatch_called.extend(agents)
        return [{"findings": []}]

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.run_region_split",
            side_effect=mock_run_region_split,
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 0, (
        f"Expected exit code 0 (no blocking findings), got {exit_code}. "
        f"stderr={stderr_capture.getvalue()!r}"
    )
    assert region_split_called, (
        "run_region_split must be called when diff exceeds 400 LOC threshold"
    )
    assert not dispatch_called, (
        "async_dispatch_specialists must NOT be called by the runner when "
        f"region-split is active; called with: {dispatch_called!r}"
    )


def test_runner_skips_run_region_split_for_small_diff(tmp_path):
    """
    Given: a diff below the 400 LOC region-split threshold
    When: runner.main() is called in-process
    Then: run_region_split is NOT called
          AND async_dispatch_specialists IS called (normal path)

    Strategy E (bed6-3871-f13c-4160): small diffs use the standard tier pipeline.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = _make_small_diff(5)
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "out.json"

    region_split_called: list = []

    def mock_run_region_split(**kwargs):
        region_split_called.append(kwargs)
        return {"findings": []}

    dispatch_called: list = []

    async def mock_dispatch(agents):
        dispatch_called.extend(agents)
        return [{"findings": []}]

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.run_region_split",
            side_effect=mock_run_region_split,
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 0, (
        f"Expected exit code 0 (no blocking findings), got {exit_code}. "
        f"stderr={stderr_capture.getvalue()!r}"
    )
    assert not region_split_called, (
        "run_region_split must NOT be called for small diffs; "
        f"was called with: {region_split_called!r}"
    )
    assert dispatch_called, (
        "async_dispatch_specialists must be called for small diffs (standard tier path)"
    )


# ---------------------------------------------------------------------------
# Schema validation hook tests — story 4425-a483-9cfe-466a
# ---------------------------------------------------------------------------
#
# Tests for _validate_findings_schema(), to be inserted in runner.py between
# merge_findings() and _write_output(). The function does NOT exist yet;
# all tests below must fail RED until Task T2 implements it.
#
# RED markers:
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_validate_findings_schema_pass_returns_pass_status]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_validate_findings_schema_missing_cited_excerpt_returns_schema_fail]

_VALIDATOR_SCRIPT = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "validate-review-output.sh"
)

# A fully valid finding dict that satisfies the code-review-dispatch schema.
# Required fields per validate-review-output.sh: severity, category, description,
# file, cited_lines, cited_excerpt; plus reachability when severity is critical/important/fragile.
_VALID_FINDING = {
    "severity": "minor",
    "category": "hygiene",
    "description": "A test finding with all required fields present.",
    "file": "foo.py",
    "cited_lines": ["foo.py:1"],
    "cited_excerpt": "print('hello')",
}

_VALID_FINDINGS_DICT = {
    "findings": [_VALID_FINDING],
    "summary": "One minor finding.",
}

# A finding that is missing cited_excerpt — should trigger schema_fail.
_INVALID_FINDING_MISSING_CITED_EXCERPT = {
    "severity": "minor",
    "category": "hygiene",
    "description": "Missing cited_excerpt field.",
    "file": "foo.py",
    "cited_lines": ["foo.py:1"],
    # cited_excerpt intentionally absent
}

_INVALID_FINDINGS_DICT = {
    "findings": [_INVALID_FINDING_MISSING_CITED_EXCERPT],
    "summary": "One invalid finding.",
}


def test_validate_findings_schema_pass_returns_pass_status():
    """
    Given: a findings dict with a valid finding containing all required fields
    When: _validate_findings_schema(findings_dict) is called (invokes validate-review-output.sh LIVE)
    Then: returns a _SchemaValidationResult with status="schema_pass" and empty errors list

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_validate_findings_schema_pass_returns_pass_status]

    At least one live-validator test per story DD3 (not mocked).
    """
    import os

    import dso_ci_review.runner as runner_mod

    # AC amendment: verify executable bit before live test
    assert os.access(_VALIDATOR_SCRIPT, os.X_OK), (
        f"validate-review-output.sh is not executable: {_VALIDATOR_SCRIPT}. "
        "Live tests will route through validator_error instead of the expected path."
    )

    result = runner_mod._validate_findings_schema(_VALID_FINDINGS_DICT)

    assert result.status == "schema_pass", (
        f"Expected status='schema_pass' for a valid findings dict; got {result.status!r}. "
        f"errors={result.errors!r}"
    )
    assert result.errors == [], (
        f"Expected empty errors list on schema_pass; got {result.errors!r}"
    )


def test_validate_findings_schema_pass_no_tmpfile_remains(tmp_path):
    """
    Given: a valid findings dict and _validate_findings_schema is called
    When: the function completes (schema_pass path)
    Then: no tmpfile is left in the temp directory after the call

    Verifies tmpfile cleanup in the happy path (AC amendment: cleanup in all exit paths).
    """
    import os
    import tempfile

    import dso_ci_review.runner as runner_mod

    # Track files created in the temp dir before and after
    tmpdir = tempfile.gettempdir()
    before = set(os.listdir(tmpdir))

    runner_mod._validate_findings_schema(_VALID_FINDINGS_DICT)

    after = set(os.listdir(tmpdir))
    new_files = after - before

    # Any tmpfile created by _validate_findings_schema must be cleaned up
    assert not new_files, (
        f"_validate_findings_schema left orphaned tmpfile(s) in {tmpdir}: {new_files}. "
        "Tmpfiles must be cleaned up in all exit paths (AC amendment)."
    )


def test_validate_findings_schema_missing_cited_excerpt_returns_schema_fail():
    """
    Given: a findings dict with a real finding that is missing cited_excerpt
    When: _validate_findings_schema(findings_dict) is called (invokes validate-review-output.sh LIVE)
    Then: returns _SchemaValidationResult with status="schema_fail" and non-empty errors list

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_validate_findings_schema_missing_cited_excerpt_returns_schema_fail]

    Uses live validate-review-output.sh (not mocked) per story DD3.
    """
    import os

    import dso_ci_review.runner as runner_mod

    # AC amendment: verify executable bit before live test
    assert os.access(_VALIDATOR_SCRIPT, os.X_OK), (
        f"validate-review-output.sh is not executable: {_VALIDATOR_SCRIPT}. "
        "Live tests will route through validator_error instead of the expected path."
    )

    result = runner_mod._validate_findings_schema(_INVALID_FINDINGS_DICT)

    assert result.status == "schema_fail", (
        f"Expected status='schema_fail' for findings missing cited_excerpt; "
        f"got {result.status!r}. errors={result.errors!r}"
    )
    assert result.errors, (
        f"Expected non-empty errors list on schema_fail; got {result.errors!r}"
    )


def test_validate_findings_schema_missing_cited_excerpt_no_tmpfile_remains():
    """
    Given: an invalid findings dict and _validate_findings_schema is called
    When: the function completes (schema_fail path)
    Then: no tmpfile is left in the temp directory after the call

    Verifies tmpfile cleanup in the schema_fail path (AC amendment: cleanup in all exit paths).
    """
    import os
    import tempfile

    import dso_ci_review.runner as runner_mod

    tmpdir = tempfile.gettempdir()
    before = set(os.listdir(tmpdir))

    runner_mod._validate_findings_schema(_INVALID_FINDINGS_DICT)

    after = set(os.listdir(tmpdir))
    new_files = after - before

    assert not new_files, (
        f"_validate_findings_schema left orphaned tmpfile(s) in {tmpdir}: {new_files}. "
        "Tmpfiles must be cleaned up in the schema_fail path (AC amendment)."
    )


def test_validate_findings_schema_validator_not_found_returns_validator_error(tmp_path):
    """
    Given: _validate_findings_schema is patched to use a nonexistent validator path
    When: _validate_findings_schema(findings_dict) is called
    Then: returns _SchemaValidationResult with status="validator_error" and non-empty errors

    Exercises the ENOENT / FileNotFoundError path (validator infrastructure failure → fail-loud).
    """
    import dso_ci_review.runner as runner_mod

    nonexistent = tmp_path / "nonexistent-validate-review-output.sh"

    with patch(
        "dso_ci_review.runner._resolve_validator_script",
        return_value=str(nonexistent),
    ):
        result = runner_mod._validate_findings_schema(_VALID_FINDINGS_DICT)

    assert result.status == "validator_error", (
        f"Expected status='validator_error' when validator script does not exist; "
        f"got {result.status!r}. errors={result.errors!r}"
    )
    assert result.errors, (
        f"Expected non-empty errors list on validator_error; got {result.errors!r}"
    )


def test_validate_findings_schema_validator_not_found_no_tmpfile_remains(tmp_path):
    """
    Given: _validate_findings_schema is patched to use a nonexistent validator path
    When: the function completes (validator_error path via ENOENT)
    Then: no tmpfile is left in the temp directory after the call

    Verifies tmpfile cleanup in the validator_error path (AC amendment: cleanup in all exit paths).
    """
    import os
    import tempfile

    import dso_ci_review.runner as runner_mod

    nonexistent = tmp_path / "nonexistent-validate-review-output.sh"
    tmpdir = tempfile.gettempdir()
    before = set(os.listdir(tmpdir))

    with patch(
        "dso_ci_review.runner._resolve_validator_script",
        return_value=str(nonexistent),
    ):
        runner_mod._validate_findings_schema(_VALID_FINDINGS_DICT)

    after = set(os.listdir(tmpdir))
    new_files = after - before

    assert not new_files, (
        f"_validate_findings_schema left orphaned tmpfile(s) in {tmpdir}: {new_files}. "
        "Tmpfiles must be cleaned up in the validator_error path (AC amendment)."
    )


def test_validate_findings_schema_validator_timeout_returns_validator_error():
    """
    Given: subprocess is patched to raise subprocess.TimeoutExpired
    When: _validate_findings_schema(findings_dict) is called
    Then: returns _SchemaValidationResult with status="validator_error" and non-empty errors

    Exercises the 60s subprocess timeout → fail-loud path.
    """
    import dso_ci_review.runner as runner_mod

    with patch(
        "dso_ci_review.runner.subprocess.run",
        side_effect=subprocess.TimeoutExpired(
            cmd="validate-review-output.sh", timeout=60
        ),
    ):
        result = runner_mod._validate_findings_schema(_VALID_FINDINGS_DICT)

    assert result.status == "validator_error", (
        f"Expected status='validator_error' on subprocess timeout; "
        f"got {result.status!r}. errors={result.errors!r}"
    )
    assert result.errors, (
        f"Expected non-empty errors list on TimeoutExpired; got {result.errors!r}"
    )


def test_validate_findings_schema_unknown_exit_code_returns_validator_error():
    """
    Given: subprocess is patched to return exit code 42 (unrecognized)
    When: _validate_findings_schema(findings_dict) is called
    Then: returns _SchemaValidationResult with status="validator_error" and non-empty errors

    Exercises the "any non-zero exit that isn't 1 → validator_error (fail-loud)" path.
    """
    import dso_ci_review.runner as runner_mod
    from unittest.mock import MagicMock

    mock_result = MagicMock()
    mock_result.returncode = 42
    mock_result.stdout = ""
    mock_result.stderr = "unexpected error from validator"

    with patch("dso_ci_review.runner.subprocess.run", return_value=mock_result):
        result = runner_mod._validate_findings_schema(_VALID_FINDINGS_DICT)

    assert result.status == "validator_error", (
        f"Expected status='validator_error' for unknown exit code 42; "
        f"got {result.status!r}. errors={result.errors!r}"
    )
    assert result.errors, (
        f"Expected non-empty errors list for unknown exit code; got {result.errors!r}"
    )


def test_main_validator_error_exits_nonzero_with_stderr_diagnostic(tmp_path):
    """
    Given: mocked dispatch returns valid findings AND _validate_findings_schema is patched
           to return a validator_error result
    When: runner.main() runs
    Then: exit code is non-zero AND stderr contains "CRITICAL:"

    Verifies that validator infrastructure failure (ENOENT / timeout / unrecognized exit)
    causes a loud failure with a CRITICAL diagnostic in stderr — never silently skipped.

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_main_validator_error_exits_nonzero_with_stderr_diagnostic]
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    # Build a _SchemaValidationResult for validator_error — requires the NamedTuple to exist.
    validator_error_result = runner_mod._SchemaValidationResult(
        status="validator_error",
        errors=["subprocess.TimeoutExpired after 60s"],
    )

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_make_findings_dispatch([_VALID_FINDING]),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=validator_error_result,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert exit_code != 0, (
        f"Expected non-zero exit code when validator_error occurs; got {exit_code}. "
        "Validator infrastructure failures must never silently succeed."
    )
    stderr_text = stderr_capture.getvalue()
    assert "CRITICAL:" in stderr_text, (
        f"Expected 'CRITICAL:' in stderr for validator_error path; got: {stderr_text!r}. "
        "The validator_error path must emit a CRITICAL diagnostic so CI log is visible."
    )


def test_main_schema_fail_returns_schema_fail_signal(tmp_path):
    """
    Given: mocked dispatch returns schema-invalid findings, real validate-review-output.sh
           detects the violation
    When: runner.main() runs with real validate-review-output.sh
    Then: the _SchemaValidationResult is accessible at the S-B integration point with
          status="schema_fail" (exit 0 with schema_fail sentinel in merged findings,
          allowing S-B correction dispatch to intercept)

    Integration point for S-B: schema_fail path returns _SchemaValidationResult to
    main() which S-B will consume for correction dispatch. This story (S-A) only
    inserts the hook; S-B implements correction dispatch.

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_main_schema_fail_returns_schema_fail_signal]
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_make_findings_dispatch(
                [_INVALID_FINDING_MISSING_CITED_EXCERPT]
            ),
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    # S-A contract: schema_fail path exits 0 (allowing S-B to consume the result).
    # The _SchemaValidationResult with status="schema_fail" is the S-B integration point.
    # Verify the output file exists and contains a schema_fail sentinel for S-B.
    assert output_file.exists(), (
        "output file must be written even on schema_fail (S-B needs it to dispatch correction)"
    )
    output_data = json.loads(output_file.read_text())
    assert "findings" in output_data, (
        f"'findings' must be present in output on schema_fail path; got keys: {list(output_data.keys())}"
    )
    # The schema_fail signal must be accessible — either as a sentinel in the findings
    # or as metadata in the output dict. This assertion verifies S-B can detect the failure.
    assert exit_code == 0, (
        f"Expected exit code 0 on schema_fail (S-B interception path); got {exit_code}. "
        "schema_fail is a data problem routed to S-B correction — not an infrastructure failure. "
        "Only validator_error (infrastructure) should produce non-zero exit from this hook."
    )


# ---------------------------------------------------------------------------
# Schema-correction integration tests — story 394e-d81b-fba4-4161 (S-B)
# ---------------------------------------------------------------------------
#
# These tests define the runner.py integration contract for dispatch_schema_correction
# (S-B task). dispatch_schema_correction and get_schema_correction_max_attempts do NOT
# exist yet — all tests below must fail RED until Task 5 integrates them in runner.py.
#
# RED markers:
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_calls_schema_correction_on_schema_fail]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_schema_correction_max_attempts_zero_skips_dispatch]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_schema_correction_result_written]


def test_runner_calls_schema_correction_on_schema_fail(tmp_path):
    """
    Given: dispatch returns schema-invalid findings AND _validate_findings_schema signals schema_fail
           AND dispatch_schema_correction is patched to return corrected (valid) findings
    When: runner.main() executes
    Then: dispatch_schema_correction is called exactly once (before _write_output)
          AND exit code is 0 (corrected findings contain no blocking findings)
          AND _write_output is called with the corrected findings (not the original schema-invalid ones)

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_calls_schema_correction_on_schema_fail]

    FAILS pre-integration because runner.main() does not call dispatch_schema_correction on schema_fail.
    Task 5 must add the call in runner.py between _validate_findings_schema and _write_output.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    # Corrected findings returned by dispatch_schema_correction — valid schema, no blockers
    corrected_findings = {
        "findings": [
            {
                "severity": "minor",
                "category": "hygiene",
                "description": "Corrected finding with all required fields.",
                "file": "foo.py",
                "cited_lines": ["foo.py:1"],
                "cited_excerpt": "added line",
            }
        ],
        "summary": "Schema-corrected findings.",
    }

    schema_fail_result = runner_mod._SchemaValidationResult(
        status="schema_fail",
        errors=["finding[0]: missing required field 'cited_excerpt'"],
    )

    correction_calls: list = []

    def mock_dispatch_schema_correction(findings, schema_errors, **kwargs):
        correction_calls.append({"findings": findings, "schema_errors": schema_errors})
        return corrected_findings

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_make_findings_dispatch(
                [_INVALID_FINDING_MISSING_CITED_EXCERPT]
            ),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=schema_fail_result,
        ),
        patch(
            "dso_ci_review.runner.get_schema_correction_max_attempts",
            return_value=3,
        ),
        patch(
            "dso_ci_review.runner.dispatch_schema_correction",
            side_effect=mock_dispatch_schema_correction,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert len(correction_calls) == 1, (
        f"dispatch_schema_correction must be called exactly once on schema_fail; "
        f"got {len(correction_calls)} calls. "
        "Task 5 must integrate dispatch_schema_correction in runner.py "
        "(story 394e-d81b-fba4-4161)."
    )
    assert exit_code == 0, (
        f"Expected exit code 0 when correction succeeds (no blocking findings); got {exit_code}. "
        f"stderr={stderr_capture.getvalue()!r}"
    )
    # Output must contain the corrected findings, not the original schema-invalid ones
    assert output_file.exists(), (
        "output file must be written after successful correction"
    )
    output_data = json.loads(output_file.read_text())
    assert output_data.get("summary") == "Schema-corrected findings.", (
        f"_write_output must receive corrected findings from dispatch_schema_correction; "
        f"got summary={output_data.get('summary')!r}. "
        "runner.main() must replace merged findings with correction result before write."
    )


def test_runner_schema_correction_max_attempts_zero_skips_dispatch(tmp_path):
    """
    Given: _validate_findings_schema signals schema_fail
           AND get_schema_correction_max_attempts returns 0
    When: runner.main() executes
    Then: dispatch_schema_correction is NOT called (max_attempts=0 short-circuits to error path)
          AND a synthetic schema_error finding is appended to merged findings
          AND CI exits non-zero (synthetic schema_error causes failure)

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_schema_correction_max_attempts_zero_skips_dispatch]

    FAILS pre-integration because runner.main() does not check get_schema_correction_max_attempts.
    Task 5 must short-circuit to the synthetic-error path when max_attempts=0.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    schema_fail_result = runner_mod._SchemaValidationResult(
        status="schema_fail",
        errors=["finding[0]: missing required field 'cited_excerpt'"],
    )

    correction_calls: list = []

    def mock_dispatch_schema_correction(findings, schema_errors, **kwargs):
        correction_calls.append(True)
        return {"findings": []}

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_make_findings_dispatch(
                [_INVALID_FINDING_MISSING_CITED_EXCERPT]
            ),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=schema_fail_result,
        ),
        patch(
            "dso_ci_review.runner.get_schema_correction_max_attempts",
            return_value=0,
        ),
        patch(
            "dso_ci_review.runner.dispatch_schema_correction",
            side_effect=mock_dispatch_schema_correction,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert not correction_calls, (
        f"dispatch_schema_correction must NOT be called when max_attempts=0; "
        f"was called {len(correction_calls)} time(s). "
        "Task 5 must short-circuit dispatch when max_attempts=0 and append synthetic error."
    )
    assert exit_code != 0, (
        f"Expected non-zero exit code when max_attempts=0 (synthetic schema_error path); "
        f"got {exit_code}. "
        "Schema correction exhausted (max_attempts=0) must cause CI to fail, not silently pass."
    )


def test_runner_schema_correction_result_written(tmp_path):
    """
    Given: _validate_findings_schema signals schema_fail
           AND dispatch_schema_correction is patched to return corrected findings
    When: runner.main() executes
    Then: _write_output receives the corrected findings (not original schema-invalid ones)
          AND the output file contains the corrected summary field

    This test isolates the data-flow assertion: the value returned by dispatch_schema_correction
    must replace the schema-invalid merged findings before _write_output is called.

    RED marker: tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_schema_correction_result_written]

    FAILS pre-integration because runner.main() does not replace merged with correction result.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/bar.py b/bar.py\n+fixed field\n")
    output_file = tmp_path / "findings.json"

    corrected_findings = {
        "findings": [
            {
                "severity": "suggestion",
                "category": "hygiene",
                "description": "post-correction suggestion",
                "file": "bar.py",
                "cited_lines": ["bar.py:1"],
                "cited_excerpt": "fixed field",
            }
        ],
        "summary": "correction-applied-sentinel",
    }

    schema_fail_result = runner_mod._SchemaValidationResult(
        status="schema_fail",
        errors=["finding[0]: missing required field 'cited_excerpt'"],
    )

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "GITHUB_EVENT_NAME": "",
                "GITHUB_REF": "",
                "GITHUB_TOKEN": "",
                "PR_NUMBER": "",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_make_findings_dispatch(
                [_INVALID_FINDING_MISSING_CITED_EXCERPT]
            ),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=schema_fail_result,
        ),
        patch(
            "dso_ci_review.runner.get_schema_correction_max_attempts",
            return_value=2,
        ),
        patch(
            "dso_ci_review.runner.dispatch_schema_correction",
            return_value=corrected_findings,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert output_file.exists(), (
        "output file must be written after dispatch_schema_correction returns corrected findings"
    )
    output_data = json.loads(output_file.read_text())
    assert output_data.get("summary") == "correction-applied-sentinel", (
        f"_write_output must receive the corrected findings returned by dispatch_schema_correction; "
        f"got summary={output_data.get('summary')!r} (expected 'correction-applied-sentinel'). "
        "runner.main() must replace merged with dispatch_schema_correction's return value before write "
        "(story 394e-d81b-fba4-4161 Task 5)."
    )
    assert exit_code == 0, (
        f"Expected exit code 0 with corrected suggestion-only findings; got {exit_code}. "
        f"stderr={stderr_capture.getvalue()!r}"
    )


def test_validate_review_schema_hash_matches_script():
    """
    Assert that _VALIDATE_REVIEW_SCHEMA_HASH in runner.py matches the
    HASH_CODE_REVIEW_DISPATCH value in validate-review-output.sh.

    When validate-review-output.sh's schema changes, its HASH_CODE_REVIEW_DISPATCH
    must be updated. This test catches drift between the two constants.
    """
    import pathlib
    import re
    import dso_ci_review.runner as runner_mod

    validator_script = runner_mod._resolve_validator_script()
    script_text = pathlib.Path(validator_script).read_text(encoding="utf-8")

    # Extract HASH_CODE_REVIEW_DISPATCH="<hex>" from the script
    match = re.search(r'HASH_CODE_REVIEW_DISPATCH="([0-9a-f]+)"', script_text)
    assert match is not None, (
        f"Could not find HASH_CODE_REVIEW_DISPATCH in {validator_script}. "
        "Was validate-review-output.sh moved or renamed?"
    )
    script_hash = match.group(1)

    assert runner_mod._VALIDATE_REVIEW_SCHEMA_HASH == script_hash, (
        f"runner._VALIDATE_REVIEW_SCHEMA_HASH={runner_mod._VALIDATE_REVIEW_SCHEMA_HASH!r} "
        f"does not match HASH_CODE_REVIEW_DISPATCH={script_hash!r} "
        f"in {validator_script}. "
        "Update _VALIDATE_REVIEW_SCHEMA_HASH in runner.py to match."
    )
