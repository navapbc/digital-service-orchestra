"""Tests for invariants.check_at_most_one_dso_local_id().

Tests cover:
  - test_a_clean_snapshot: no violations → no writes or ticket-cli calls
  - test_b_single_violation: one violation → one append + one ticket-cli call +
    patch_bug_filed called with returned bug id
  - test_c_dedup_window: same key violated twice within 24h → exactly one ticket-cli call
  - test_d_cap_at_5: 7 violations with cap=5 → exactly 5 writes + 5 calls + 2 skipped
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, call, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
INVARIANTS_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "invariants.py"
)


def _load_invariants() -> ModuleType:
    spec = importlib.util.spec_from_file_location("invariants", INVARIANTS_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["invariants"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def invariants() -> ModuleType:
    """Load the invariants module, failing all tests if absent."""
    if not INVARIANTS_PATH.exists():
        pytest.fail(
            f"invariants.py not found at {INVARIANTS_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_invariants()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_alert_store_mock(deduped_keys: set[str] | None = None):
    """Return a mock alert_store module with controllable dedup behavior."""
    if deduped_keys is None:
        deduped_keys = set()

    mock_store = MagicMock()
    mock_store.is_deduped.side_effect = lambda key, repo_root: key in deduped_keys
    mock_store.append.return_value = None
    mock_store.patch_bug_filed.return_value = None
    return mock_store


def _make_subprocess_result(returncode: int = 0, stdout: str = "bug-abc123"):
    result = MagicMock()
    result.returncode = returncode
    result.stdout = stdout + "\n"
    return result


# ---------------------------------------------------------------------------
# Test (a): clean snapshot → no writes or ticket-cli calls
# ---------------------------------------------------------------------------


def test_a_clean_snapshot(tmp_path, invariants):
    """A snapshot with no issues having multiple dso_local_ids produces no side effects."""
    snapshot = {
        "PROJ-100": {"dso_local_ids": ["local-abc"]},
        "PROJ-200": {"dso_local_ids": []},
        "PROJ-300": {"dso_local_ids": ["local-xyz"]},
        "PROJ-400": {},  # no dso_local_ids key at all
    }

    mock_store = _make_alert_store_mock(deduped_keys=set())

    with patch.object(invariants, "_load_alert_store", return_value=mock_store):
        with patch("invariants.subprocess.run") as mock_run:
            result = invariants.check_at_most_one_dso_local_id(
                snapshot, repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    assert result == []
    mock_store.append.assert_not_called()
    mock_run.assert_not_called()
    mock_store.patch_bug_filed.assert_not_called()


# ---------------------------------------------------------------------------
# Test (b): single violation → one append, one ticket-cli call, one patch_bug_filed
# ---------------------------------------------------------------------------


def test_b_single_violation(tmp_path, invariants):
    """One issue with two dso_local_ids triggers one append, one ticket-cli call, one patch."""
    snapshot = {
        "PROJ-100": {"dso_local_ids": ["local-aaa", "local-bbb"]},
    }

    mock_store = _make_alert_store_mock(deduped_keys=set())
    mock_proc_result = _make_subprocess_result(returncode=0, stdout="bug-ticket-xyz")

    with patch.object(invariants, "_load_alert_store", return_value=mock_store):
        with patch("invariants.subprocess.run", return_value=mock_proc_result) as mock_run:
            result = invariants.check_at_most_one_dso_local_id(
                snapshot, repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    # One violation returned
    assert len(result) == 1
    assert result[0]["jira_key"] == "PROJ-100"
    assert result[0]["dso_local_ids"] == ["local-aaa", "local-bbb"]

    # Exactly one append call
    mock_store.append.assert_called_once()
    append_record = mock_store.append.call_args[0][0]
    assert append_record["jira_key"] == "PROJ-100"
    assert "key" in append_record
    assert "timestamp_ns" in append_record

    # Exactly one subprocess.run call (ticket-cli)
    mock_run.assert_called_once()
    cli_args = mock_run.call_args[0][0]
    assert "ticket" in cli_args
    assert "create" in cli_args
    assert "bug" in cli_args

    # patch_bug_filed called with the returned bug id
    mock_store.patch_bug_filed.assert_called_once()
    patch_args = mock_store.patch_bug_filed.call_args[0]
    assert patch_args[1] == "bug-ticket-xyz"


# ---------------------------------------------------------------------------
# Test (c): same key violated twice within 24h dedup window → one ticket-cli call
# ---------------------------------------------------------------------------


def test_c_dedup_window(tmp_path, invariants):
    """Second call for the same jira_key within 24h dedup window skips ticket-cli."""
    dedup_key = "at-most-one:PROJ-100"
    snapshot = {
        "PROJ-100": {"dso_local_ids": ["local-aaa", "local-bbb"]},
    }

    # Simulate the key already being deduped (i.e., within the 24h window)
    mock_store = _make_alert_store_mock(deduped_keys={dedup_key})

    with patch.object(invariants, "_load_alert_store", return_value=mock_store):
        with patch("invariants.subprocess.run") as mock_run:
            result = invariants.check_at_most_one_dso_local_id(
                snapshot, repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    # Deduped: no violation filed
    assert result == []
    mock_store.append.assert_not_called()
    mock_run.assert_not_called()
    mock_store.patch_bug_filed.assert_not_called()


# ---------------------------------------------------------------------------
# Test (d): 7 violations with cap=5 → exactly 5 writes + 5 calls + 2 capped
# ---------------------------------------------------------------------------


def test_d_cap_at_5(tmp_path, invariants):
    """With 7 violations and cap=5, exactly 5 are processed and 2 are skipped."""
    snapshot = {
        f"PROJ-{100 + i * 100}": {"dso_local_ids": [f"local-a{i}", f"local-b{i}"]}
        for i in range(7)
    }

    mock_store = _make_alert_store_mock(deduped_keys=set())
    mock_proc_result = _make_subprocess_result(returncode=0, stdout="bug-ticket-cap")

    with patch.object(invariants, "_load_alert_store", return_value=mock_store):
        with patch("invariants.subprocess.run", return_value=mock_proc_result) as mock_run:
            result = invariants.check_at_most_one_dso_local_id(
                snapshot, repo_root=tmp_path, ticket_cli="/fake/dso"
            )

    # Exactly 5 violations filed (cap enforced)
    assert len(result) == 5

    # Exactly 5 append calls
    assert mock_store.append.call_count == 5

    # Exactly 5 ticket-cli subprocess calls
    assert mock_run.call_count == 5

    # Exactly 5 patch_bug_filed calls
    assert mock_store.patch_bug_filed.call_count == 5
