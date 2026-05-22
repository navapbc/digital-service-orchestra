"""RED tests for dso_ci_review.cycle_dispatcher — next_action decision logic.

All tests fail until cycle_dispatcher.py is created (Story 45da-5043 T7).
"""

from __future__ import annotations

import pathlib
import sys

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.cycle_dispatcher import next_action  # noqa: E402


# --- Original 8 edge cases ---


def test_short_circuit_when_same_commit_sha_with_existing_arbiter_ruling(tmp_path):
    """SHORT_CIRCUIT when current SHA matches last cycle AND arbiter-rulings.json exists."""
    (tmp_path / "arbiter-rulings.json").write_text(
        '{"schema_version":"1.0.0","rulings":[]}'
    )
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 3,
                "commit_sha": "abc123",
                "findings": [],
                "findings_hash": "h3",
            }
        ],
    }
    result = next_action(
        ledger,
        max_cycles=4,
        current_findings=[{"file": "x.py", "line_range": "1", "category": "c"}],
        current_commit_sha="abc123",
        artifacts_dir=str(tmp_path),
    )
    assert result["action"] == "SHORT_CIRCUIT"
    assert result["cycle_num"] == 3


def test_reset_cycle_num_to_1_when_sha_changes():
    """SHA differs from last cycle → cycle_num returned = 1 (fresh start)."""
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "old1",
                "findings": [],
                "findings_hash": "h1",
            },
            {
                "cycle_num": 2,
                "commit_sha": "old1",
                "findings": [],
                "findings_hash": "h2",
            },
            {
                "cycle_num": 3,
                "commit_sha": "old1",
                "findings": [],
                "findings_hash": "h3",
            },
        ],
    }
    result = next_action(
        ledger,
        max_cycles=4,
        current_findings=[{"file": "x.py", "line_range": "1", "category": "c"}],
        current_commit_sha="new2",
    )
    assert result["cycle_num"] == 1


def test_skip_jaccard_when_cycle_1_no_prior():
    """Empty ledger (first cycle) → DISPATCH_NEXT, no Jaccard."""
    ledger = {"schema_version": "1.1.0", "epic_id": "e1", "cycles": []}
    result = next_action(
        ledger,
        max_cycles=4,
        current_findings=[{"file": "x.py", "line_range": "1", "category": "c"}],
        current_commit_sha="sha1",
    )
    assert result["action"] == "DISPATCH_NEXT"
    assert result["cycle_num"] == 1


def test_skip_jaccard_when_prior_cycle_has_reconstruction_gaps():
    """Prior cycle has reconstruction_gaps=True → skip Jaccard, return DISPATCH_NEXT."""
    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "reconstruction_gaps": True,
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "sha1",
                "findings": findings,
                "findings_hash": "h1",
                "reconstruction_gaps": True,
            },
        ],
    }
    result = next_action(
        ledger, max_cycles=4, current_findings=findings, current_commit_sha="sha1"
    )
    assert result["action"] == "DISPATCH_NEXT"


def test_pass_when_no_unresolved_findings():
    """current_findings empty → PASS regardless of cycle_num or ledger."""
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "sha1",
                "findings": [{"file": "x", "line_range": "1", "category": "c"}],
                "findings_hash": "h1",
            }
        ],
    }
    result = next_action(
        ledger, max_cycles=4, current_findings=[], current_commit_sha="sha1"
    )
    assert result["action"] == "PASS"


def test_dispatch_arbiter_when_cycle_num_reaches_max():
    """cycle_num >= max_cycles AND unresolved findings → DISPATCH_ARBITER."""
    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "sha1",
                "findings": findings,
                "findings_hash": "h1",
            },
            {
                "cycle_num": 2,
                "commit_sha": "sha1",
                "findings": findings,
                "findings_hash": "h2",
            },
            {
                "cycle_num": 3,
                "commit_sha": "sha1",
                "findings": findings,
                "findings_hash": "h3",
            },
        ],
    }
    # Next cycle would be 4, == max_cycles
    result = next_action(
        ledger, max_cycles=4, current_findings=findings, current_commit_sha="sha1"
    )
    assert result["action"] == "DISPATCH_ARBITER"
    assert "max_cycles" in result["reason"]


def test_dispatch_arbiter_on_stable_halt_with_unresolved_critical():
    """Jaccard >= 0.85 + unresolved critical → DISPATCH_ARBITER (STABLE_HALT)."""
    findings = [
        {"file": f"f{i}.py", "line_range": "1", "category": "c", "severity": "critical"}
        for i in range(3)
    ]
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "sha1",
                "findings": findings,
                "findings_hash": "h1",
            },
            {
                "cycle_num": 2,
                "commit_sha": "sha1",
                "findings": findings,
                "findings_hash": "h2",
            },
        ],
    }
    result = next_action(
        ledger, max_cycles=4, current_findings=findings, current_commit_sha="sha1"
    )
    assert result["action"] == "DISPATCH_ARBITER"
    assert "STABLE_HALT" in result["reason"]


def test_dispatch_next_when_below_threshold_and_below_max():
    """Jaccard < 0.85 AND cycle < max_cycles → DISPATCH_NEXT."""
    prior_findings = [
        {"file": f"f{i}.py", "line_range": "1", "category": "c"} for i in range(4)
    ]
    current_findings = [
        {"file": "f0.py", "line_range": "1", "category": "c"}
    ]  # 1 of 4 = 0.25
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "sha1",
                "findings": prior_findings,
                "findings_hash": "h1",
            },
            {
                "cycle_num": 2,
                "commit_sha": "sha1",
                "findings": prior_findings,
                "findings_hash": "h2",
            },
        ],
    }
    result = next_action(
        ledger,
        max_cycles=4,
        current_findings=current_findings,
        current_commit_sha="sha1",
    )
    assert result["action"] == "DISPATCH_NEXT"
    assert result["cycle_num"] == 3


# --- 5 additional edge cases from AC amendment ---


def test_missing_ledger_file_returns_dispatch_next_cycle_1():
    """No prior cycles (fresh worktree, ledger absent → empty cycles list) → DISPATCH_NEXT cycle_num=1."""
    ledger = {"schema_version": "1.1.0", "epic_id": "", "cycles": []}
    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    result = next_action(
        ledger, max_cycles=4, current_findings=findings, current_commit_sha="sha1"
    )
    assert result["action"] == "DISPATCH_NEXT"
    assert result["cycle_num"] == 1


def test_corrupt_ledger_handled_deterministically():
    """Ledger with missing 'cycles' key (corrupt) → treat as empty, DISPATCH_NEXT cycle=1."""
    ledger = {"schema_version": "1.1.0"}  # missing 'cycles'
    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    result = next_action(
        ledger, max_cycles=4, current_findings=findings, current_commit_sha="sha1"
    )
    assert result["action"] == "DISPATCH_NEXT"
    assert result["cycle_num"] == 1


def test_forward_compat_schema_version_greater_than_1_1_0(capsys):
    """schema_version='2.0.0' → log warning, best-effort proceed, no raise."""
    ledger = {
        "schema_version": "2.0.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "sha1",
                "findings": [],
                "findings_hash": "h1",
            }
        ],
    }
    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    # Should NOT raise
    result = next_action(
        ledger, max_cycles=4, current_findings=findings, current_commit_sha="sha1"
    )
    assert result["action"] in ("DISPATCH_NEXT", "DISPATCH_ARBITER")
    captured = capsys.readouterr()
    # warning emitted to stderr
    assert "schema_version" in captured.err.lower() or "version" in captured.err.lower()


def test_reconstruction_gaps_with_multiple_cycles_skips_jaccard():
    """reconstruction_gaps=True with len(cycles)>=2 → still skips Jaccard, DISPATCH_NEXT."""
    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "reconstruction_gaps": True,
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "sha1",
                "findings": findings,
                "findings_hash": "h1",
                "reconstruction_gaps": True,
            },
            {
                "cycle_num": 2,
                "commit_sha": "sha1",
                "findings": findings,
                "findings_hash": "h2",
                "reconstruction_gaps": True,
            },
        ],
    }
    result = next_action(
        ledger, max_cycles=4, current_findings=findings, current_commit_sha="sha1"
    )
    assert result["action"] == "DISPATCH_NEXT"


def test_sha_change_reset_wins_over_max_cycles():
    """SHA changed AND cycle_num == max_cycles → SHA reset wins (cycle_num=1, DISPATCH_NEXT)."""
    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 1,
                "commit_sha": "old1",
                "findings": findings,
                "findings_hash": "h1",
            },
            {
                "cycle_num": 2,
                "commit_sha": "old1",
                "findings": findings,
                "findings_hash": "h2",
            },
            {
                "cycle_num": 3,
                "commit_sha": "old1",
                "findings": findings,
                "findings_hash": "h3",
            },
            {
                "cycle_num": 4,
                "commit_sha": "old1",
                "findings": findings,
                "findings_hash": "h4",
            },
        ],
    }
    result = next_action(
        ledger, max_cycles=4, current_findings=findings, current_commit_sha="new2"
    )
    # SHA-reset wins → cycle 1, dispatch next (not arbiter)
    assert result["cycle_num"] == 1
    assert result["action"] == "DISPATCH_NEXT"


# ── Bug da45 PR #202 finding f-b2c3d4e5 regression test ───────────────────────


def test_semver_schema_compare_treats_dotted_versions_numerically(tmp_path):
    """schema_version > '1.1.0' must use semver-style numeric comparison, not
    lexicographic string comparison. '1.10.0' is greater than '1.1.0' (10 > 1
    in the minor component), but Python string compare evaluates
    '1.10.0' > '1.1.0' as False because '.' sorts before '0'.

    Without this fix, the dispatcher silently proceeds on unknown future
    schemas (1.10.0, 1.1.10, etc.) without emitting the intended warning.
    """
    from dso_ci_review.cycle_dispatcher import _is_unknown_future_schema as f

    # Forward-compat versions that string-compare BACKWARD must be detected
    assert f("1.10.0", "1.1.0") is True
    assert f("1.1.10", "1.1.0") is True
    assert f("2.0.0", "1.1.0") is True

    # Versions equal to or older than the known max are not flagged
    assert f("1.1.0", "1.1.0") is False
    assert f("1.0.5", "1.1.0") is False
    assert f("0.9.0", "1.1.0") is False


# ── Bug ab89-4fbb PR-comment fallback for SHORT_CIRCUIT (CI re-run same SHA) ──


def test_short_circuit_via_pr_comment_when_artifacts_dir_empty(tmp_path):
    """SHORT_CIRCUIT via durable PR-comment state when artifacts dir has no
    arbiter-rulings.json file (CI ephemeral ARTIFACTS_DIR scenario).

    subprocess.run is patched to return a comment list containing a valid
    DSO-Arbiter-Ruling marker matching current_commit_sha.  next_action must
    return SHORT_CIRCUIT even though the filesystem file does not exist.
    """
    import json
    import subprocess
    from unittest.mock import MagicMock, patch

    body_text = "DSO-Arbiter-Ruling: 4 commit_sha=abc123"
    mock_result = MagicMock(spec=subprocess.CompletedProcess)
    mock_result.returncode = 0
    mock_result.stdout = json.dumps([{"body": body_text}])

    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 4,
                "commit_sha": "abc123",
                "findings": [],
                "findings_hash": "h4",
            }
        ],
    }
    # tmp_path is empty — no arbiter-rulings.json present
    with patch(
        "dso_ci_review.cycle_dispatcher.subprocess.run", return_value=mock_result
    ):
        result = next_action(
            ledger,
            max_cycles=4,
            current_findings=[{"file": "x.py", "line_range": "1", "category": "c"}],
            current_commit_sha="abc123",
            artifacts_dir=str(tmp_path),
            pr_number=270,
            repo="navapbc/digital-service-orchestra",
        )
    assert result["action"] == "SHORT_CIRCUIT"


def test_no_short_circuit_when_pr_has_no_matching_arbiter_marker(tmp_path):
    """No SHORT_CIRCUIT when gh api returns an empty comment list.

    With no arbiter marker on the PR and no arbiter-rulings.json on disk,
    next_action must fall through to the normal dispatch path.  For a ledger
    whose last cycle has the same SHA and cycle_num == max_cycles the expected
    action is DISPATCH_ARBITER.
    """
    import json
    import subprocess
    from unittest.mock import MagicMock, patch

    mock_result = MagicMock(spec=subprocess.CompletedProcess)
    mock_result.returncode = 0
    mock_result.stdout = json.dumps([])  # no comments

    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 4,
                "commit_sha": "abc123",
                "findings": findings,
                "findings_hash": "h4",
            }
        ],
    }
    # tmp_path is empty — no arbiter-rulings.json present
    with patch(
        "dso_ci_review.cycle_dispatcher.subprocess.run", return_value=mock_result
    ):
        result = next_action(
            ledger,
            max_cycles=4,
            current_findings=findings,
            current_commit_sha="abc123",
            artifacts_dir=str(tmp_path),
            pr_number=270,
            repo="navapbc/digital-service-orchestra",
        )
    assert result["action"] != "SHORT_CIRCUIT"


def test_pr_comment_fetch_failure_falls_through_to_dispatch(tmp_path):
    """Fail-open: CalledProcessError from gh api must not propagate out of
    next_action.  The function must return a non-SHORT_CIRCUIT action and must
    not raise.
    """
    import subprocess
    from unittest.mock import patch

    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 4,
                "commit_sha": "abc123",
                "findings": findings,
                "findings_hash": "h4",
            }
        ],
    }

    def _raise(*_args, **_kwargs):
        raise subprocess.CalledProcessError(1, "gh api")

    with patch("dso_ci_review.cycle_dispatcher.subprocess.run", side_effect=_raise):
        try:
            result = next_action(
                ledger,
                max_cycles=4,
                current_findings=findings,
                current_commit_sha="abc123",
                artifacts_dir=str(tmp_path),
                pr_number=270,
                repo="navapbc/digital-service-orchestra",
            )
        except Exception as exc:
            raise AssertionError(
                f"next_action must not raise on gh api failure; got {exc!r}"
            ) from exc
    assert result["action"] != "SHORT_CIRCUIT"


def test_local_mode_skips_pr_comment_check_when_repo_missing(tmp_path):
    """When repo kwarg is absent (or None), the PR-comment helper must NOT be
    invoked.  subprocess.run call count must be zero — no gh api call should
    occur for local-mode invocations that lack PR context.
    """
    from unittest.mock import patch

    findings = [{"file": "x.py", "line_range": "1", "category": "c"}]
    ledger = {
        "schema_version": "1.1.0",
        "epic_id": "e1",
        "cycles": [
            {
                "cycle_num": 4,
                "commit_sha": "abc123",
                "findings": findings,
                "findings_hash": "h4",
            }
        ],
    }
    # tmp_path is empty — no arbiter-rulings.json present
    with patch("dso_ci_review.cycle_dispatcher.subprocess.run") as mock_subprocess:
        result = next_action(
            ledger,
            max_cycles=4,
            current_findings=findings,
            current_commit_sha="abc123",
            artifacts_dir=str(tmp_path),
            # repo is intentionally omitted — local mode
        )
    assert mock_subprocess.call_count == 0, (
        "subprocess.run must not be called when repo kwarg is absent"
    )
    assert result["action"] != "SHORT_CIRCUIT"
