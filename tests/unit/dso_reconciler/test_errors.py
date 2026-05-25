"""Tests for dso_reconciler._errors."""
import importlib.util
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
ERRORS_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "_errors.py"


def _load_errors():
    spec = importlib.util.spec_from_file_location("_errors", ERRORS_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def errs():
    return _load_errors()


def test_direction_mismatch_is_exception_subclass(errs):
    assert issubclass(errs.DirectionMismatchError, Exception)

def test_unknown_action_is_exception_subclass(errs):
    assert issubclass(errs.UnknownActionError, Exception)

def test_status_mapping_is_exception_subclass(errs):
    assert issubclass(errs.StatusMappingError, Exception)

def test_str_preserves_message(errs):
    for cls in (errs.DirectionMismatchError, errs.UnknownActionError, errs.StatusMappingError):
        e = cls("boom")
        assert str(e) == "boom"
