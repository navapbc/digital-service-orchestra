"""Axis 2 (send path) — acli-integration.add_comment over-length guard.

Bug 6afc-20ee-84e5-4dd5. Jira Cloud's comment body limit is 32,767 chars and
``acli ... comment create`` exits 0 on an over-length rejection, so add_comment
must truncate the body BEFORE handing it to ACLI (mirroring _sanitize_summary).

Asserts OBSERVABLE behaviour: the body string actually placed in the ACLI
command list is within the limit, and a within-limit body is sent unchanged.

Module load + sys.path for the hyphenated acli-integration.py filename are
provided by tests/scripts/conftest.py.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
ACLI_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "acli-integration.py"

_JIRA_COMMENT_MAX_CHARS = 32767


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("acli_integration", ACLI_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def acli() -> ModuleType:
    return _load_module()


_OVERSIZE_BODY = "X" * 38015


@pytest.mark.unit
@pytest.mark.scripts
def test_add_comment_truncates_oversize_body_sent_to_acli(acli: ModuleType) -> None:
    """add_comment must hand ACLI a body within Jira's 32,767-char limit."""
    response = json.dumps({"id": "1", "body": "ok"})
    mock_proc = MagicMock(returncode=0, stdout=response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        acli.add_comment(jira_key="DIG-7000", body=_OVERSIZE_BODY)

    cmd = mock_run.call_args[0][0]
    assert "--body" in cmd, f"Expected --body flag in cmd: {cmd}"
    sent_body = cmd[cmd.index("--body") + 1]
    assert len(sent_body) <= _JIRA_COMMENT_MAX_CHARS, (
        f"Body sent to ACLI ({len(sent_body)} chars) exceeds Jira's "
        f"{_JIRA_COMMENT_MAX_CHARS}-char comment limit; add_comment must truncate."
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_add_comment_leaves_within_limit_body_unchanged(acli: ModuleType) -> None:
    """A within-limit body must be sent verbatim (no spurious truncation)."""
    body = "A normal-length human comment."
    response = json.dumps({"id": "1", "body": body})
    mock_proc = MagicMock(returncode=0, stdout=response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        acli.add_comment(jira_key="DIG-7001", body=body)

    cmd = mock_run.call_args[0][0]
    sent_body = cmd[cmd.index("--body") + 1]
    assert sent_body == body, (
        f"Within-limit body must be sent unchanged; got {sent_body!r}"
    )
