"""RED tests for runner.py — ledger-authoritative cycle_num derivation + SHORT_CIRCUIT.

All 5 tests fail until runner.py implements:
  - init_cycle_ledger(): reads cycle-ledger.json OR reconstructs from PR comments,
    derives cycle_num from ledger length (authoritative over DSO_REVIEW_CYCLE).
  - SHORT_CIRCUIT pre-check: when HEAD SHA matches last cycle AND arbiter-rulings.json
    exists with BLOCK rulings, exit 1 without calling async_dispatch_specialists.

RED marker: tests/skills/dso_ci_review/test_runner_cycle_ledger.py [test_init_cycle_ledger_reads_existing_file]
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
from unittest.mock import patch

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.runner as runner_mod  # noqa: E402


def test_init_cycle_ledger_reads_existing_file(tmp_path):
    """Given: cycle-ledger.json exists with cycles=[{cycle_num:1, commit_sha:'abc'}].
    When: runner initializes the cycle ledger from artifacts_dir.
    Then: derived cycle_num == 2 (len(cycles) + 1 from the ledger).
    """
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "",
        "cycles": [
            {"cycle_num": 1, "commit_sha": "abc", "findings": [], "findings_hash": "h1"}
        ],
    }
    ledger_path = tmp_path / "cycle-ledger.json"
    ledger_path.write_text(json.dumps(ledger))

    # init_cycle_ledger is the function under test — it must exist and return cycle_num.
    cycle_num = runner_mod.init_cycle_ledger(artifacts_dir=str(tmp_path))

    assert cycle_num == 2, (
        f"Expected cycle_num=2 (len(cycles)+1), got {cycle_num!r}. "
        "Ledger had 1 existing cycle; authoritative cycle_num must be len(cycles)+1."
    )


def test_init_cycle_ledger_reconstructs_from_pr_when_file_absent(tmp_path):
    """Given: ledger file absent + PR_NUMBER=123 + GITHUB_REPOSITORY=owner/repo.
    When: runner initializes the cycle ledger.
    Then: reconstruct_from_pr_comments(123, 'owner/repo') is called; cycle_num==2.
    """
    reconstructed = {
        "schema_version": "1.1.0",
        "epic_id": "",
        "cycles": [
            {"cycle_num": 1, "commit_sha": "xyz", "findings": [], "findings_hash": "h1"}
        ],
    }

    with (
        patch.dict(
            "os.environ",
            {"PR_NUMBER": "123", "GITHUB_REPOSITORY": "owner/repo"},
        ),
        patch(
            "dso_ci_review.cycle_ledger.reconstruct_from_pr_comments",
            return_value=reconstructed,
        ) as mock_reconstruct,
    ):
        cycle_num = runner_mod.init_cycle_ledger(artifacts_dir=str(tmp_path))

    mock_reconstruct.assert_called_once_with(123, "owner/repo")
    assert cycle_num == 2, (
        f"Expected cycle_num=2 from reconstructed ledger (1 cycle), got {cycle_num!r}."
    )


def test_init_cycle_ledger_starts_at_cycle_1_with_no_history(tmp_path):
    """Given: no ledger file AND no PR_NUMBER (or no GITHUB_REPOSITORY).
    When: runner initializes the cycle ledger.
    Then: cycle_num==1, no exception raised.
    """
    env_without_pr = {
        k: v
        for k, v in os.environ.items()
        if k not in ("PR_NUMBER", "GITHUB_REPOSITORY")
    }

    with patch.dict("os.environ", env_without_pr, clear=True):
        try:
            cycle_num = runner_mod.init_cycle_ledger(artifacts_dir=str(tmp_path))
        except Exception as exc:
            raise AssertionError(
                f"init_cycle_ledger raised {type(exc).__name__} with no history: {exc}"
            ) from exc

    assert cycle_num == 1, (
        f"Expected cycle_num=1 with no history (empty ledger, no PR), got {cycle_num!r}."
    )


def test_init_cycle_ledger_warns_on_env_var_mismatch(tmp_path, capsys):
    """Given: DSO_REVIEW_CYCLE=5 in env BUT ledger says cycle_num=2 (1 cycle in ledger).
    When: runner initializes the cycle ledger.
    Then: WARNING on stderr containing both numbers; ledger wins (cycle_num=2 used).
    """
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "",
        "cycles": [
            {"cycle_num": 1, "commit_sha": "abc", "findings": [], "findings_hash": "h1"}
        ],
    }
    ledger_path = tmp_path / "cycle-ledger.json"
    ledger_path.write_text(json.dumps(ledger))

    with patch.dict("os.environ", {"DSO_REVIEW_CYCLE": "5"}):
        cycle_num = runner_mod.init_cycle_ledger(artifacts_dir=str(tmp_path))

    captured = capsys.readouterr()
    assert cycle_num == 2, (
        f"Ledger must win over DSO_REVIEW_CYCLE env var. Expected cycle_num=2, got {cycle_num!r}."
    )
    assert "WARNING" in captured.err or "warning" in captured.err.lower(), (
        f"Expected WARNING in stderr when DSO_REVIEW_CYCLE mismatches ledger. stderr={captured.err!r}"
    )
    assert "5" in captured.err and "2" in captured.err, (
        f"WARNING must reference both DSO_REVIEW_CYCLE value (5) and ledger-derived value (2). "
        f"stderr={captured.err!r}"
    )


def test_short_circuit_pre_check_same_sha_with_arbiter_rulings(tmp_path):
    """Given: ledger last commit_sha == HEAD AND arbiter-rulings.json has rulings=[{ruling:'BLOCK'}].
    When: runner.main() is called.
    Then: exits 1 (BLOCK present) AND async_dispatch_specialists is NOT called.
    """
    head_sha = "deadbeef" * 5  # 40-char fake SHA

    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "",
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": head_sha,
                "findings": [],
                "findings_hash": "h1",
            }
        ],
    }
    ledger_path = tmp_path / "cycle-ledger.json"
    ledger_path.write_text(json.dumps(ledger))

    arbiter_rulings = {
        "schema_version": "1.0.0",
        "rulings": [{"ruling": "BLOCK", "reason": "unresolved critical finding"}],
    }
    (tmp_path / "arbiter-rulings.json").write_text(json.dumps(arbiter_rulings))

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    dispatch_called = []

    async def mock_dispatch_specialists(agents):
        dispatch_called.append(agents)
        return []

    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "WORKFLOW_PLUGIN_ARTIFACTS_DIR": str(tmp_path),
            },
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch_specialists,
        ),
        patch(
            "dso_ci_review.runner._validate_agent_files",
            return_value=None,
        ),
        patch(
            "subprocess.check_output",
            return_value=head_sha + "\n",
        ),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 1, (
        f"Expected exit code 1 (BLOCK ruling short-circuit), got {exit_code!r}."
    )
    assert len(dispatch_called) == 0, (
        f"async_dispatch_specialists must NOT be called when SHORT_CIRCUIT triggers. "
        f"Was called {len(dispatch_called)} time(s)."
    )


def test_cycle_number_resets_on_sha_change(tmp_path):
    """When HEAD SHA differs from the last ledger cycle's commit_sha,
    cycle_number resets to 1 — preventing stale defense loading and
    incorrect two-call dispatch after force-pushes (bug 3fb2-23be)."""
    import contextlib
    from unittest.mock import patch as _patch

    old_sha = "aaa1111111111111111111111111111111111111"
    new_sha = "bbb2222222222222222222222222222222222222"

    ledger_with_old_sha = {
        "schema_version": "1.1.0",
        "epic_id": "",
        "cycles": [
            {"cycle_num": 2, "commit_sha": old_sha, "pr_number": 0},
        ],
    }

    specialist_findings = [
        {
            "findings": [
                {
                    "severity": "important",
                    "description": "Test finding for SHA-reset",
                    "cited_lines": ["src/foo.py:1"],
                    "category": "correctness",
                    "relation": "NEW_INTRODUCED",
                }
            ],
            "scores": {},
            "summary": "finding",
        }
    ]

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/src/foo.py b/src/foo.py\n+line\n")
    output_file = tmp_path / "findings.json"

    env = {
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "CI_REVIEW_PROVIDER": "anthropic",
        "ANTHROPIC_API_KEY": "test-key",
        "DSO_REVIEW_CYCLE": "3",
    }

    _TIER_RESULT = {
        "selected_tier": "light",
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
        "diff_lines": 1,
        "change_volume": 0,
        "computed_total": 1,
        "is_merge_commit": False,
    }

    dispatch_next = {
        "action": "DISPATCH_NEXT",
        "reason": "SHA changed, reset to cycle 1",
        "cycle_num": 1,
    }

    async def mock_dispatch(agents):
        return specialist_findings

    stack = contextlib.ExitStack()
    stack.enter_context(_patch.dict("os.environ", env))
    stack.enter_context(
        _patch("dso_ci_review.runner._classify_tier_via_bash", return_value=_TIER_RESULT)
    )
    stack.enter_context(
        _patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        )
    )
    stack.enter_context(
        _patch("dso_ci_review.runner.async_dispatch_specialists", side_effect=mock_dispatch)
    )
    stack.enter_context(
        _patch(
            "dso_ci_review.verifier.dispatch_verifier",
            side_effect=lambda findings, reviewed_sha=None: findings,
        )
    )
    stack.enter_context(
        _patch("dso_ci_review.runner.cycle_next_action", return_value=dispatch_next)
    )
    stack.enter_context(
        _patch("dso_ci_review.runner._resolve_artifacts_dir", return_value=str(tmp_path))
    )
    stack.enter_context(
        _patch(
            "dso_ci_review.runner._init_cycle_ledger",
            return_value=(ledger_with_old_sha, 3),
        )
    )
    stack.enter_context(_patch("dso_ci_review.runner._resolve_max_cycles", return_value=5))
    stack.enter_context(_patch("dso_ci_review.runner._resolve_pr_number", return_value=None))
    stack.enter_context(_patch("dso_ci_review.runner._resolve_repo", return_value=None))
    stack.enter_context(_patch("dso_ci_review.runner._append_cycle"))
    stack.enter_context(_patch("dso_ci_review.runner._post_cycle_marker_comment"))
    stack.enter_context(
        _patch("dso_ci_review.runner.subprocess.check_output", return_value=new_sha + "\n")
    )

    with stack:
        runner_mod.main()

    assert output_file.exists()
    output_data = json.loads(output_file.read_text())

    # The cycle_number in the output should be 1 (reset), not 3 (stale)
    output_cycle = output_data.get("cycle_number")
    assert output_cycle == 1, (
        f"Expected cycle_number=1 after SHA change, got {output_cycle}. "
        f"The SHA-reset should have fired because HEAD ({new_sha[:12]}) "
        f"differs from last ledger cycle SHA ({old_sha[:12]})."
    )
