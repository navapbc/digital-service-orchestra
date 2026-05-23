"""Unit tests for _attestation.py — verify_attested_commit().

Tests cover:
  - test_returns_true_for_valid_human_signed_commit: verify-commit exits 0,
    committer email not in allowlist → True.
  - test_returns_false_for_bot_signed_commit: verify-commit exits 0 but email
    IS in allowlist → False.
  - test_returns_false_when_verify_commit_fails: verify-commit exits nonzero → False.
  - test_returns_false_on_subprocess_error: verify-commit raises exception → False.
"""

from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
ATTESTATION_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "_attestation.py"
)


def _load_attestation() -> ModuleType:
    spec = importlib.util.spec_from_file_location("_attestation", ATTESTATION_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def attestation() -> ModuleType:
    """Return the _attestation module; fail all tests if absent."""
    if not ATTESTATION_PATH.exists():
        pytest.fail(
            f"_attestation.py not found at {ATTESTATION_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_attestation()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

_BOT_ALLOWLIST = ["bot@example.com", "ci-bot@github.com"]
_HUMAN_EMAIL = "human@example.com"
_SHA = "abc123def456"


def _make_completed_process(returncode: int, stdout: str = "") -> MagicMock:
    """Build a mock CompletedProcess with the given returncode and stdout."""
    mock = MagicMock(spec=subprocess.CompletedProcess)
    mock.returncode = returncode
    mock.stdout = stdout
    return mock


def test_returns_true_for_valid_human_signed_commit(attestation):
    """verify-commit exits 0 and committer is not a bot → True."""
    verify_ok = _make_completed_process(returncode=0)
    log_ok = _make_completed_process(returncode=0, stdout=f"{_HUMAN_EMAIL}\n")

    with patch("subprocess.run", side_effect=[verify_ok, log_ok]) as mock_run:
        result = attestation.verify_attested_commit(_SHA, _BOT_ALLOWLIST)

    assert result is True
    assert mock_run.call_count == 2
    # First call should be git verify-commit
    first_call_args = mock_run.call_args_list[0][0][0]
    assert "verify-commit" in first_call_args
    assert _SHA in first_call_args
    # Second call should be git log for email
    second_call_args = mock_run.call_args_list[1][0][0]
    assert "log" in second_call_args
    assert "%ae" in " ".join(second_call_args)


def test_returns_false_for_bot_signed_commit(attestation):
    """verify-commit exits 0 but committer email is in allowlist → False."""
    verify_ok = _make_completed_process(returncode=0)
    log_ok = _make_completed_process(returncode=0, stdout="bot@example.com\n")

    with patch("subprocess.run", side_effect=[verify_ok, log_ok]):
        result = attestation.verify_attested_commit(_SHA, _BOT_ALLOWLIST)

    assert result is False


def test_returns_false_when_verify_commit_fails(attestation):
    """verify-commit exits nonzero → False without calling git log."""
    verify_fail = _make_completed_process(returncode=1)

    with patch("subprocess.run", side_effect=[verify_fail]) as mock_run:
        result = attestation.verify_attested_commit(_SHA, _BOT_ALLOWLIST)

    assert result is False
    # Should short-circuit — git log should not be called
    assert mock_run.call_count == 1


def test_returns_false_on_subprocess_error(attestation):
    """subprocess.run raises an exception for verify-commit → False."""
    with patch("subprocess.run", side_effect=OSError("git not found")):
        result = attestation.verify_attested_commit(_SHA, _BOT_ALLOWLIST)

    assert result is False
