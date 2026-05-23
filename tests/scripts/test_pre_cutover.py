"""Tests for pre_cutover.py — pre-cutover orchestrator that runs three step modules.

Tests patch _load_step so no real step modules are executed during testing.
"""

from __future__ import annotations

import importlib.util
import sys
from dataclasses import dataclass
from pathlib import Path
from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# Module loading via importlib (project convention — no package install)
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
PRE_CUTOVER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "pre_cutover.py"
)


def _load_pre_cutover():
    """Load pre_cutover module fresh for each test.

    Registers the module in sys.modules before exec so dataclasses can resolve
    annotations against the module's global namespace (required on Python 3.14+).
    """
    spec = importlib.util.spec_from_file_location("pre_cutover", PRE_CUTOVER_PATH)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["pre_cutover"] = mod
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.modules.pop("pre_cutover", None)
    return mod


# ---------------------------------------------------------------------------
# Helper: build a stub module whose run() returns a StepResult
# ---------------------------------------------------------------------------


def _make_stub_mod(name: str, ok: bool, message: str = "stub"):
    """Return a mock module whose run() returns a StepResult-like object."""
    mod = MagicMock()

    @dataclass
    class _StepResult:
        name: str
        ok: bool
        message: str
        details: str = ""

    mod.run.return_value = _StepResult(name=name, ok=ok, message=message)
    return mod


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_all_stubs_pass_exits_0(capsys):
    """When all three step stubs return ok=True, main() returns 0 and prints success."""
    pc = _load_pre_cutover()

    stubs = {
        "capability_check": _make_stub_mod("capability_check", ok=True),
        "forward_compat_probe": _make_stub_mod("forward_compat_probe", ok=True),
        "cursor_snapshot": _make_stub_mod("cursor_snapshot", ok=True),
    }

    def fake_load_step(name: str):
        return stubs[name]

    with patch.object(pc, "_load_step", side_effect=fake_load_step):
        exit_code = pc.main()

    assert exit_code == 0
    captured = capsys.readouterr()
    assert "OK: pre_cutover (3/3 steps passed)" in captured.out


def test_middle_step_fails_short_circuits(capsys):
    """When forward_compat_probe fails, main() returns 1 and cursor_snapshot is not called."""
    pc = _load_pre_cutover()

    capability_stub = _make_stub_mod("capability_check", ok=True)
    forward_stub = _make_stub_mod(
        "forward_compat_probe", ok=False, message="probe failed"
    )
    cursor_stub = _make_stub_mod("cursor_snapshot", ok=True)

    stubs = {
        "capability_check": capability_stub,
        "forward_compat_probe": forward_stub,
        "cursor_snapshot": cursor_stub,
    }

    def fake_load_step(name: str):
        return stubs[name]

    with patch.object(pc, "_load_step", side_effect=fake_load_step):
        exit_code = pc.main()

    assert exit_code == 1
    captured = capsys.readouterr()
    assert "FAIL: forward_compat_probe" in captured.err
    # cursor_snapshot stub should NOT have been called
    assert cursor_stub.run.call_count == 0
