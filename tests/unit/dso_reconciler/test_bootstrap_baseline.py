"""Unit tests for bootstrap.py — baseline capture ordering and call-count invariants.

Tests cover:
  - test_capture_baseline_called_before_band_apply: capture_baseline() is
    invoked before any band's apply() would be called during run_bootstrap().
  - test_capture_baseline_called_exactly_once: run_bootstrap() calls
    capture_baseline() exactly once per invocation regardless of band count.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
BOOTSTRAP_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "bootstrap.py"
)


def _load_bootstrap() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bootstrap", BOOTSTRAP_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    # Ensure fresh load each time (avoid stale sys.modules cache)
    sys.modules.pop("bootstrap", None)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture()
def bootstrap() -> ModuleType:
    return _load_bootstrap()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_capture_baseline_called_before_band_apply(
    bootstrap: ModuleType, tmp_path: Path
) -> None:
    """capture_baseline() must be invoked before any band's apply() step.

    We simulate a scenario where a band module has an apply() function and
    verify that capture_baseline() was already called by the time any
    apply() would run.  Because run_bootstrap() only calls each band's plan
    step (not apply directly), we assert ordering via call sequence on a
    shared call log injected through _load().
    """
    call_log: list[str] = []

    # Build a fake health module
    fake_health = MagicMock()

    def _baseline_side_effect(pass_id: str, repo_root=None) -> Path:
        call_log.append("capture_baseline")
        return tmp_path / "bridge_state" / "health" / f"{pass_id}_baseline.json"

    fake_health.capture_baseline.side_effect = _baseline_side_effect

    # Build a fake band module that logs when it is loaded
    fake_band = MagicMock()

    def _fake_load(name: str, filename: str) -> MagicMock:
        if filename == "health.py":
            return fake_health
        # For any band module, record its loading
        call_log.append(f"band_load:{filename}")
        return fake_band

    # Patch the internal _load helper in bootstrap
    with patch.object(bootstrap, "_load", side_effect=_fake_load):
        result = bootstrap.run_bootstrap("pass-order-001", repo_root=tmp_path)

    # capture_baseline must appear before any band is loaded/executed
    assert "capture_baseline" in call_log, "capture_baseline was never called"
    band_indices = [
        i for i, entry in enumerate(call_log) if entry.startswith("band_load:")
    ]
    if band_indices:
        baseline_index = call_log.index("capture_baseline")
        assert baseline_index < min(band_indices), (
            "capture_baseline() was called AFTER a band was loaded; "
            f"call_log={call_log}"
        )

    # Basic sanity: result has expected shape
    assert result["pass_id"] == "pass-order-001"
    assert "bands" in result


def test_capture_baseline_called_exactly_once(
    bootstrap: ModuleType, tmp_path: Path
) -> None:
    """run_bootstrap() calls capture_baseline() exactly once per invocation."""
    fake_health = MagicMock()
    fake_health.capture_baseline.return_value = (
        tmp_path / "bridge_state" / "health" / "pass-once-001_baseline.json"
    )
    fake_band = MagicMock()

    def _fake_load(name: str, filename: str) -> MagicMock:
        if filename == "health.py":
            return fake_health
        return fake_band

    with patch.object(bootstrap, "_load", side_effect=_fake_load):
        bootstrap.run_bootstrap("pass-once-001", repo_root=tmp_path)

    assert fake_health.capture_baseline.call_count == 1, (
        f"Expected capture_baseline() called once, got "
        f"{fake_health.capture_baseline.call_count}"
    )
    # Verify it was called with the correct pass_id
    fake_health.capture_baseline.assert_called_once_with(
        "pass-once-001", repo_root=tmp_path
    )
