"""Unit tests for _concurrency.py.

Tests cover:
  - test_snapshot_head_returns_nonempty_string: snapshot_head() on a real tmp
    git repo returns a non-empty hex SHA string.
  - test_rebase_retry_ok_when_write_succeeds: rebase_retry() returns
    Result(ok=True) when write_fn succeeds and HEAD is stable.
  - test_rebase_retry_abort_due_to_error: rebase_retry() returns
    Result(ok=False, event.kind='abort_due_to_error') when write_fn raises.
  - test_rebase_retry_abort_due_to_drift: rebase_retry() returns
    Result(ok=False, event.kind='abort_due_to_drift') when HEAD changes between
    the before-capture and the after-check.
  - test_concurrency_event_kind_values: ConcurrencyEvent accepts each of the
    three expected kind strings without error.
"""

from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "_concurrency.py"
)


def _load_module() -> ModuleType:
    import sys

    spec = importlib.util.spec_from_file_location("_concurrency", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    # Register in sys.modules before exec so that dataclass annotation resolution
    # (which calls sys.modules.get(cls.__module__)) works in Python 3.14+.
    sys.modules["_concurrency"] = mod
    try:
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
    except Exception:
        sys.modules.pop("_concurrency", None)
        raise
    return mod


@pytest.fixture(scope="module")
def concurrency() -> ModuleType:
    """Return the _concurrency module; fail all tests if absent."""
    if not MODULE_PATH.exists():
        pytest.fail(
            f"_concurrency.py not found at {MODULE_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


@pytest.fixture()
def tmp_git_repo(tmp_path: Path) -> Path:
    """Create a minimal git repository with one commit and return its root."""
    subprocess.run(["git", "init", str(tmp_path)], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(tmp_path), "config", "user.email", "test@example.com"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(tmp_path), "config", "user.name", "Test"],
        check=True,
        capture_output=True,
    )
    readme = tmp_path / "README.md"
    readme.write_text("hello\n")
    subprocess.run(
        ["git", "-C", str(tmp_path), "add", "README.md"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(tmp_path), "commit", "-m", "init"],
        check=True,
        capture_output=True,
    )
    return tmp_path


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_snapshot_head_returns_nonempty_string(concurrency, tmp_git_repo: Path) -> None:
    """snapshot_head() on a real tmp git repo returns a non-empty hex string."""
    sha = concurrency.snapshot_head(tmp_git_repo)
    assert isinstance(sha, str)
    assert len(sha) > 0
    # Should look like a hex SHA (at least 7 chars)
    assert all(c in "0123456789abcdef" for c in sha.lower())


def test_rebase_retry_ok_when_write_succeeds(concurrency, tmp_git_repo: Path) -> None:
    """rebase_retry() returns Result(ok=True) when write_fn succeeds and HEAD is stable."""
    sentinel = object()

    def write_fn():
        return sentinel

    result = concurrency.rebase_retry(tmp_git_repo, write_fn)
    assert result.ok is True
    assert result.event is None
    assert result.value is sentinel


def test_rebase_retry_abort_due_to_error(concurrency, tmp_git_repo: Path) -> None:
    """rebase_retry() returns Result(ok=False, event.kind='abort_due_to_error') when write_fn raises."""

    def write_fn():
        raise RuntimeError("simulated write failure")

    result = concurrency.rebase_retry(tmp_git_repo, write_fn)
    assert result.ok is False
    assert result.event is not None
    assert result.event.kind == "abort_due_to_error"
    assert "simulated write failure" in result.event.message
    assert result.event.attempt == 1


def test_rebase_retry_abort_due_to_drift(concurrency, tmp_git_repo: Path) -> None:
    """rebase_retry() returns Result(ok=False, event.kind='abort_due_to_drift')
    when HEAD changes between the before-capture and the after-check."""
    # snapshot_head is called twice per attempt: once before, once after.
    # We return different SHAs to simulate concurrent write on the tickets branch.
    sha_before = "aabbccdd" * 5  # 40 chars
    sha_after = "11223344" * 5   # 40 chars, different

    call_counter = {"n": 0}

    def fake_snapshot_head(repo_root):  # noqa: ARG001
        call_counter["n"] += 1
        if call_counter["n"] % 2 == 1:
            return sha_before
        return sha_after

    def write_fn():
        return "write_result"

    with patch.object(
        importlib.import_module("_concurrency") if False else concurrency,
        "snapshot_head",
        side_effect=fake_snapshot_head,
    ):
        # We need to patch at the module level — use the loaded module directly
        original_snapshot_head = concurrency.snapshot_head
        concurrency.snapshot_head = fake_snapshot_head
        try:
            result = concurrency.rebase_retry(tmp_git_repo, write_fn)
        finally:
            concurrency.snapshot_head = original_snapshot_head

    assert result.ok is False
    assert result.event is not None
    assert result.event.kind == "abort_due_to_drift"
    assert "aabbccdd" in result.event.message
    assert "11223344" in result.event.message


def test_concurrency_event_kind_values(concurrency) -> None:
    """ConcurrencyEvent accepts each of the three expected kind strings."""
    for kind in ("abort_due_to_drift", "reject_and_reschedule", "abort_due_to_error"):
        evt = concurrency.ConcurrencyEvent(kind=kind, message="test", attempt=1)
        assert evt.kind == kind
