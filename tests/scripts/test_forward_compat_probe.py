"""Tests for forward_compat_probe.py — 4-sub-op forward-compatibility probe.

All tests mock _load_acli_client so no real network calls are made.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# Module loading via importlib (project convention — no package install)
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE_PATH = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "scripts"
    / "dso_reconciler"
    / "forward_compat_probe.py"
)


def _load_forward_compat_probe():
    """Load forward_compat_probe module fresh for each test."""
    spec = importlib.util.spec_from_file_location("forward_compat_probe", PROBE_PATH)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["forward_compat_probe"] = mod
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.modules.pop("forward_compat_probe", None)
    return mod


# ---------------------------------------------------------------------------
# Helper: build a mock AcliClient class that returns a configured instance
# ---------------------------------------------------------------------------


def _make_mock_client_class(
    *,
    issue_key: str = "TEST-123",
    property_value: str | None = None,
    search_results: list | None = None,
    set_issue_property_side_effect=None,
    direct_rest_put_side_effect=None,
    direct_rest_put_raw_side_effect=None,
    get_issue_property_side_effect=None,
    delete_side_effect=None,
) -> tuple[MagicMock, MagicMock]:
    """Return (MockClass, mock_instance) with sensible defaults."""
    instance = MagicMock()
    # forward_compat_probe.run() calls result.get("key") on the create_issue
    # return value — must be a dict, not a bare string.
    instance.create_issue.return_value = {"key": issue_key}

    if search_results is None:
        search_results = [{"key": issue_key}]
    instance.search_issues.return_value = search_results

    if set_issue_property_side_effect is not None:
        instance.set_issue_property.side_effect = set_issue_property_side_effect
    else:
        instance.set_issue_property.return_value = None

    if direct_rest_put_side_effect is not None:
        instance._direct_rest_put.side_effect = direct_rest_put_side_effect
    else:
        instance._direct_rest_put.return_value = None

    # forward_compat_probe.run() uses _direct_rest_put_raw for label updates
    # (raw PUT body, not the issue-properties wrapper).
    if direct_rest_put_raw_side_effect is not None:
        instance._direct_rest_put_raw.side_effect = direct_rest_put_raw_side_effect
    else:
        instance._direct_rest_put_raw.return_value = None

    if get_issue_property_side_effect is not None:
        instance.get_issue_property.side_effect = get_issue_property_side_effect
    elif property_value is not None:
        instance.get_issue_property.return_value = property_value
    # else: get_issue_property returns a MagicMock (we'll configure per test)

    if delete_side_effect is not None:
        instance.delete_issue.side_effect = delete_side_effect
    else:
        instance.delete_issue.return_value = {"status": "deleted", "key": issue_key}

    mock_class = MagicMock(return_value=instance)
    return mock_class, instance


# ---------------------------------------------------------------------------
# Env fixture
# ---------------------------------------------------------------------------

VALID_ENV = {
    "JIRA_URL": "https://jira.example.com",
    "JIRA_USER": "test@example.com",
    "JIRA_API_TOKEN": "test-token-abc",
}


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_all_four_sub_ops_pass(monkeypatch):
    """All 4 sub-operations succeed — probe returns ok=True with 4 passing entries."""
    for key, val in VALID_ENV.items():
        monkeypatch.setenv(key, val)

    mod = _load_forward_compat_probe()

    # get_issue_property must return the *same* uuid that was passed to set_issue_property
    captured_uuid: list[str] = []

    def capture_set(issue_key, prop_key, value):
        captured_uuid.append(value)

    def return_captured(issue_key, prop_key):
        return captured_uuid[0] if captured_uuid else "wrong-uuid"

    mock_class, instance = _make_mock_client_class(issue_key="TEST-123")
    instance.set_issue_property.side_effect = capture_set
    instance.get_issue_property.side_effect = return_captured

    with patch.object(mod, "_load_acli_client", return_value=mock_class):
        result = mod.run()

    assert result.ok is True
    assert "4 sub-operations" in result.message
    sub_ops = result.details.get("sub_operations", [])
    assert len(sub_ops) == 4
    for entry in sub_ops:
        assert entry["ok"] is True, f"sub-op {entry.get('op')} was not ok: {entry}"


def test_missing_credentials_returns_fail(monkeypatch):
    """Missing JIRA_URL causes immediate ok=False with credentials message."""
    monkeypatch.setenv("JIRA_USER", "test@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", "test-token-abc")
    monkeypatch.delenv("JIRA_URL", raising=False)

    mod = _load_forward_compat_probe()
    result = mod.run()

    assert result.ok is False
    assert "missing Jira credentials" in result.message


def test_label_write_failure_short_circuits(monkeypatch):
    """label_write failure causes ok=False with 'label_write' in message; only 1 sub_op entry."""
    for key, val in VALID_ENV.items():
        monkeypatch.setenv(key, val)

    mod = _load_forward_compat_probe()

    mock_class, instance = _make_mock_client_class(
        issue_key="TEST-123",
        # label_write now goes through _direct_rest_put_raw (raw body PUT).
        direct_rest_put_raw_side_effect=RuntimeError("403 Forbidden"),
    )

    with patch.object(mod, "_load_acli_client", return_value=mock_class):
        result = mod.run()

    assert result.ok is False
    assert "label_write" in result.message
    sub_ops = result.details.get("sub_operations", [])
    assert len(sub_ops) == 1
    assert sub_ops[0]["op"] == "label_write"
    assert sub_ops[0]["ok"] is False


def test_delete_called_even_on_failure(monkeypatch):
    """delete_issue is called exactly once with the created issue key, even when property_write fails."""
    for key, val in VALID_ENV.items():
        monkeypatch.setenv(key, val)

    mod = _load_forward_compat_probe()

    # property_write raises after create succeeds
    mock_class, instance = _make_mock_client_class(
        issue_key="TEST-123",
        set_issue_property_side_effect=RuntimeError("property write failed"),
    )

    with patch.object(mod, "_load_acli_client", return_value=mock_class):
        result = mod.run()

    assert result.ok is False
    # delete_issue must have been called once with the created key
    instance.delete_issue.assert_called_once_with("TEST-123")


def test_jira_project_falls_back_when_env_var_empty(monkeypatch):
    """Empty-string JIRA_PROJECT (e.g. blank CI secret) falls back to 'DIG' rather than
    being passed through as an empty project key."""
    for key, val in VALID_ENV.items():
        monkeypatch.setenv(key, val)
    # The footgun the fix defends against: os.environ.get("X", "DIG") returns "" if
    # JIRA_PROJECT is set to empty; we expect `or "DIG"` to coerce that back to "DIG".
    monkeypatch.setenv("JIRA_PROJECT", "")

    mod = _load_forward_compat_probe()
    mock_class, instance = _make_mock_client_class(issue_key="TEST-EMPTY")
    instance.set_issue_property.side_effect = lambda *a, **k: None
    instance.get_issue_property.side_effect = lambda *a, **k: "dummy"

    with patch.object(mod, "_load_acli_client", return_value=mock_class):
        mod.run()

    # We only inspect the call args — the probe's ok/fail status is
    # incidental to the JIRA_PROJECT fallback semantics being verified.
    main_construct = mock_class.call_args_list[0]
    assert main_construct.kwargs.get("jira_project") == "DIG", (
        "Empty-string JIRA_PROJECT must fall back to default 'DIG', "
        f"got jira_project={main_construct.kwargs.get('jira_project')!r}"
    )


def test_cleanup_client_uses_same_jira_project_as_main_path(monkeypatch):
    """The finally-block AcliClient must be constructed with the same jira_project as
    the main-path client, so any future cleanup logic that consults self.jira_project
    targets the right project."""
    for key, val in VALID_ENV.items():
        monkeypatch.setenv(key, val)
    monkeypatch.setenv("JIRA_PROJECT", "CUSTOM")

    mod = _load_forward_compat_probe()
    mock_class, instance = _make_mock_client_class(issue_key="TEST-CLEAN")
    instance.set_issue_property.side_effect = lambda *a, **k: None
    instance.get_issue_property.side_effect = lambda *a, **k: "dummy"

    with patch.object(mod, "_load_acli_client", return_value=mock_class):
        mod.run()

    # Two AcliClient constructions: main-path (line ~57) and cleanup (line ~161).
    # Both must use jira_project=CUSTOM.
    assert len(mock_class.call_args_list) >= 2, (
        f"Expected >=2 AcliClient constructions, got {len(mock_class.call_args_list)}"
    )
    for i, call in enumerate(mock_class.call_args_list):
        assert call.kwargs.get("jira_project") == "CUSTOM", (
            f"AcliClient call #{i} used jira_project={call.kwargs.get('jira_project')!r}, expected 'CUSTOM'"
        )
