"""Unit tests for dso_reconciler/invariants.py.

Covers check_at_most_one_dso_local_id end-to-end against a mocked alert_store
and a mocked subprocess.run for the ticket CLI invocation. Does NOT load
reconcile.py — tests that exercise the reconcile→invariants integration live
in test_at_most_one_invariant.py (deferred to the core-pipeline PR because
that test loads reconcile.py too).
"""

from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
INVARIANTS_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "invariants.py"
)


def _load_invariants() -> ModuleType:
    spec = importlib.util.spec_from_file_location("invariants", INVARIANTS_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def invariants() -> ModuleType:
    return _load_invariants()


@pytest.fixture
def mock_alert_store() -> MagicMock:
    """Mock alert_store module with is_deduped / append / patch_bug_filed."""
    m = MagicMock()
    m.is_deduped.return_value = False
    return m


def _snapshot_with_dup(jira_key: str = "DIG-100") -> dict:
    return {jira_key: {"dso_local_ids": ["id-a", "id-b"]}}


def _ok_cli_result(bug_id: str = "bug-new-001") -> MagicMock:
    r = MagicMock()
    r.returncode = 0
    r.stdout = f"Created bug ticket {bug_id}\n"
    r.stderr = ""
    return r


# ---------------------------------------------------------------------------
# Happy path — duplicate found, bug filed, alert patched
# ---------------------------------------------------------------------------


def test_dup_dso_local_ids_files_alert_and_bug(
    invariants: ModuleType, mock_alert_store: MagicMock, tmp_path: Path
) -> None:
    """A snapshot with duplicate dso_local_ids files one alert and one bug ticket."""
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        with patch.object(invariants.subprocess, "run", return_value=_ok_cli_result()):
            filed = invariants.check_at_most_one_dso_local_id(
                _snapshot_with_dup(), repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    assert len(filed) == 1
    assert filed[0]["jira_key"] == "DIG-100"
    assert filed[0]["dedup_key"] == "at-most-one:DIG-100"
    mock_alert_store.append.assert_called_once()
    mock_alert_store.patch_bug_filed.assert_called_once_with(
        "at-most-one:DIG-100", "bug-new-001", tmp_path
    )


# ---------------------------------------------------------------------------
# No duplicates — no alerts, no bugs
# ---------------------------------------------------------------------------


def test_no_duplicates_files_nothing(
    invariants: ModuleType, mock_alert_store: MagicMock, tmp_path: Path
) -> None:
    """A clean snapshot triggers no alerts."""
    snap = {"DIG-1": {"dso_local_ids": ["only-one"]}, "DIG-2": {}}
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        filed = invariants.check_at_most_one_dso_local_id(
            snap, repo_root=tmp_path, ticket_cli="/fake/dso"
        )

    assert filed == []
    mock_alert_store.append.assert_not_called()
    mock_alert_store.patch_bug_filed.assert_not_called()


# ---------------------------------------------------------------------------
# Dedup short-circuit — already-filed alert is not re-filed
# ---------------------------------------------------------------------------


def test_dedup_short_circuits(
    invariants: ModuleType, mock_alert_store: MagicMock, tmp_path: Path
) -> None:
    """When is_deduped returns True, the violation is skipped."""
    mock_alert_store.is_deduped.return_value = True
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        with patch.object(invariants.subprocess, "run") as mock_run:
            filed = invariants.check_at_most_one_dso_local_id(
                _snapshot_with_dup(), repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    assert filed == []
    mock_alert_store.append.assert_not_called()
    mock_run.assert_not_called()


# ---------------------------------------------------------------------------
# CAP_PER_PASS — only 5 violations filed even when more exist
# ---------------------------------------------------------------------------


def test_cap_per_pass_limits_filings(
    invariants: ModuleType, mock_alert_store: MagicMock, tmp_path: Path
) -> None:
    """Only _CAP_PER_PASS=5 violations are filed per call; extras are skipped this pass."""
    snap = {f"DIG-{i}": {"dso_local_ids": ["a", "b"]} for i in range(10)}
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        with patch.object(invariants.subprocess, "run", return_value=_ok_cli_result()):
            filed = invariants.check_at_most_one_dso_local_id(
                snap, repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    assert len(filed) == 5
    assert mock_alert_store.append.call_count == 5


# ---------------------------------------------------------------------------
# TimeoutExpired — alert is still written, stderr WARN surfaced, no
# patch_bug_filed call
# ---------------------------------------------------------------------------


def test_timeout_surfaces_warning_does_not_patch_bug(
    invariants: ModuleType,
    mock_alert_store: MagicMock,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """TimeoutExpired during ticket-create surfaces a WARN to stderr and leaves the alert orphan-without-bug (next pass will see dedup; operators are expected to act on the WARN)."""
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        with patch.object(
            invariants.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(cmd="dso", timeout=30),
        ):
            filed = invariants.check_at_most_one_dso_local_id(
                _snapshot_with_dup(), repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    # Violation IS recorded (alert appended, returned) even though ticket failed
    assert len(filed) == 1
    mock_alert_store.append.assert_called_once()
    mock_alert_store.patch_bug_filed.assert_not_called()

    err = capsys.readouterr().err
    assert "WARN" in err
    assert "at-most-one:DIG-100" in err
    assert "timed out" in err


def test_oserror_surfaces_warning_does_not_patch_bug(
    invariants: ModuleType,
    mock_alert_store: MagicMock,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """FileNotFoundError (e.g., ticket_cli not on PATH) is treated like a transient CLI failure: surface WARN, leave alert without bug-ticket linkage, do NOT crash the loop."""
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        with patch.object(
            invariants.subprocess,
            "run",
            side_effect=FileNotFoundError("dso not on PATH"),
        ):
            filed = invariants.check_at_most_one_dso_local_id(
                _snapshot_with_dup(), repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    assert len(filed) == 1
    mock_alert_store.append.assert_called_once()
    mock_alert_store.patch_bug_filed.assert_not_called()
    err = capsys.readouterr().err
    assert "WARN" in err
    assert "FileNotFoundError" in err


# ---------------------------------------------------------------------------
# Non-zero ticket-create exit — alert kept, WARN surfaced
# ---------------------------------------------------------------------------


def test_non_zero_exit_surfaces_warning(
    invariants: ModuleType,
    mock_alert_store: MagicMock,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """When ticket-create exits non-zero, the failure is surfaced but the alert is preserved."""
    bad_result = MagicMock()
    bad_result.returncode = 1
    bad_result.stdout = ""
    bad_result.stderr = "Invalid ticket type"
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        with patch.object(invariants.subprocess, "run", return_value=bad_result):
            filed = invariants.check_at_most_one_dso_local_id(
                _snapshot_with_dup(), repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    assert len(filed) == 1
    mock_alert_store.append.assert_called_once()
    mock_alert_store.patch_bug_filed.assert_not_called()
    err = capsys.readouterr().err
    assert "exit=1" in err


# ---------------------------------------------------------------------------
# Programming errors (AttributeError, TypeError) now propagate — they no
# longer get silently swallowed by an over-broad except.
# ---------------------------------------------------------------------------


def test_programming_error_propagates(
    invariants: ModuleType, mock_alert_store: MagicMock, tmp_path: Path
) -> None:
    """An AttributeError (programming bug) inside subprocess.run is NOT swallowed."""
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        with patch.object(
            invariants.subprocess,
            "run",
            side_effect=AttributeError("simulated programming defect"),
        ):
            with pytest.raises(AttributeError, match="simulated programming defect"):
                invariants.check_at_most_one_dso_local_id(
                    _snapshot_with_dup(), repo_root=tmp_path, ticket_cli="/fake/dso"
                )


# ---------------------------------------------------------------------------
# Non-list dso_local_ids value is ignored (defensive read shape)
# ---------------------------------------------------------------------------


def test_non_list_dso_local_ids_is_ignored(
    invariants: ModuleType, mock_alert_store: MagicMock, tmp_path: Path
) -> None:
    """A snapshot entry whose dso_local_ids is not a list (or a single-element list) does not trigger a violation."""
    snap = {
        "DIG-A": {"dso_local_ids": "single-string-not-a-list"},
        "DIG-B": {"dso_local_ids": ["just-one"]},
        "DIG-C": {},  # no dso_local_ids at all
    }
    with patch.object(invariants, "_load_alert_store", return_value=mock_alert_store):
        filed = invariants.check_at_most_one_dso_local_id(
            snap, repo_root=tmp_path, ticket_cli="/fake/dso"
        )

    assert filed == []
    mock_alert_store.append.assert_not_called()
