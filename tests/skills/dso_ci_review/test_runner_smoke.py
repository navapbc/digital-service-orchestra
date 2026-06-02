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
import os
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


def test_runner_config_error_exits_4(fixture_diff_path, tmp_path):
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

    assert result.returncode == 4, (
        f"Expected exit code 4 (R4: provider ConfigError is an infrastructure "
        f"failure), got {result.returncode}.\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )
    assert "ERROR: provider" in result.stderr, (
        f"Expected 'ERROR: provider ...' in stderr, got: {result.stderr!r}"
    )


def test_runner_auth_error_exits_4(fixture_diff_path, tmp_path):
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

    assert result.returncode == 4, (
        f"Expected exit code 4 (R4: provider AuthError is an infrastructure "
        f"failure), got {result.returncode}.\n"
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

    async def mock_dispatch(agents, **kwargs):
        captured_agents.extend(agents)
        return specialist_findings

    # Isolate cycle-ledger state per test (mirrors _run_main_with). Without
    # this, the shared /tmp/workflow-plugin-<hash>/cycle-ledger.json
    # accumulates cycles across runs and the novelty gate downgrades the
    # important finding to suggestion on cycle >= 2.
    _artifacts_isolation_dir = str(tmp_path / "artifacts")
    os.makedirs(_artifacts_isolation_dir, exist_ok=True)

    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "WORKFLOW_PLUGIN_ARTIFACTS_DIR": _artifacts_isolation_dir,
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result
        ) as mock_classify,
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch
        ),
        patch(
            "dso_ci_review.runner.cycle_next_action",
            return_value={
                "action": "DISPATCH_NEXT",
                "reason": "smoke-test stub",
                "cycle_num": 1,
            },
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

    async def mock_dispatch(agents, **kwargs):
        captured_agents.extend(agents)
        return [correctness_findings, verification_findings, hygiene_findings]

    # Isolate cycle-ledger state per test (mirrors _run_main_with). Without
    # this, the shared /tmp/workflow-plugin-<hash>/cycle-ledger.json
    # accumulates cycles across runs and the novelty gate downgrades the
    # critical/important findings to suggestion on cycle >= 2.
    _artifacts_isolation_dir = str(tmp_path / "artifacts")
    os.makedirs(_artifacts_isolation_dir, exist_ok=True)

    # Mock the deep-tier arch synthesis so the real LLM call doesn't fire.
    # Return the merged specialist output (findings + scores) unchanged so
    # the severity gate sees what the specialists produced.
    # bug 7f55 / f148 follow-up: runner now sends the SONNET-A/B/C marker
    # format (required by code-reviewer-deep-arch's Sonnet Findings Guard).
    # That format intentionally drops scores (the agent contract is about
    # the three finding markers, not metadata). To passthrough scores in
    # the test we side-channel the original merged dict via a wrapper
    # around _format_merged_for_arch that captures it.
    _captured_merged: dict = {}
    _real_format = runner_mod._format_merged_for_arch

    def _capture_then_format(merged: dict) -> str:
        _captured_merged.clear()
        _captured_merged.update(merged)
        return _real_format(merged)

    def _arch_synth_passthrough(merged_json, **_kwargs):
        return dict(_captured_merged) if _captured_merged else (
            json.loads(merged_json) if isinstance(merged_json, str) else merged_json
        )

    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "WORKFLOW_PLUGIN_ARTIFACTS_DIR": _artifacts_isolation_dir,
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
            },
        ),
        patch("dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch
        ),
        patch(
            "dso_ci_review.runner._format_merged_for_arch",
            side_effect=_capture_then_format,
        ),
        patch(
            "dso_ci_review.runner.dispatch_arch_synthesis",
            side_effect=_arch_synth_passthrough,
        ),
        patch(
            "dso_ci_review.runner.cycle_next_action",
            return_value={
                "action": "DISPATCH_NEXT",
                "reason": "smoke-test stub",
                "cycle_num": 1,
            },
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


def test_runner_exits_4_when_all_specialists_fail(tmp_path):
    """
    Given: all specialists return specialist_error findings (e.g. ModuleNotFoundError)
    When: runner.main() is called in-process
    Then: exit code is 4 (infrastructure failure per R4) and stderr contains
          a message about specialist failure.

    R4 (PR-C) reframes this gate: an all-specialist-failure outcome is an
    infrastructure failure, not "review found problems". Exit code 4 lets
    the CI workflow's classify step annotate the run accordingly. Config-
    gated via DSO_INFRA_EXIT_CODE_ENABLED for clean rollback.

    Covers fcea-6e83 (the original requirement that the runner must NOT
    exit 0 when every specialist fails — exit 4 still satisfies that, and
    additionally gives operators the right signal).
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

    async def mock_dispatch(agents, **kwargs):
        return all_error_findings

    stderr_capture = io.StringIO()
    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                # Pin to defeat ambient-state flakiness (CodeRabbit PR #455).
                "DSO_INFRA_EXIT_CODE_ENABLED": "1",
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

    assert exit_code == 4, (
        f"Expected exit code 4 when all specialists fail (R4 infrastructure "
        f"failure), got {exit_code}. runner.main() must detect "
        "all-specialist-error and return 4 (PR-C R4). Legacy rollback "
        "behavior (exit 1) is gated behind DSO_INFRA_EXIT_CODE_ENABLED=0."
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

    Covers c86e-e177 Fix C: tier-appropriate models read from dso config, matching
    local review tiers (haiku=light, sonnet=standard/deep). Not hardcoded.
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "model.light=claude-haiku-4-5\n"
        "model.standard=claude-sonnet-4-6\n"
        "model.deep=claude-opus-4-7\n"
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
    Given: dso-config.conf sets model.light=claude-haiku-4-5
    When: _build_agents_for_tier("light", ...) is called with that config path
    Then: the agent model is claude-haiku-4-5

    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "model.light=claude-haiku-4-5\n"
        "model.standard=claude-sonnet-4-6\n"
        "model.deep=claude-opus-4-7\n"
    )

    agents = runner_mod._build_agents_for_tier(
        "light", "diff text", {}, config_path=str(config_file)
    )
    assert len(agents) == 1
    assert agents[0]["model"] == "claude-haiku-4-5"


def test_build_agents_for_tier_reads_deep_model_from_config(tmp_path):
    """
    Given: dso-config.conf sets model.deep=claude-opus-4-7
    When: _build_agents_for_tier("deep", ...) is called with that config path
    Then: all three deep agents use claude-opus-4-7

    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text(
        "model.light=claude-haiku-4-5\n"
        "model.standard=claude-sonnet-4-6\n"
        "model.deep=claude-opus-4-7\n"
    )

    agents = runner_mod._build_agents_for_tier(
        "deep", "diff text", {}, config_path=str(config_file)
    )
    assert len(agents) == 3
    for agent in agents:
        assert agent["model"] == "claude-opus-4-7", (
            f"deep tier agent {agent['agent_id']!r} should use claude-opus-4-7; "
            f"got {agent['model']!r}"
        )


def test_build_agents_for_tier_falls_back_to_tier_defaults_when_config_absent(tmp_path):
    """
    Given: a config file that does NOT set model.standard
    When: _build_agents_for_tier("standard", ...) is called with that config path
    Then: the agent uses the hardcoded tier default for standard (sonnet), not haiku

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
    assert agents[0]["model"] != "claude-haiku-4-5", (
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

    async def mock_dispatch(agents, **kwargs):
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
                # Pin to defeat ambient-state flakiness (CodeRabbit PR #455).
                "DSO_INFRA_EXIT_CODE_ENABLED": "1",
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

    assert exit_code == 4, (
        f"Expected exit code 4 (R4 infrastructure failure for all-synthetic "
        f"findings), got {exit_code}. stderr: {stderr_capture.getvalue()!r}. "
        "Legacy exit 1 is rollback-gated via DSO_INFRA_EXIT_CODE_ENABLED=0."
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

    async def mock_dispatch(agents, **kwargs):
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

    # Isolate cycle ledger / arbiter sidecar state per test by pointing
    # WORKFLOW_PLUGIN_ARTIFACTS_DIR at a per-test tmp subdir. Without this,
    # the runner's _init_cycle_ledger resolves to the global /tmp/workflow-plugin-*
    # path and accumulates cycle_num across test invocations — eventually
    # triggering the cycle>=2 novelty gate and downgrading critical findings
    # the smoke tests expect to remain critical.
    _artifacts_isolation_dir = str(diff_path.parent / "artifacts")
    import os as _os  # noqa: PLC0415

    _os.makedirs(_artifacts_isolation_dir, exist_ok=True)

    env = {
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_path),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_path),
        "WORKFLOW_PLUGIN_ARTIFACTS_DIR": _artifacts_isolation_dir,
        "CI_REVIEW_PROVIDER": "anthropic",
        "ANTHROPIC_API_KEY": "test-key",
        # Suppress real GitHub Actions env that would otherwise leak in via
        # patch.dict(clear=False) and trigger an unintended `gh pr comment`
        # subprocess call when these tests run inside a CI job. Tests that
        # need the PR-event path opt in via env_extra below.
        "GITHUB_EVENT_NAME": "",
        "GITHUB_REF": "",
        "GITHUB_TOKEN": "",
        "GITHUB_SHA": "",
        "PR_NUMBER": "",
    }
    if env_extra:
        env.update(env_extra)

    stderr_capture = io.StringIO()
    _schema_pass = runner_mod._SchemaValidationResult(status="schema_pass", errors=[])

    # Force the cycle dispatcher to choose DISPATCH_NEXT so the smoke tests
    # exercise the normal severity-gate + _post_pr_review flow rather than the
    # arbiter branch. The runner calls cycle_next_action a second time AFTER
    # _append_cycle, which makes the Jaccard self-comparison always halt; the
    # stub here keeps the smoke-test surface focused on the runner's normal
    # output path. (The dedicated cycle2 tests below mock _init_cycle_ledger
    # and exercise the arbiter/defense paths separately.)
    def _cycle_next_action_dispatch_next(*_args, **_kwargs):
        return {"action": "DISPATCH_NEXT", "reason": "smoke-test stub", "cycle_num": 1}

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
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=_schema_pass,
        ),
        patch(
            "dso_ci_review.runner.cycle_next_action",
            side_effect=_cycle_next_action_dispatch_next,
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
    """Blocking findings must be posted via the GitHub Pulls Reviews API as resolvable threads.

    Bug 59e3-8b8b fix: findings with cited_lines are now posted as a batched PR review
    (gh api -X POST .../pulls/{n}/reviews) instead of individual issue comments.
    Uses GITHUB_SHA + GITHUB_REPOSITORY + GITHUB_EVENT_NAME=pull_request to simulate
    PR context with head SHA available.
    """
    import dso_ci_review.runner as runner_mod
    import json as _json

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
    captured_inputs = []

    def _capture_run(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        captured_inputs.append(kwargs.get("input", ""))
        from subprocess import CompletedProcess

        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/123/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_SHA": "deadbeef1234",
    }

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _capture_run
        # Real exception types so the runner's `except` clauses match by identity
        # if the stub ever raises (currently it doesn't).
        import subprocess as _real_subprocess

        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [c for c in captured_calls if isinstance(c, list) and c and c[0] == "gh"]
    reviews_api_calls = [
        c for c in gh_calls if "api" in c and "/reviews" in " ".join(str(x) for x in c)
    ]

    def _is_cycle_marker_comment(cmd: list) -> bool:
        """Return True when cmd is a 'gh pr comment' carrying a DSO-Review-Cycle marker body
        (cycle ledger infrastructure, not finding comments).
        """
        # The body is passed as a positional arg after '--body': ["gh", "pr", "comment", <pr>, "--body", <body>]
        try:
            body_idx = cmd.index("--body") + 1
            body = str(cmd[body_idx])
            return body.startswith("DSO-Review-Cycle:")
        except (ValueError, IndexError):
            return False

    # Exclude DSO-Review-Cycle marker comments (cycle ledger infrastructure, not finding comments).
    issue_comment_calls = [
        c
        for c in gh_calls
        if "pr" in c and "comment" in c and not _is_cycle_marker_comment(c)
    ]

    assert len(reviews_api_calls) == 1, (
        f"Expected 1 Reviews API call (batched); got {len(reviews_api_calls)}: {reviews_api_calls!r}"
    )
    assert not issue_comment_calls, (
        f"Anchored findings must NOT use gh pr comment; got: {issue_comment_calls!r}"
    )

    reviews_call_idx = next(
        i for i, c in enumerate(captured_calls) if c in reviews_api_calls
    )
    body = _json.loads(captured_inputs[reviews_call_idx])
    assert len(body.get("comments", [])) == len(findings), (
        f"Reviews API body must contain {len(findings)} comments; got {body.get('comments')!r}"
    )
    for i, comment in enumerate(body["comments"], 1):
        assert f"finding {i}/{len(findings)}" in comment.get("body", ""), (
            f"Comment {i} body missing the finding-index marker; got: {comment.get('body')!r:.200}"
        )


def test_runner_partial_post_failure_continues_remaining_findings(tmp_path):
    """When the Reviews API call fails, the runner falls back and posts all findings as issue comments.

    Bug 59e3-8b8b fix: if `gh api .../reviews` returns a non-zero exit code (e.g., 422
    from GitHub rejecting a path not in the diff), the runner catches the error and
    re-routes ALL findings to individual issue comments — none are dropped.
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
            "description": "second finding",
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

    def _reviews_api_fails(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        from subprocess import CalledProcessError, CompletedProcess

        # Make the Reviews API call fail (simulate 422 / path not in diff)
        if (
            isinstance(cmd, list)
            and "api" in cmd
            and "/reviews" in " ".join(str(x) for x in cmd)
        ):
            raise CalledProcessError(
                returncode=1, cmd=cmd, output="", stderr="422 Unprocessable Entity"
            )
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/123/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_SHA": "abcdef1234",
    }

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        import subprocess as _real_subprocess

        mock_subprocess.run.side_effect = _reviews_api_fails
        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [c for c in captured_calls if isinstance(c, list) and c and c[0] == "gh"]
    reviews_api_calls = [
        c for c in gh_calls if "api" in c and "/reviews" in " ".join(str(x) for x in c)
    ]

    def _is_cycle_marker(cmd: list) -> bool:
        try:
            body_idx = cmd.index("--body") + 1
            body = str(cmd[body_idx])
            return body.startswith("DSO-Review-Cycle:")
        except (ValueError, IndexError):
            return False

    # Exclude DSO-Review-Cycle marker comments (cycle ledger infrastructure).
    issue_comment_calls = [
        c for c in gh_calls if "pr" in c and "comment" in c and not _is_cycle_marker(c)
    ]

    assert len(reviews_api_calls) == 1, (
        f"Expected 1 Reviews API attempt (which fails); got {reviews_api_calls!r}"
    )
    assert len(issue_comment_calls) == 3, (
        f"Expected 3 fallback issue comment posts after Reviews API failure; "
        f"got {len(issue_comment_calls)}: {issue_comment_calls!r}"
    )


def test_post_pr_review_uses_reviews_api_for_anchored_findings(tmp_path):
    """Findings with cited_lines must be posted via the GitHub Pulls Reviews API, not issue comments.

    Bug 59e3-8b8b: _post_pr_review used gh pr comment (Issues API), so findings
    never became resolvable review threads. With the fix, a single gh api -X POST
    .../pulls/{n}/reviews call with a comments[] payload replaces the per-finding
    gh pr comment calls for anchored findings.
    """
    import dso_ci_review.runner as runner_mod

    findings = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "fix A",
            "cited_lines": ["foo.py:1"],
        },
        {
            "severity": "fragile",
            "category": "correctness",
            "description": "fix B",
            "cited_lines": ["foo.py:7"],
        },
        {
            "severity": "critical",
            "category": "correctness",
            "description": "fix C",
            "cited_lines": ["foo.py:12"],
        },
    ]
    captured_calls = []
    captured_inputs = []

    def _capture_run(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        captured_inputs.append(kwargs.get("input", ""))
        from subprocess import CompletedProcess

        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/123/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_SHA": "abc123headsha",
    }

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+x\n")
    out = tmp_path / "out.json"

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _capture_run
        import subprocess as _real_subprocess

        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [c for c in captured_calls if isinstance(c, list) and c and c[0] == "gh"]
    reviews_api_calls = [
        c for c in gh_calls if "api" in c and "/reviews" in " ".join(str(x) for x in c)
    ]

    def _is_cycle_marker(cmd):
        try:
            body = str(cmd[cmd.index("--body") + 1])
            return body.startswith("DSO-Review-Cycle:")
        except (ValueError, IndexError):
            return False

    issue_comment_calls = [
        c for c in gh_calls if "pr" in c and "comment" in c and not _is_cycle_marker(c)
    ]

    assert len(reviews_api_calls) == 1, (
        f"Expected exactly 1 Reviews API call for 3 anchored findings; "
        f"got {len(reviews_api_calls)} reviews_api and {len(issue_comment_calls)} issue_comment calls. "
        f"All gh calls: {gh_calls!r}"
    )
    assert not issue_comment_calls, (
        f"Anchored findings must use Reviews API, not issue comments; "
        f"got {len(issue_comment_calls)} gh pr comment calls: {issue_comment_calls!r}"
    )

    # Verify the reviews API body has all 3 comments
    reviews_call_idx = next(
        i for i, c in enumerate(captured_calls) if c in reviews_api_calls
    )
    body_json = captured_inputs[reviews_call_idx]
    import json as _json

    body = _json.loads(body_json)
    assert body.get("commit_id") == "abc123headsha", f"commit_id mismatch: {body!r}"
    assert body.get("event") == "COMMENT", f"event mismatch: {body!r}"
    assert len(body.get("comments", [])) == 3, (
        f"Expected 3 review comments; got {body.get('comments')!r}"
    )
    # Each comment must have path, line, side, body
    for i, comment in enumerate(body["comments"]):
        assert "path" in comment, f"comment[{i}] missing path: {comment!r}"
        assert "line" in comment, f"comment[{i}] missing line: {comment!r}"
        assert comment.get("side") == "RIGHT", (
            f"comment[{i}] side must be RIGHT: {comment!r}"
        )
        assert f"finding {i + 1}/3" in comment.get("body", ""), (
            f"comment[{i}] body missing finding index marker: {comment.get('body')!r:.200}"
        )


def test_post_pr_review_surfaces_gh_stderr_when_reviews_api_fails(tmp_path):
    """When the Reviews API call fails, the warning MUST include gh's stderr
    so operators can diagnose the underlying cause (e.g. 422 'Commit SHA is
    not in the pull request' from a mid-cycle push superseding head_sha).
    Earlier behavior only emitted `type(exc).__name__` — the GitHub API
    rejection text was discarded with the exception, leaving operators with
    "Reviews API failed" and no path to root cause.
    """
    import subprocess as _real_subprocess

    import dso_ci_review.runner as runner_mod

    gh_stderr_payload = (
        '{"message":"Validation Failed","errors":[{"resource":"PullRequestReview",'
        '"code":"custom","message":"Commit SHA is not in the pull request"}],'
        '"documentation_url":"https://docs.github.com/rest/pulls/reviews"}'
    )

    findings = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "fix A",
            "cited_lines": ["foo.py:1"],
        }
    ]

    issue_comment_call_count = {"n": 0}

    def _fake_run(cmd, *args, **kwargs):
        if "api" in cmd and "/reviews" in " ".join(str(x) for x in cmd):
            raise _real_subprocess.CalledProcessError(
                returncode=1, cmd=cmd, output="", stderr=gh_stderr_payload
            )
        if "pr" in cmd and "comment" in cmd:
            issue_comment_call_count["n"] += 1
        return _real_subprocess.CompletedProcess(
            args=cmd, returncode=0, stdout="", stderr=""
        )

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/123/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_SHA": "abc123headsha",
    }

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+x\n")
    out = tmp_path / "out.json"

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _fake_run
        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _, stderr_text = _run_main_with(
            diff_file, out, findings, env_extra=env_extra
        )

    assert "Reviews API failed" in stderr_text, (
        f"Expected fallback warning. Got:\n{stderr_text}"
    )
    assert "gh stderr:" in stderr_text, (
        "Warning must include 'gh stderr:' prefix so operators can grep for "
        f"diagnostic context. Got:\n{stderr_text}"
    )
    assert "Commit SHA is not in the pull request" in stderr_text, (
        "The actual gh stderr payload (containing the GitHub error message) "
        f"must appear in the warning text. Got:\n{stderr_text}"
    )
    assert issue_comment_call_count["n"] >= 1, (
        "Anchored finding must be re-routed to issue comment after Reviews "
        "API failure; got 0 fallback gh pr comment calls."
    )


def test_post_pr_review_surfaces_gh_stderr_when_issue_comment_fails(tmp_path):
    """The issue-comment fallback loop's failure warning must include gh's
    stderr, same rationale as the Reviews-API branch. When token lacks
    pull-requests:write or hits a rate limit, the loop fires once per
    finding; without the underlying gh message operators get N opaque
    warnings with no diagnostic path.
    """
    import subprocess as _real_subprocess

    import dso_ci_review.runner as runner_mod

    gh_stderr_payload = (
        '{"message":"Resource not accessible by integration",'
        '"documentation_url":"https://docs.github.com/rest/issues/comments"}'
    )

    # Use unanchored findings (no cited_lines) so they route directly to the
    # issue-comment loop — the Reviews-API branch is bypassed for these.
    findings = [
        {"severity": "important", "category": "correctness", "description": "fix A"},
        {"severity": "critical", "category": "correctness", "description": "fix B"},
    ]

    issue_comment_attempts = {"n": 0}

    def _fake_run(cmd, *args, **kwargs):
        if "pr" in cmd and "comment" in cmd:
            # _post_cycle_marker_comment also uses `gh pr comment`; skip the
            # cycle marker body (it does not start with "[critical]" or
            # "[important]") and only fail real finding posts.
            body = ""
            try:
                body = str(cmd[cmd.index("--body") + 1])
            except (ValueError, IndexError):
                pass
            if body.startswith("DSO-Review-Cycle:"):
                return _real_subprocess.CompletedProcess(
                    args=cmd, returncode=0, stdout="", stderr=""
                )
            issue_comment_attempts["n"] += 1
            raise _real_subprocess.CalledProcessError(
                returncode=1, cmd=cmd, output="", stderr=gh_stderr_payload
            )
        return _real_subprocess.CompletedProcess(
            args=cmd, returncode=0, stdout="", stderr=""
        )

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/123/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_SHA": "abc123headsha",
    }

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+x\n")
    out = tmp_path / "out.json"

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _fake_run
        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _, stderr_text = _run_main_with(
            diff_file, out, findings, env_extra=env_extra
        )

    assert "failed to post PR comment for finding" in stderr_text, (
        f"Expected per-finding fallback warning. Got:\n{stderr_text}"
    )
    assert "gh stderr:" in stderr_text, (
        "Per-finding warning must include 'gh stderr:' prefix. "
        f"Got:\n{stderr_text}"
    )
    assert "Resource not accessible by integration" in stderr_text, (
        "The actual gh stderr payload must appear in the warning. "
        f"Got:\n{stderr_text}"
    )


def test_post_pr_review_falls_back_to_issue_comment_for_unanchorable(tmp_path):
    """Findings with no cited_lines anchor fall back to issue comments; anchored ones use Reviews API.

    Bug 59e3-8b8b: verify mixed findings (one anchored, one unanchored) produce
    exactly 1 Reviews API call (anchored) + 1 issue comment (unanchored).
    """
    import dso_ci_review.runner as runner_mod

    findings = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "anchored",
            "cited_lines": ["bar.py:5"],
        },
        {
            "severity": "important",
            "category": "correctness",
            "description": "no anchor",
            "cited_lines": [],
        },
    ]
    captured_calls = []
    captured_inputs = []

    def _capture_run(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        captured_inputs.append(kwargs.get("input", ""))
        from subprocess import CompletedProcess

        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/99/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_SHA": "deadbeef",
    }

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/bar.py b/bar.py\n+x\n")
    out = tmp_path / "out.json"

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _capture_run
        import subprocess as _real_subprocess

        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [c for c in captured_calls if isinstance(c, list) and c and c[0] == "gh"]
    reviews_api_calls = [
        c for c in gh_calls if "api" in c and "/reviews" in " ".join(str(x) for x in c)
    ]

    def _is_cycle_marker(cmd):
        try:
            body = str(cmd[cmd.index("--body") + 1])
            return body.startswith("DSO-Review-Cycle:")
        except (ValueError, IndexError):
            return False

    issue_comment_calls = [
        c for c in gh_calls if "pr" in c and "comment" in c and not _is_cycle_marker(c)
    ]

    assert len(reviews_api_calls) == 1, (
        f"Expected 1 Reviews API call for anchored finding; got {reviews_api_calls!r}"
    )
    assert len(issue_comment_calls) == 1, (
        f"Expected 1 issue comment call for unanchored finding; got {issue_comment_calls!r}"
    )


def test_post_pr_review_falls_back_when_head_sha_unresolvable(tmp_path):
    """When GITHUB_SHA is absent and gh pr view headRefOid returns empty, all findings fall back to issue comments.

    Bug 59e3-8b8b: graceful degradation — if the HEAD SHA cannot be resolved,
    the runner must still post all findings (as issue comments) rather than dropping them.
    """
    import dso_ci_review.runner as runner_mod

    findings = [
        {
            "severity": "important",
            "category": "correctness",
            "description": "finding 1",
            "cited_lines": ["a.py:10"],
        },
        {
            "severity": "important",
            "category": "correctness",
            "description": "finding 2",
            "cited_lines": ["b.py:20"],
        },
    ]
    captured_calls = []

    def _capture_run(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        from subprocess import CompletedProcess

        # Return empty stdout for headRefOid lookup
        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/77/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
        # GITHUB_SHA intentionally absent
    }

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/a.py b/a.py\n+x\n")
    out = tmp_path / "out.json"

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _capture_run
        import subprocess as _real_subprocess

        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [c for c in captured_calls if isinstance(c, list) and c and c[0] == "gh"]
    reviews_api_calls = [
        c for c in gh_calls if "api" in c and "/reviews" in " ".join(str(x) for x in c)
    ]

    def _is_cycle_marker(cmd):
        try:
            body = str(cmd[cmd.index("--body") + 1])
            return body.startswith("DSO-Review-Cycle:")
        except (ValueError, IndexError):
            return False

    issue_comment_calls = [
        c for c in gh_calls if "pr" in c and "comment" in c and not _is_cycle_marker(c)
    ]

    assert not reviews_api_calls, (
        f"Must NOT call Reviews API when HEAD SHA is unresolvable; got: {reviews_api_calls!r}"
    )
    assert len(issue_comment_calls) == 2, (
        f"Expected 2 issue comment fallback calls; got {len(issue_comment_calls)}: {issue_comment_calls!r}"
    )


def test_post_pr_review_handles_range_cited_lines(tmp_path):
    """A cited_lines range like 'path:10-25' must anchor to the start line (10).

    Bug 59e3-8b8b: verify the anchor extractor parses ranges correctly so the
    Reviews API comment lands at the right line.
    """
    import dso_ci_review.runner as runner_mod
    import json as _json

    findings = [
        {
            "severity": "critical",
            "category": "correctness",
            "description": "range anchor",
            "cited_lines": ["src/util.py:10-25"],
        }
    ]
    captured_calls = []
    captured_inputs = []

    def _capture_run(cmd, *args, **kwargs):
        captured_calls.append(cmd)
        captured_inputs.append(kwargs.get("input", ""))
        from subprocess import CompletedProcess

        return CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

    env_extra = {
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/5/merge",
        "GITHUB_TOKEN": "token-stub",
        "GITHUB_REPOSITORY": "owner/repo",
        "GITHUB_SHA": "cafebabe",
    }

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/src/util.py b/src/util.py\n+x\n")
    out = tmp_path / "out.json"

    with patch.object(runner_mod, "subprocess", create=True) as mock_subprocess:
        mock_subprocess.run.side_effect = _capture_run
        import subprocess as _real_subprocess

        mock_subprocess.CalledProcessError = _real_subprocess.CalledProcessError
        mock_subprocess.TimeoutExpired = _real_subprocess.TimeoutExpired
        _run_main_with(diff_file, out, findings, env_extra=env_extra)

    gh_calls = [c for c in captured_calls if isinstance(c, list) and c and c[0] == "gh"]
    reviews_api_calls = [
        c for c in gh_calls if "api" in c and "/reviews" in " ".join(str(x) for x in c)
    ]

    assert len(reviews_api_calls) == 1, (
        f"Expected 1 Reviews API call; got {reviews_api_calls!r}"
    )
    reviews_call_idx = next(
        i for i, c in enumerate(captured_calls) if c in reviews_api_calls
    )
    body = _json.loads(captured_inputs[reviews_call_idx])
    comment = body["comments"][0]
    assert comment["path"] == "src/util.py", f"path mismatch: {comment!r}"
    assert comment["line"] == 10, (
        f"Expected start line 10 for range 10-25; got {comment['line']}"
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


def test_runner_calls_dispatch_verifier(tmp_path) -> None:
    """dispatch_verifier must be called once per review run with the merged findings."""
    findings_path = tmp_path / "findings.json"
    diff = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n"
    diff_file = tmp_path / "diff.txt"
    diff_file.write_text(diff)

    mock_findings = [
        {
            "finding_id": "f-001",
            "severity": "important",
            "description": "does not exist",
            "file": "foo.py",
            "cited_lines": ["foo.py:1"],
            "cited_excerpt": "x = 1",
            "category": "correctness",
            "reachability": "reachable",
            "verification_evidence": {"command": "grep x foo.py", "output": ""},
        }
    ]

    with (
        patch("dso_ci_review.runner.async_dispatch_specialists") as mock_dispatch,
        patch("dso_ci_review.runner._classify_tier_via_bash") as mock_tier,
        patch("dso_ci_review.runner._validate_findings_schema") as mock_schema,
        patch("dso_ci_review.verifier.dispatch_verifier") as mock_verifier,
    ):
        mock_tier.return_value = {
            "selected_tier": "standard",
            "file_count": 1,
            "loc_count": 1,
            "is_merge_commit": False,
            "overlay_flags": {},
        }
        mock_dispatch.return_value = [{"findings": mock_findings}]
        mock_schema.return_value = type(
            "_SR", (), {"status": "schema_pass", "errors": []}
        )()
        mock_verifier.return_value = mock_findings  # pass through unchanged

        from dso_ci_review.runner import main

        with (
            patch.dict(
                "os.environ",
                {
                    "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                    "DSO_CI_REVIEW_OUTPUT_PATH": str(findings_path),
                    "CI_REVIEW_PROVIDER": "anthropic",
                },
            ),
            patch("dso_ci_review.runner.get_provider"),
        ):
            main()

    mock_verifier.assert_called_once()


def test_build_agents_for_tier_includes_tier_in_agent_dicts(tmp_path):
    """_build_agents_for_tier must set 'tier' on every agent dict it returns.

    async_dispatch_specialists reads agent['tier'] to pass to dispatch_review,
    so light-tier dispatch correctly skips the augmentation loop in production.
    Without this field, a.get('tier', 'standard') defaults to 'standard', enabling
    the loop for all tiers including light.
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("model.light=claude-haiku-4-5\n")

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
                model="claude-haiku-4-5",
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

#   tests/skills/dso_ci_review/test_runner_smoke.py [test_runner_uses_bash_classifier]
#
# Task 6430-6a72: assert runner.py calls _classify_tier_via_bash helper
# (the bash subprocess wrapper) instead of the Python classify_tier function.


def test_runner_uses_bash_classifier(tmp_path):
    """
    Given: a non-empty diff and mocked _classify_tier_via_bash + async_dispatch_specialists
    When: runner.main() is called in-process
    Then: _classify_tier_via_bash is called once with the diff text argument

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

    async def mock_dispatch(agents, **kwargs):
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

    async def mock_dispatch(agents, **kwargs):
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

    async def mock_dispatch(agents, **kwargs):
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

    async def mock_dispatch(agents, **kwargs):
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
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
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

    Given: cycle 2 (ledger-based fixture via _init_cycle_ledger mock),
           GITHUB_EVENT_NAME=pull_request, PR has a DEFENSE_RECORD for a critical finding,
           and the LLM re-emits the same critical finding verbatim
    When: runner.main() executes
    Then: the re-emitted finding is downgraded to 'suggestion' (not blocking)
          AND exit code is 0 (no blocking findings remain)

    Mocking strategy (classification-a ledger migration — task 36cf audit):
    - _init_cycle_ledger patched to return 2 (ledger-based fixture; task 36cf will replace
      the env-var body with ledger logic, but the mock point is identical).
    - DSO_REVIEW_CYCLE=2 is kept in env as a belt-and-suspenders guard for the
      current env-var implementation path; remove it once task 36cf lands.
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
                # DSO_REVIEW_CYCLE kept for current env-var implementation;
                # remove after task 36cf replaces _init_cycle_ledger body.
                "DSO_REVIEW_CYCLE": "2",
                "GITHUB_EVENT_NAME": "pull_request",
                "GITHUB_REF": "refs/pull/77/merge",
                "GITHUB_TOKEN": "test-token",
            },
        ),
        # Ledger-based fixture: mock _init_cycle_ledger to return cycle 2.
        # Task 36cf replaces the env-var body; the mock point is now stable.
        patch(
            "dso_ci_review.runner._init_cycle_ledger", return_value=({"cycles": []}, 2)
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_standard_tier_classification(),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
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

    Given: cycle 2 (ledger-based fixture via _init_cycle_ledger mock), deep tier,
           one prior defense, 3 specialist results where
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
                "relation": "RESUSTAIN_OF",
            },
            {
                "severity": "important",
                "description": "real correctness issue in handler",
                "cited_lines": ["auth/handler.py:1"],
                "relation": "RESUSTAIN_OF",
            },
        ],
        "scores": {"correctness": 2, "verification": 3},
        "summary": "Arch synthesis: partial failure, real findings remain.",
    }

    captured_synthesis_calls: list[str] = []

    async def mock_dispatch(agents, **kwargs):
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
                # DSO_REVIEW_CYCLE kept for current env-var implementation;
                # remove after task 36cf replaces _init_cycle_ledger body.
                "DSO_REVIEW_CYCLE": "2",
                "GITHUB_EVENT_NAME": "pull_request",
                "GITHUB_REF": "refs/pull/99/merge",
                "GITHUB_TOKEN": "test-token",
            },
        ),
        # Ledger-based fixture: mock _init_cycle_ledger to return cycle 2.
        # Task 36cf replaces the env-var body; the mock point is now stable.
        patch(
            "dso_ci_review.runner._init_cycle_ledger", return_value=({"cycles": []}, 2)
        ),
        patch("dso_ci_review.runner._classify_tier_via_bash", return_value=tier_result),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
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

    Given: cycle 1 (_init_cycle_ledger returns 1 by default; DSO_REVIEW_CYCLE absent),
           an important finding from the LLM
    When: runner.main() executes
    Then: exit code is 1 (important finding blocks)
          AND no defense fetch is attempted

    Classification-b (task 36cf audit): DSO_REVIEW_CYCLE absent was used as a fixture
    convenience to get cycle_num=1. Under ledger semantics, a fresh ledger also returns 1,
    so this test requires no mock change — the default _init_cycle_ledger() behavior is correct.
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

    async def mock_dispatch(agents, **kwargs):
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
                # DSO_REVIEW_CYCLE absent → _init_cycle_ledger() defaults to 1.
                # Under ledger semantics (task 36cf) a fresh ledger also yields cycle 1.
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


def _make_large_diff(loc: int = 21000, files: int = 2) -> str:
    """Return a synthetic diff exceeding the region-split GATE LOC threshold.

    Defaults:
    - ``loc=21000`` clears the component #3' GATE default of 20000 (the GATE
      threshold review.region_split.gate_loc; the per-cluster fan-out
      threshold remains 3000 but no longer governs the gate decision).
    - ``files=2`` ensures a multi-file diff; the file-atomicity invariant
      makes single-file diffs ineligible for region-split regardless of LOC.
    """
    per_file = max(1, loc // files)
    parts: list[str] = []
    for f in range(files):
        path = f"bigfile_{f}.py"
        parts.append(
            f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1 +1 @@\n"
        )
        parts.extend(f"+line {i}\n" for i in range(per_file))
    return "".join(parts)


def _make_small_diff(loc: int = 5) -> str:
    """Return a synthetic diff with only ``loc`` changed lines."""
    header = "diff --git a/small.py b/small.py\n--- a/small.py\n+++ b/small.py\n@@ -1 +1 @@\n"
    body = "".join(f"+line {i}\n" for i in range(loc))
    return header + body


def test_runner_calls_run_region_split_for_large_diff(tmp_path):
    """
    Given: a multi-file diff exceeding the region-split LOC threshold (default 3000)
    When: runner.main() is called in-process
    Then: run_region_split_strategy_f is called (not standard tier dispatch)
          AND _aggregate_cluster_findings is called to synthesize results

    Strategy F (S7.T7): large diffs bypass the standard tier path and route
    through the filter → Strategy F chunk → dispatch → aggregate pipeline.

    Threshold history (component #3'): the GATE default is review.region_split.gate_loc
    = 20000 (decoupled from the per-cluster fan-out loc_threshold, still 3000).
    The diff used here clears the new GATE default AND spans 2+ files so the
    file-atomicity invariant doesn't short-circuit region-split to False.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = _make_large_diff(loc=21000, files=2)
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "out.json"

    strategy_f_called: list[dict] = []

    def mock_run_region_split_strategy_f(**kwargs):
        strategy_f_called.append(kwargs)
        # Return a minimal dispatch spec so the pipeline can proceed.
        return [
            {
                "cluster_dir": ".",
                "files": ["file0.py"],
                "diff": diff_text,
                "oversized_single_file": False,
            }
        ]

    aggregate_called: list[dict] = []

    def mock_aggregate(**kwargs):
        aggregate_called.append(kwargs)
        return {"findings": [], "visibility_trailer": "", "aggregation_status": "ok"}

    dispatch_called: list = []

    async def mock_dispatch(agents, **kwargs):
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
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.run_region_split_strategy_f",
            side_effect=mock_run_region_split_strategy_f,
        ),
        patch(
            "dso_ci_review.runner._aggregate_cluster_findings",
            side_effect=mock_aggregate,
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
    assert strategy_f_called, (
        "run_region_split_strategy_f must be called when a multi-file diff exceeds "
        "the region-split LOC threshold (default 3000; see bug 532e-6ab7)"
    )
    assert aggregate_called, (
        "_aggregate_cluster_findings must be called after Strategy F dispatch "
        "to synthesize per-cluster results into a unified payload"
    )


def test_runner_skips_run_region_split_for_small_diff(tmp_path):
    """
    Given: a diff below the region-split LOC threshold (default 3000 per bug 532e-6ab7)
    When: runner.main() is called in-process
    Then: run_region_split_strategy_f is NOT called
          AND async_dispatch_specialists IS called (normal path)

    Strategy F (S7.T7): small diffs use the standard tier pipeline.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = _make_small_diff(5)
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "out.json"

    strategy_f_called: list = []

    def mock_run_region_split_strategy_f(**kwargs):
        strategy_f_called.append(kwargs)
        return []

    dispatch_called: list = []

    async def mock_dispatch(agents, **kwargs):
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
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.run_region_split_strategy_f",
            side_effect=mock_run_region_split_strategy_f,
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
    assert not strategy_f_called, (
        "run_region_split_strategy_f must NOT be called for small diffs; "
        f"was called with: {strategy_f_called!r}"
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
# all tests below must fail until Task T2 implements it.
#

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
    import subprocess  # subprocess is also imported at module level; explicit here for clarity
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
    # S-B is now wired: dispatch_schema_correction is called on schema_fail.
    # Patch it to return valid (empty) findings so the S-A exit-0 contract still holds.
    _corrected_findings = {"findings": [], "summary": "Corrected by S-B stub."}

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
            return_value=1,
        ),
        patch(
            "dso_ci_review.runner.dispatch_schema_correction",
            return_value=_corrected_findings,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    # S-A + S-B contract: schema_fail path dispatches correction (S-B) and exits 0
    # when correction succeeds, writing the corrected findings to the output file.
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
# exist yet — all tests below must fail until Task 5 integrates them in runner.py.
#

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


def test_runner_schema_correction_exhausted_retries_returns_nonzero(tmp_path):
    """
    Given: _validate_findings_schema signals schema_fail
           AND dispatch_schema_correction returns an exhausted-retry result
              (contains synthetic parse_error/schema_error finding)
    When: runner.main() executes
    Then: exit code is non-zero (fail-closed — exhausted retries must not silently pass)
          AND the output file is written (artifact upload can proceed)

    Regression for bug: exhausted retries fell through to normal exit code logic
    which excluded parse_error from blocking, allowing schema-invalid PRs to merge.
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
    # Simulate dispatch_schema_correction exhausting retries:
    # returns the last attempt's findings PLUS a synthetic schema_error
    exhausted_result = {
        "findings": [
            {
                "severity": "suggestion",
                "category": "hygiene",
                "description": "A real finding that survived correction attempt.",
                "file": "foo.py",
                "cited_lines": ["foo.py:1"],
                "cited_excerpt": "",
            },
            {
                "type": "parse_error",
                "severity": "critical",
                "category": "schema_error",
                "description": "Schema correction failed after 2 attempt(s): frozen field mutated",
                "finding_id": "schema_error_abcd1234",
                "file": "",
                "cited_lines": [],
                "cited_excerpt": "",
                "reachability": "",
            },
        ],
        "summary": "Schema correction applied: all attempts exhausted",
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
            return_value=exhausted_result,
        ),
        redirect_stderr(stderr_capture),
    ):
        exit_code = runner_mod.main()

    assert exit_code != 0, (
        f"Expected non-zero exit when schema correction exhausted retries; got {exit_code}. "
        f"Exhausted retry results contain synthetic schema_error — must block merge (fail-closed). "
        f"stderr={stderr_capture.getvalue()!r}"
    )
    assert output_file.exists(), (
        "Output file must be written even when retries are exhausted (artifact upload needs it)"
    )
    output_data = json.loads(output_file.read_text())
    assert "cycle_number" in output_data, (
        "cycle_number must be stamped in output even on exhausted-retry path so next cycle "
        "can correctly compute DSO_REVIEW_CYCLE"
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

    # Pass plugin_root explicitly so CLAUDE_PLUGIN_ROOT (which points to the main
    # repo in worktree sessions) does not cause the test to read the wrong script.
    _worktree_plugin_root = str(pathlib.Path(__file__).parents[3] / "plugins" / "dso")
    validator_script = runner_mod._resolve_validator_script(
        plugin_root=_worktree_plugin_root
    )
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


# ---------------------------------------------------------------------------
# _read_config_int and _clamp_schema_correction_attempts tests
# Task efab-ac00-d1a8-4cee (functions do not exist yet in runner.py)
# ---------------------------------------------------------------------------
#

#   tests/skills/dso_ci_review/test_runner_smoke.py [test_read_config_int_returns_default_when_key_absent]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_read_config_int_returns_value_when_key_present]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_read_config_int_returns_default_on_invalid_value]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_clamp_schema_correction_attempts_honors_zero]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_clamp_schema_correction_attempts_honors_within_ceiling]
#   tests/skills/dso_ci_review/test_runner_smoke.py [test_clamp_schema_correction_attempts_clamps_above_ceiling_with_warning]


def test_read_config_int_returns_default_when_key_absent(tmp_path):
    """
    Given: a dso-config.conf with no review.schema_correction_max_attempts entry
    When: _read_config_int("review.schema_correction_max_attempts", 1, config_path) is called
    Then: returns 1 (the default)

    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("# no review.schema_correction_max_attempts key\n")

    result = runner_mod._read_config_int(
        "review.schema_correction_max_attempts", 1, str(config_file)
    )
    assert result == 1, (
        f"_read_config_int must return the default (1) when the key is absent; "
        f"got {result!r}"
    )


def test_read_config_int_returns_value_when_key_present(tmp_path):
    """
    Given: dso-config.conf contains "review.schema_correction_max_attempts=2"
    When: _read_config_int("review.schema_correction_max_attempts", 1, config_path) is called
    Then: returns 2

    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.schema_correction_max_attempts=2\n")

    result = runner_mod._read_config_int(
        "review.schema_correction_max_attempts", 1, str(config_file)
    )
    assert result == 2, (
        f"_read_config_int must return 2 when the config contains "
        f"'review.schema_correction_max_attempts=2'; got {result!r}"
    )


def test_read_config_int_returns_default_on_invalid_value(tmp_path):
    """
    Given: dso-config.conf contains 'review.schema_correction_max_attempts=foo'
    When: _read_config_int("review.schema_correction_max_attempts", 1, config_path) is called
    Then: returns 1 (the default) without raising an exception

    AC amendment: covers missing_error_path — non-integer config values must fall
    back to the default rather than raising ValueError or propagating a parse error.
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.schema_correction_max_attempts=foo\n")

    result = runner_mod._read_config_int(
        "review.schema_correction_max_attempts", 1, str(config_file)
    )
    assert result == 1, (
        f"_read_config_int must return the default (1) when the config value is "
        f"non-integer ('foo'); got {result!r}. Must not raise."
    )


def test_read_config_int_handles_whitespace_around_equals(tmp_path):
    """
    Given: dso-config.conf contains 'review.schema_correction_max_attempts = 2'
           (spaces around '=', as some editors produce)
    When: _read_config_int("review.schema_correction_max_attempts", 1, config_path) is called
    Then: returns 2 (whitespace-normalized match, not the default)
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.schema_correction_max_attempts = 2\n")

    result = runner_mod._read_config_int(
        "review.schema_correction_max_attempts", 1, str(config_file)
    )
    assert result == 2, (
        f"_read_config_int must handle 'key = value' format (spaces around '='); "
        f"got {result!r} (expected 2, not the default 1). "
        "Some editors produce 'key = value' in config files."
    )


def test_read_config_int_returns_default_when_file_absent(tmp_path):
    """
    Given: config_path points to a non-existent file
    When: _read_config_int("review.schema_correction_max_attempts", 1, config_path) is called
    Then: returns the default (1) without raising
    """
    import dso_ci_review.runner as runner_mod

    missing = str(tmp_path / "nonexistent-config.conf")
    result = runner_mod._read_config_int(
        "review.schema_correction_max_attempts", 1, missing
    )
    assert result == 1, (
        f"_read_config_int must return the default when config file does not exist; "
        f"got {result!r}"
    )


def test_read_config_int_returns_default_on_oserror(tmp_path):
    """
    Given: config_path exists but raises OSError on open (e.g. permission denied)
    When: _read_config_int("review.schema_correction_max_attempts", 1, config_path) is called
    Then: returns the default (1) without propagating the exception
    """
    import dso_ci_review.runner as runner_mod
    import unittest.mock as mock

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.schema_correction_max_attempts=2\n")

    with mock.patch("builtins.open", side_effect=OSError("permission denied")):
        result = runner_mod._read_config_int(
            "review.schema_correction_max_attempts", 1, str(config_file)
        )
    assert result == 1, (
        f"_read_config_int must return the default when OSError is raised on open; "
        f"got {result!r}"
    )


def test_read_config_int_returns_default_on_unicode_decode_error(tmp_path):
    """
    Given: config_path exists but raises UnicodeDecodeError on read (non-UTF-8 bytes)
    When: _read_config_int("review.schema_correction_max_attempts", 1, config_path) is called
    Then: returns the default (1) without propagating the exception
    """
    import dso_ci_review.runner as runner_mod
    import unittest.mock as mock

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.schema_correction_max_attempts=2\n")

    with mock.patch(
        "builtins.open",
        side_effect=UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte"),
    ):
        result = runner_mod._read_config_int(
            "review.schema_correction_max_attempts", 1, str(config_file)
        )
    assert result == 1, (
        f"_read_config_int must return the default when UnicodeDecodeError is raised; "
        f"got {result!r}. Non-UTF-8 config files must not crash the reader."
    )


def test_clamp_schema_correction_attempts_honors_zero():
    """
    Given: max_attempts=0
    When: _clamp_schema_correction_attempts(0) is called
    Then: returns 0 (disable-correction sentinel honored as-is)

    """
    import dso_ci_review.runner as runner_mod

    result = runner_mod._clamp_schema_correction_attempts(0)
    assert result == 0, (
        f"_clamp_schema_correction_attempts(0) must return 0 (disable sentinel); "
        f"got {result!r}"
    )


def test_clamp_schema_correction_attempts_honors_within_ceiling():
    """
    Given: values 1 and 3
    When: _clamp_schema_correction_attempts(v) is called for each
    Then: returns the value unchanged (no clamping, no warning)

    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    for v in (1, 3):
        stderr_capture = io.StringIO()
        with redirect_stderr(stderr_capture):
            result = runner_mod._clamp_schema_correction_attempts(v)
        assert result == v, (
            f"_clamp_schema_correction_attempts({v}) must return {v} unchanged; "
            f"got {result!r}"
        )
        stderr_text = stderr_capture.getvalue()
        assert not stderr_text, (
            f"_clamp_schema_correction_attempts({v}) must not emit a warning "
            f"(value is within ceiling); got stderr: {stderr_text!r}"
        )


def test_clamp_schema_correction_attempts_clamps_above_ceiling_with_warning(capsys):
    """
    Given: max_attempts=10
    When: _clamp_schema_correction_attempts(10) is called
    Then: returns 3; a warning line is emitted to stderr containing
          "schema_correction_max_attempts" and "clamped" (or equivalent)

    """
    import dso_ci_review.runner as runner_mod

    result = runner_mod._clamp_schema_correction_attempts(10)
    captured = capsys.readouterr()

    assert result == 3, (
        f"_clamp_schema_correction_attempts(10) must clamp to 3; got {result!r}"
    )
    assert "schema_correction_max_attempts" in captured.err, (
        f"Warning must mention 'schema_correction_max_attempts'; "
        f"got stderr: {captured.err!r}"
    )
    assert "clamp" in captured.err.lower(), (
        f"Warning must mention 'clamped' (or 'clamp'); got stderr: {captured.err!r}"
    )


def test_clamp_schema_correction_attempts_rejects_negative(capsys):
    """
    Given: max_attempts=-5 (negative misconfiguration)
    When: _clamp_schema_correction_attempts(-5) is called
    Then: returns 0 (correction disabled) and emits a warning to stderr
          mentioning 'schema_correction_max_attempts' and 'negative'
    """
    import dso_ci_review.runner as runner_mod

    result = runner_mod._clamp_schema_correction_attempts(-5)
    captured = capsys.readouterr()

    assert result == 0, (
        f"_clamp_schema_correction_attempts(-5) must clamp to 0 (correction disabled); "
        f"got {result!r}"
    )
    assert "schema_correction_max_attempts" in captured.err, (
        f"Warning must mention 'schema_correction_max_attempts'; "
        f"got stderr: {captured.err!r}"
    )
    assert "negative" in captured.err.lower(), (
        f"Warning must mention 'negative'; got stderr: {captured.err!r}"
    )


def test_get_schema_correction_max_attempts_end_to_end(tmp_path):
    """
    Given: dso-config.conf contains 'review.schema_correction_max_attempts=2'
    When: get_schema_correction_max_attempts(config_path=...) is called
    Then: returns 2 (valid value, no clamping needed)

    Exercises the full composition: _read_config_int → _clamp_schema_correction_attempts.
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.schema_correction_max_attempts=2\n")

    result = runner_mod.get_schema_correction_max_attempts(config_path=str(config_file))

    assert result == 2, (
        f"get_schema_correction_max_attempts must return 2 when config sets "
        f"review.schema_correction_max_attempts=2; got {result!r}"
    )


def test_get_schema_correction_max_attempts_clamps_negative(tmp_path, capsys):
    """
    Given: dso-config.conf contains 'review.schema_correction_max_attempts=-1'
    When: get_schema_correction_max_attempts(config_path=...) is called
    Then: returns 0 (negative clamped to disable sentinel)
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.schema_correction_max_attempts=-1\n")

    result = runner_mod.get_schema_correction_max_attempts(config_path=str(config_file))

    assert result == 0, (
        f"get_schema_correction_max_attempts must clamp -1 to 0; got {result!r}"
    )


def test_get_schema_correction_max_attempts_clamps_above_ceiling(tmp_path, capsys):
    """
    Given: dso-config.conf contains 'review.schema_correction_max_attempts=10'
           (above the hard ceiling of 3)
    When: get_schema_correction_max_attempts(config_path=...) is called
    Then: returns 3 (ceiling value) and emits a warning to stderr
    """
    import dso_ci_review.runner as runner_mod

    config_file = tmp_path / "dso-config.conf"
    config_file.write_text("review.schema_correction_max_attempts=10\n")

    result = runner_mod.get_schema_correction_max_attempts(config_path=str(config_file))
    captured = capsys.readouterr()

    assert result == runner_mod._SCHEMA_CORRECTION_MAX_ATTEMPTS_CEILING, (
        f"get_schema_correction_max_attempts must clamp 10 to ceiling "
        f"{runner_mod._SCHEMA_CORRECTION_MAX_ATTEMPTS_CEILING}; got {result!r}"
    )
    assert "schema_correction_max_attempts" in captured.err, (
        f"Warning must mention 'schema_correction_max_attempts'; "
        f"got stderr: {captured.err!r}"
    )


def test_strategy_f_oversized_single_file_skips_llm_dispatch(tmp_path):
    """
    Given: Strategy F returns a spec with oversized_single_file=True
    When: runner.main() processes that cluster in the Strategy F dispatch loop
    Then: async_dispatch_specialists is NOT called for that cluster
          AND the pipeline completes without dispatching the oversized diff to the LLM
          AND stderr contains an informational skip message for the oversized cluster

    Root cause (bug 0768-337d-f6fa-43f0): runner.py Step 4 ignores the
    oversized_single_file flag from region_split.py. When a single file's diff
    exceeds the loc_threshold, the runner dispatches it to the LLM unchanged,
    causing a 134KB non-JSON response and fallback_exhausted on claude-opus-4-7.
    """
    import io
    from contextlib import redirect_stderr

    import dso_ci_review.runner as runner_mod

    diff_text = _make_large_diff(loc=21000, files=2)
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)
    output_file = tmp_path / "out.json"

    # Strategy F returns one normal cluster and one oversized_single_file cluster
    strategy_f_specs = [
        {
            "cluster_dir": ".",
            "files": ["bigfile_0.py"],
            "diff": diff_text[:100],  # small cluster — dispatched normally
            "oversized_single_file": False,
        },
        {
            "cluster_dir": ".",
            "files": ["bigfile_1.py"],
            "diff": diff_text,  # oversized — must NOT be dispatched to LLM
            "oversized_single_file": True,
        },
    ]

    dispatch_calls: list[list] = []

    async def mock_dispatch(agents, **kwargs):
        dispatch_calls.append(list(agents))
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
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.run_region_split_strategy_f",
            return_value=strategy_f_specs,
        ),
        patch(
            "dso_ci_review.runner._aggregate_cluster_findings",
            return_value={
                "findings": [],
                "visibility_trailer": "",
                "aggregation_status": "ok",
            },
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        redirect_stderr(stderr_capture),
    ):
        runner_mod.main()

    # The LLM must NOT be called for the oversized cluster
    # (only the normal cluster should be dispatched)
    assert len(dispatch_calls) == 1, (
        f"Expected exactly 1 LLM dispatch (the non-oversized cluster); "
        f"got {len(dispatch_calls)} dispatch(es). "
        f"The oversized_single_file=True cluster must NOT be dispatched to the LLM "
        f"(bug 0768-337d-f6fa-43f0: oversized file diffs cause non-JSON LLM responses)."
    )

    stderr_output = stderr_capture.getvalue()
    assert "oversized" in stderr_output.lower() or "skip" in stderr_output.lower(), (
        f"stderr must contain an informational message about skipping the oversized "
        f"cluster; got stderr={stderr_output!r}"
    )
