"""Behavioral tests for dso_reconciler.__main__ entry module.

Tests cover:
  - test_exits_zero_on_converged_stub_path: ``python -m dso_reconciler`` exits 0
    when no pipeline step modules are present (pure walking-skeleton path).
  - test_run_pass_returns_0_when_all_steps_absent: run_pass() returns 0 directly
    when all sibling modules are missing (subprocess-free fast path).
  - test_run_pass_returns_0_when_step_run_returns_0: run_pass() returns 0 when
    a monkeypatched step module's run() returns 0.
  - test_run_pass_returns_1_when_step_run_returns_nonzero: run_pass() returns 1
    when a step's run() returns non-zero.
  - test_run_pass_returns_1_when_step_raises: run_pass() returns 1 and does not
    propagate the exception when a step's run() raises.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
MAIN_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "__main__.py"
)
RECONCILER_PKG = REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler"


def _load_main_module():
    """Load __main__.py as a named module for patching."""
    spec = importlib.util.spec_from_file_location("dso_reconciler.__main__", MAIN_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["dso_reconciler.__main__"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def main_mod():
    """Load the __main__ module, failing all tests if absent."""
    if not MAIN_PATH.exists():
        pytest.fail(
            f"__main__.py not found at {MAIN_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_main_module()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_exits_zero_on_converged_stub_path():
    """``python -m dso_reconciler`` exits 0 when invoked in a directory where
    none of the optional pipeline step modules (fetcher, differ, …) exist.

    Uses subprocess so the full interpreter path is exercised.  The scripts/
    directory containing the ``dso_reconciler`` package is added to PYTHONPATH
    so the module is importable without installation.
    """
    scripts_dir = str(RECONCILER_PKG.parent)
    env = {**__import__("os").environ, "PYTHONPATH": scripts_dir}
    result = subprocess.run(
        [sys.executable, "-m", "dso_reconciler"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"Expected exit 0 but got {result.returncode}.\n"
        f"stdout: {result.stdout!r}\n"
        f"stderr: {result.stderr!r}"
    )


def test_run_pass_returns_0_when_all_steps_absent(main_mod):
    """run_pass() returns 0 when _try_load_step returns None for every step.

    This simulates the walking-skeleton path: no pipeline modules implemented yet.
    """
    with patch.object(main_mod, "_try_load_step", return_value=None):
        rc = main_mod.run_pass()
    assert rc == 0


def test_run_pass_returns_0_when_step_run_returns_0(main_mod):
    """run_pass() returns 0 when a stubbed pipeline step's run() returns 0."""
    stub_mod = types.ModuleType("stub_fetcher")
    stub_mod.run = MagicMock(return_value=0)  # type: ignore[attr-defined]

    call_count = 0

    def _fake_load(name: str):
        nonlocal call_count
        if name == "fetcher":
            call_count += 1
            return stub_mod
        return None

    with patch.object(main_mod, "_try_load_step", side_effect=_fake_load):
        rc = main_mod.run_pass()

    assert rc == 0
    assert call_count == 1
    stub_mod.run.assert_called_once()


def test_run_pass_returns_1_when_step_run_returns_nonzero(main_mod):
    """run_pass() returns 1 when a pipeline step's run() returns a non-zero code."""
    stub_mod = types.ModuleType("stub_differ")
    stub_mod.run = MagicMock(return_value=2)  # type: ignore[attr-defined]

    def _fake_load(name: str):
        if name == "differ":
            return stub_mod
        return None

    with patch.object(main_mod, "_try_load_step", side_effect=_fake_load):
        rc = main_mod.run_pass()

    assert rc == 1


def test_run_pass_returns_1_when_step_raises(main_mod):
    """run_pass() returns 1 and does not re-raise when a step's run() raises."""
    stub_mod = types.ModuleType("stub_applier")
    stub_mod.run = MagicMock(side_effect=RuntimeError("boom"))  # type: ignore[attr-defined]

    def _fake_load(name: str):
        if name == "applier":
            return stub_mod
        return None

    with patch.object(main_mod, "_try_load_step", side_effect=_fake_load):
        rc = main_mod.run_pass()

    assert rc == 1
