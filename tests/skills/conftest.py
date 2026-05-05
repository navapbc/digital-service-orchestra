"""Root conftest for tests/skills/.

Ensures plugins/dso/scripts is at the FRONT of sys.path so that
``import dso_ci_review`` resolves to the plugin package rather than the
test-package directory of the same name (tests/skills/dso_ci_review/).

Implementation note: path setup runs in BOTH the module-level scope (early
collection) AND in ``pytest_configure`` (which runs before module imports
in pytest's collection phase) to handle both direct pytest invocations and
cases where pytest inserts the test-package root mid-collection.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")


def _install_scripts_path() -> None:
    """Ensure the plugin scripts dir is at the front of sys.path and evict shadows."""
    # Remove stale occurrence of _SCRIPTS_DIR so we can re-insert at position 0.
    while _SCRIPTS_DIR in sys.path:
        sys.path.remove(_SCRIPTS_DIR)
    sys.path.insert(0, _SCRIPTS_DIR)

    # Evict any test-package shadow of dso_ci_review so subsequent imports
    # resolve to the plugin package.  We keep entries whose __file__ is already
    # under _SCRIPTS_DIR (they are legitimate), and entries that don't have a
    # __file__ at all (namespace packages, mocks, etc.).
    for _key in list(sys.modules):
        if _key == "dso_ci_review" or _key.startswith("dso_ci_review."):
            _file = getattr(sys.modules[_key], "__file__", None) or ""
            if _file and _SCRIPTS_DIR not in _file:
                del sys.modules[_key]


def pytest_configure(config: pytest.Config) -> None:  # noqa: ARG001
    """Re-run path setup after pytest has finished its own sys.path manipulation.

    pytest inserts the rootdir / package roots into sys.path during the
    ``configure`` phase, which can push plugins/dso/scripts back behind
    tests/skills in the search order.  Running _install_scripts_path() here
    ensures the plugin package wins regardless of pytest's insertion order.
    """
    _install_scripts_path()


# Also run at module-import time as a belt-and-suspenders measure for
# pytest invocations that process test modules before configure completes.
_install_scripts_path()
