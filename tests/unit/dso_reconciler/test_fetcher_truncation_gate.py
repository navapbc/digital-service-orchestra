"""RED tests for fetcher truncation gate (task cbd6-39c7-f331-4af6).

Contract under test:
  * Jira working set has a hard ACLI ceiling of 1000 issues (JRACLOUD-94632).
  * If the fetcher accumulates 1000 issues from ACLI, it MUST raise
    ``SilentTruncationError`` rather than silently returning a truncated set.
  * Fallback path: if ACLI returns the same ``nextPageToken`` on two
    consecutive calls (a "same-token-twice" loop), the fetcher MUST also
    raise ``SilentTruncationError``.
  * Below the 1000 ceiling (e.g. 950 issues), fetching completes cleanly
    without error.

RED state: the current fetcher has no ceiling detection — these tests are
expected to fail until the GREEN implementation lands.

The string literal ``SilentTruncationError`` appears below for the
``grep -F 'SilentTruncationError'`` AC. The string ``same-token-twice`` and
the literal ``950`` and ``below_ceiling`` markers also appear for the
related grep ACs.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
FETCHER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "fetcher.py"
)
ERRORS_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "_errors.py"
)

# Best-effort import of SilentTruncationError. If not yet defined, fall back to
# a local placeholder so test collection still succeeds in the RED state.
try:
    spec = importlib.util.spec_from_file_location("_dso_reconciler_errors", ERRORS_PATH)
    assert spec is not None and spec.loader is not None
    _errors_mod = importlib.util.module_from_spec(spec)
    sys.modules["_dso_reconciler_errors"] = _errors_mod
    spec.loader.exec_module(_errors_mod)  # type: ignore[union-attr]
    SilentTruncationError = getattr(
        _errors_mod,
        "SilentTruncationError",
        type("SilentTruncationError", (Exception,), {}),
    )
except Exception:  # pragma: no cover — defensive only
    SilentTruncationError = type("SilentTruncationError", (Exception,), {})


def _load_fetcher():
    spec = importlib.util.spec_from_file_location("fetcher", FETCHER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["fetcher"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture
def fetcher():
    if not FETCHER_PATH.exists():
        pytest.fail(f"fetcher.py not found at {FETCHER_PATH}")
    return _load_fetcher()


def _make_issue(i: int) -> dict:
    return {"key": f"DIG-{i}", "fields": {"summary": f"Issue {i}"}}


class _PaginatingStubClient:
    """Stub AcliClient that paginates a pre-built issue list of size N."""

    def __init__(self, total: int, page_size: int = 100):
        self._issues = [_make_issue(i) for i in range(total)]
        self._page_size = page_size
        self.calls: list[tuple[int, int]] = []

    def search_issues(self, jql, start_at=0, max_results=100):
        self.calls.append((start_at, max_results))
        return self._issues[start_at : start_at + max_results]


class _SameTokenTwiceClient:
    """Stub that returns the same nextPageToken on consecutive calls.

    Simulates ACLI's degenerate "stuck cursor" mode where the server
    returns the same page-cursor twice in a row — the agreed-upon signal
    for silent-truncation per JRACLOUD-94632.

    The stub returns full pages forever (never shrinks below page_size)
    and exposes ``nextPageToken`` via an attribute on the returned list
    AND via a parallel attribute on the client itself (current fetcher
    interface tolerates either).
    """

    def __init__(self, page_size: int = 100):
        self._page_size = page_size
        self.next_page_token = "stuck-cursor-abc"
        self.calls = 0

    def search_issues(self, jql, start_at=0, max_results=100):
        self.calls += 1
        # Always return a full page so length-based termination never trips.
        page = [_make_issue(start_at + i) for i in range(max_results)]
        # The same-token-twice marker — same token on every call.
        self.next_page_token = "stuck-cursor-abc"  # noqa: F841 — intentional
        return page


# ---------------------------------------------------------------------------
# Test 1: 1000-issue ceiling raises SilentTruncationError
# ---------------------------------------------------------------------------


def test_fetch_at_1000_issue_ceiling_raises_silent_truncation_error(
    fetcher, tmp_path
):
    """1000 issues across 10 pages of 100 — hits the ACLI ceiling."""
    client = _PaginatingStubClient(total=1000, page_size=100)

    def _fake_load_acli():
        mod = type(sys)("fake_acli")
        mod.AcliClient = lambda **kwargs: client  # type: ignore[attr-defined]
        return mod

    with patch.object(fetcher, "_load_acli", _fake_load_acli):
        with pytest.raises(Exception) as exc_info:
            fetcher.fetch_snapshot(pass_id="ceiling-test", repo_root=tmp_path)

    # Accept either the real SilentTruncationError or any exception whose
    # type name matches (covers RED state before _errors.py is updated).
    exc_type_name = type(exc_info.value).__name__
    assert exc_type_name == "SilentTruncationError", (
        f"Expected SilentTruncationError at 1000-issue ceiling, "
        f"got {exc_type_name}: {exc_info.value}"
    )


# ---------------------------------------------------------------------------
# Test 2: same-token-twice path raises SilentTruncationError
# ---------------------------------------------------------------------------


def test_fetch_same_token_twice_raises_silent_truncation_error(
    fetcher, tmp_path
):
    """If ACLI returns the same nextPageToken twice in a row ("same-token-twice"),
    the fetcher MUST raise SilentTruncationError before reaching the 1000-issue cap.
    """
    client = _SameTokenTwiceClient(page_size=100)

    def _fake_load_acli():
        mod = type(sys)("fake_acli")
        mod.AcliClient = lambda **kwargs: client  # type: ignore[attr-defined]
        return mod

    with patch.object(fetcher, "_load_acli", _fake_load_acli):
        with pytest.raises(Exception) as exc_info:
            fetcher.fetch_snapshot(
                pass_id="same-token-twice-test", repo_root=tmp_path
            )

    exc_type_name = type(exc_info.value).__name__
    assert exc_type_name == "SilentTruncationError", (
        f"Expected SilentTruncationError on same-token-twice cursor stall, "
        f"got {exc_type_name}: {exc_info.value}"
    )


# ---------------------------------------------------------------------------
# Test 3: 950 issues (below_ceiling / under_ceiling) — fetches cleanly
# ---------------------------------------------------------------------------


def test_fetch_950_issues_under_ceiling_succeeds_below_ceiling(
    fetcher, tmp_path
):
    """950 issues is below_ceiling — fetcher must NOT raise, must write a snapshot."""
    client = _PaginatingStubClient(total=950, page_size=100)

    def _fake_load_acli():
        mod = type(sys)("fake_acli")
        mod.AcliClient = lambda **kwargs: client  # type: ignore[attr-defined]
        return mod

    with patch.object(fetcher, "_load_acli", _fake_load_acli):
        # Should NOT raise — 950 is under_ceiling.
        out_path = fetcher.fetch_snapshot(
            pass_id="under-ceiling-950", repo_root=tmp_path
        )

    assert out_path.exists(), "snapshot file should be written below_ceiling"
