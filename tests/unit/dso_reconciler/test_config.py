"""Unit tests for dso_reconciler/config.py — EXCLUDED_FIELDS constant.

Tests cover:
  - test_excluded_fields_is_tuple: EXCLUDED_FIELDS is a tuple.
  - test_excluded_fields_has_exactly_two_elements: EXCLUDED_FIELDS has exactly 2 elements.
  - test_excluded_fields_contains_dso_local_id: EXCLUDED_FIELDS contains 'dso_local_id'.
  - test_excluded_fields_contains_dso_id: EXCLUDED_FIELDS contains 'dso-id'.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
CONFIG_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "config.py"
)


def _load_config() -> ModuleType:
    spec = importlib.util.spec_from_file_location("config", CONFIG_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def config() -> ModuleType:
    return _load_config()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_excluded_fields_is_tuple(config: ModuleType) -> None:
    assert isinstance(config.EXCLUDED_FIELDS, tuple)


def test_excluded_fields_has_exactly_two_elements(config: ModuleType) -> None:
    assert len(config.EXCLUDED_FIELDS) == 2


def test_excluded_fields_contains_dso_local_id(config: ModuleType) -> None:
    assert 'dso_local_id' in config.EXCLUDED_FIELDS


def test_excluded_fields_contains_dso_id(config: ModuleType) -> None:
    assert 'dso-id' in config.EXCLUDED_FIELDS
