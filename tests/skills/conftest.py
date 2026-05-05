"""Root conftest for tests/skills/.

Ensures plugins/dso/scripts is at the FRONT of sys.path so that
``import dso_ci_review`` resolves to the plugin package rather than the
test-package directory of the same name (tests/skills/dso_ci_review/).
"""

from __future__ import annotations

import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")


def _install_scripts_path() -> None:
    """Ensure the plugin scripts dir is at the front of sys.path and evict shadows."""
    if _SCRIPTS_DIR in sys.path:
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


# Run at import time (when pytest loads this conftest) so that the path
# is correct before any test module in this directory tree is imported.
_install_scripts_path()
