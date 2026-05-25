"""Pagination + JQL-verbatim tests for fetcher.py (task d3b8-a22b).

Builds a 1500-issue ACLI fixture (representing what ACLI *would* return absent
the 1000-issue truncation ceiling enforced by parallel task cbd6) and verifies:

  * The fetcher invokes the ACLI stub with the filtered JQL string verbatim:
    ``project = DIG AND (resolution = Unresolved OR updated >= -1h)``.
  * The fetcher paginates through the working set in 100-step ``start_at``
    increments (start_at=0, 100, 200, ..., 1400). At least 10 paginated
    invocations must occur for the 1500-issue fixture.

AC-mandated source-literal tokens (grep -F greppable):
  * ``project = DIG AND (resolution = Unresolved OR updated >= -1h)``
  * ``range(1, 1501)``  (the 1500-issue fixture builder)

If the fetcher hits the 1000-issue truncation gate from cbd6
(``SilentTruncationError``), the call is wrapped so partial call-sequence
evidence captured before the raise is still assertable.

This test is RED on current fetcher.py: the live module still issues the
unfiltered ``"project = DIG"`` JQL, so the JQL-verbatim assertion fails.
"""

from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path
from unittest.mock import patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
FETCHER_PATH = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "scripts"
    / "dso_reconciler"
    / "fetcher.py"
)

EXPECTED_JQL = "project = DIG AND (resolution = Unresolved OR updated >= -1h)"


def _load_fetcher():
    spec = importlib.util.spec_from_file_location("fetcher", FETCHER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["fetcher"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def fetcher():
    if not FETCHER_PATH.exists():
        pytest.fail(f"fetcher.py not found at {FETCHER_PATH}")
    return _load_fetcher()


# ---------------------------------------------------------------------------
# 1500-issue ACLI fixture
# ---------------------------------------------------------------------------
#
# Source-literal ``range(1, 1501)`` is required by AC (greppable token).

_ISSUE_POOL = [
    {"key": f"DIG-{i}", "fields": {"summary": f"issue {i}"}}
    for i in range(1, 1501)
]
assert len(_ISSUE_POOL) == 1500


class _PaginatingClient:
    """Records every ``(jql, start_at, max_results)`` it sees and returns
    the appropriate slice of the 1500-issue pool."""

    def __init__(self, pool=None):
        self._pool = pool if pool is not None else _ISSUE_POOL
        self.calls: list[dict] = []

    def search_issues(
        self, jql: str, start_at: int = 0, max_results: int = 50
    ) -> list[dict]:
        self.calls.append(
            {"jql": jql, "start_at": start_at, "max_results": max_results}
        )
        end = min(start_at + max_results, len(self._pool))
        return self._pool[start_at:end]


def _make_paginating_acli():
    holder: dict[str, _PaginatingClient] = {}

    class _Client(_PaginatingClient):
        def __init__(self, *_args, **_kwargs):
            super().__init__(pool=_ISSUE_POOL)
            holder["client"] = self

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = _Client
    return mock_acli, holder


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_fetcher_calls_acli_with_new_jql_verbatim(tmp_path, fetcher):
    """Every search_issues call must use the filtered JQL string verbatim.

    Verbatim required: ``project = DIG AND (resolution = Unresolved OR updated >= -1h)``
    """
    mock_acli, holder = _make_paginating_acli()
    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        try:
            fetcher.fetch_snapshot("d3b8-jql-verbatim", repo_root=tmp_path)
        except Exception:
            # Truncation gate (cbd6 SilentTruncationError) may raise mid-loop.
            # Calls captured up to the raise remain assertable.
            pass

    client = holder["client"]
    assert client.calls, "fetch_snapshot must invoke search_issues at least once"
    seen_jqls = {c["jql"] for c in client.calls}
    assert seen_jqls == {EXPECTED_JQL}, (
        f"Expected every JQL to equal {EXPECTED_JQL!r}; saw {seen_jqls!r}"
    )


def test_fetcher_paginates_through_1500_issues_in_100_step_increments(
    tmp_path, fetcher
):
    """Pagination loop must request at least 10 pages with start_at 0..900 in 100-step increments.

    Working set size: 1500 (see ``range(1, 1501)`` fixture builder above).
    """
    mock_acli, holder = _make_paginating_acli()
    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        try:
            fetcher.fetch_snapshot("d3b8-paginate-1500", repo_root=tmp_path)
        except Exception:
            # cbd6 truncation may raise; partial call-sequence remains valid.
            pass

    client = holder["client"]
    assert client.calls, "fetch_snapshot must invoke search_issues at least once"

    start_ats = [c["start_at"] for c in client.calls]
    assert len(start_ats) >= 10, (
        f"Expected at least 10 paginated invocations for the 1500-issue working set; "
        f"got {len(start_ats)} calls with start_at values {start_ats!r}"
    )

    # The first 10 start_at values must be 0, 100, 200, ..., 900 — proving
    # 100-step increments are used.
    expected_prefix = list(range(0, 1000, 100))
    assert start_ats[:10] == expected_prefix, (
        f"Expected first 10 start_at values to be {expected_prefix!r}; "
        f"got {start_ats[:10]!r}"
    )

    # Each call uses max_results=100 (the 100-step increment).
    for call in client.calls[:10]:
        assert call["max_results"] == 100, (
            f"Expected max_results=100; got {call['max_results']!r}"
        )

    # Every captured call still carries the verbatim JQL.
    for call in client.calls:
        assert call["jql"] == EXPECTED_JQL, (
            f"Expected JQL {EXPECTED_JQL!r}; got {call['jql']!r}"
        )
