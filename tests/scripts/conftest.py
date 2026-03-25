"""Pytest fixtures for bridge field-coverage tests.

Constants and helper functions live in bridge_test_helpers.py — import from
there in test files.  This conftest.py only provides pytest fixtures that are
auto-discovered by pytest regardless of working directory.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType
from typing import Any
from unittest.mock import MagicMock

import pytest

# Ensure tests/scripts/ is on sys.path so that `from bridge_test_helpers import ...`
# works regardless of how pytest is invoked (e.g., from a non-root directory).
_TESTS_SCRIPTS_DIR = str(Path(__file__).resolve().parent)
if _TESTS_SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _TESTS_SCRIPTS_DIR)

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
OUTBOUND_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-outbound.py"
INBOUND_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-inbound.py"
ACLI_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "acli-integration.py"


def _load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def outbound() -> ModuleType:
    if not OUTBOUND_PATH.exists():
        pytest.fail(f"bridge-outbound.py not found at {OUTBOUND_PATH}")
    return _load_module("bridge_outbound", OUTBOUND_PATH)


@pytest.fixture(scope="module")
def inbound() -> ModuleType:
    if not INBOUND_PATH.exists():
        pytest.fail(f"bridge-inbound.py not found at {INBOUND_PATH}")
    return _load_module("bridge_inbound", INBOUND_PATH)


@pytest.fixture(scope="module")
def acli_mod() -> ModuleType:
    if not ACLI_PATH.exists():
        pytest.fail(f"acli-integration.py not found at {ACLI_PATH}")
    return _load_module("acli_integration", ACLI_PATH)


# ---------------------------------------------------------------------------
# ACLI capture fixture
# ---------------------------------------------------------------------------


@pytest.fixture
def acli_capture(
    acli_mod: ModuleType,
) -> tuple[Any, list[list[str]], Any]:
    """Provide an AcliClient with a fake _run_acli that captures commands.

    Returns:
        (client, captured_cmds, fake_run_acli) — the client is pre-configured
        with test credentials; captured_cmds accumulates every command list
        passed to _run_acli; fake_run_acli is the callable for use with
        patch.object.
    """
    captured_cmds: list[list[str]] = []

    def fake_run_acli(cmd: list[str], *, acli_cmd: list[str] | None = None) -> Any:
        captured_cmds.append(cmd)
        result = MagicMock()
        result.stdout = json.dumps({"key": "TEST-1"})
        return result

    client = acli_mod.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="TEST",
        acli_cmd=["echo"],
    )
    return client, captured_cmds, fake_run_acli
