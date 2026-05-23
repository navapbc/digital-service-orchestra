"""Tests for dso_reconciler/fetcher.py fetch_snapshot().

Covers:
- File is written to the correct path
- Output is valid JSON
- Two calls with identical stub data produce byte-identical files (determinism)
- Errors from AcliClient.search_issues() propagate out
"""

from __future__ import annotations

import importlib.util
import json
import sys
import types
from pathlib import Path
from unittest.mock import patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
FETCHER_PATH = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "scripts"
    / "dso_reconciler"
    / "fetcher.py"
)


def _load_fetcher():
    spec = importlib.util.spec_from_file_location("fetcher", FETCHER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["fetcher"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def fetcher():
    """Load the fetcher module, failing all tests if absent."""
    if not FETCHER_PATH.exists():
        pytest.fail(
            f"fetcher.py not found at {FETCHER_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_fetcher()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_mock_acli(issues: list[dict]) -> types.ModuleType:
    """Return a stub acli_integration module whose AcliClient.search_issues() returns issues."""

    class _MockClient:
        def __init__(self, jira_url, user, api_token, **kwargs):
            pass

        def search_issues(self, jql: str, **kwargs) -> list[dict]:
            return list(issues)

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = _MockClient
    return mock_acli


def _make_sample_issues() -> list[dict]:
    """Return a small but realistic list of stub Jira issues."""
    return [
        {
            "key": "DIG-1",
            "fields": {
                "summary": "First issue",
                "status": {"name": "To Do"},
                "issuetype": {"name": "Story"},
            },
        },
        {
            "key": "DIG-2",
            "fields": {
                "summary": "Second issue",
                "assignee": None,
                "status": {"name": "In Progress"},
                "issuetype": {"name": "Task"},
            },
        },
    ]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_snapshot_written_to_correct_path(tmp_path, fetcher):
    """fetch_snapshot writes the file to bridge_state/snapshots/<pass_id>.json."""
    pass_id = "2026-05-22-pass-01"
    mock_acli = _make_mock_acli(_make_sample_issues())

    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        result_path = fetcher.fetch_snapshot(pass_id, repo_root=tmp_path)

    expected_path = tmp_path / "bridge_state" / "snapshots" / f"{pass_id}.json"
    assert result_path == expected_path, (
        f"Expected path {expected_path}, got {result_path}"
    )
    assert expected_path.exists(), "Snapshot file was not created"


def test_snapshot_is_valid_json(tmp_path, fetcher):
    """fetch_snapshot produces a file that parses as valid JSON."""
    pass_id = "2026-05-22-pass-02"
    mock_acli = _make_mock_acli(_make_sample_issues())

    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        result_path = fetcher.fetch_snapshot(pass_id, repo_root=tmp_path)

    content = result_path.read_text()
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        pytest.fail(f"Snapshot file is not valid JSON: {exc}")

    assert isinstance(parsed, dict), "Top-level JSON value must be a dict"
    assert "DIG-1" in parsed
    assert "DIG-2" in parsed


def test_snapshot_is_deterministic(tmp_path, fetcher):
    """Two fetch_snapshot calls with identical stub data produce byte-identical files."""
    pass_id_a = "2026-05-22-pass-03a"
    pass_id_b = "2026-05-22-pass-03b"
    issues = _make_sample_issues()

    mock_acli = _make_mock_acli(issues)

    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        path_a = fetcher.fetch_snapshot(pass_id_a, repo_root=tmp_path)

    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        path_b = fetcher.fetch_snapshot(pass_id_b, repo_root=tmp_path)

    content_a = path_a.read_bytes()
    content_b = path_b.read_bytes()
    assert content_a == content_b, (
        "Two fetches with identical data must produce byte-identical snapshots"
    )


def test_snapshot_field_keys_are_sorted(tmp_path, fetcher):
    """Normalized issue fields are stored with sorted keys for determinism."""
    pass_id = "2026-05-22-pass-04"
    # Issue with intentionally unsorted fields
    issues = [
        {
            "key": "DIG-99",
            "fields": {
                "zzz_last": "last",
                "aaa_first": "first",
                "mmm_middle": "middle",
            },
        }
    ]
    mock_acli = _make_mock_acli(issues)

    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        result_path = fetcher.fetch_snapshot(pass_id, repo_root=tmp_path)

    parsed = json.loads(result_path.read_text())
    field_keys = list(parsed["DIG-99"].keys())
    assert field_keys == sorted(field_keys), (
        f"Field keys are not sorted: {field_keys}"
    )


def test_fetcher_paginates_through_full_result_set(tmp_path, fetcher):
    """F4 regression: fetch_snapshot must paginate to capture issues beyond page 1.

    Before F4, fetch_snapshot called search_issues without start_at/max_results,
    so AcliClient's default max_results=50 silently truncated snapshots to
    50 issues and the next pass emitted spurious delete mutations for the rest.

    The fix issues paginated calls with max_results=100; the loop terminates
    when a page is shorter than the requested size. This test simulates
    3 pages of 100, 100, 50 (250 total) and asserts every issue lands in the
    snapshot file.
    """

    class _PaginatingClient:
        def __init__(self, jira_url, user, api_token, **kwargs):
            self.calls: list[dict] = []

        def search_issues(self, jql: str, start_at: int = 0, max_results: int = 50):
            self.calls.append({"start_at": start_at, "max_results": max_results})
            # Total of 250 issues across three pages: 100, 100, 50
            all_issues = [
                {"key": f"DIG-{i}", "fields": {"summary": f"issue {i}"}}
                for i in range(250)
            ]
            return all_issues[start_at : start_at + max_results]

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = _PaginatingClient

    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        result_path = fetcher.fetch_snapshot(
            "2026-05-22-pass-pagination", repo_root=tmp_path
        )

    parsed = json.loads(result_path.read_text())
    assert len(parsed) == 250, (
        f"Snapshot must contain all 250 issues across paginated pages; "
        f"got {len(parsed)} (first-50 truncation regressed?)"
    )
    # Sanity: both the first and a late issue appear
    assert "DIG-0" in parsed
    assert "DIG-249" in parsed


def test_search_issues_error_propagates(tmp_path, fetcher):
    """Errors raised by AcliClient.search_issues() propagate out of fetch_snapshot."""

    class _ErrorClient:
        def __init__(self, jira_url, user, api_token, **kwargs):
            pass

        def search_issues(self, jql: str, **kwargs):
            raise RuntimeError("ACLI connection refused")

    mock_acli = types.ModuleType("acli_integration")
    mock_acli.AcliClient = _ErrorClient

    with patch.object(fetcher, "_load_acli", return_value=mock_acli):
        with pytest.raises(RuntimeError, match="ACLI connection refused"):
            fetcher.fetch_snapshot("2026-05-22-pass-05", repo_root=tmp_path)
