"""Test-package shim: re-exports dso_ci_review.cycle_dispatcher from plugin scripts.

In multiprocessing 'spawn' mode on macOS, the child process inherits the
parent's sys.path verbatim. When pytest runs, tests/skills precedes
plugins/dso/scripts in sys.path, so 'dso_ci_review' resolves to this test
package. This shim makes cycle_dispatcher accessible from either location.
"""

from __future__ import annotations

import importlib.util as _ilu
import pathlib as _pathlib

_REPO_ROOT = _pathlib.Path(__file__).resolve().parents[3]
_CD_PATH = (
    _REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_ci_review" / "cycle_dispatcher.py"
)

_spec = _ilu.spec_from_file_location("dso_ci_review.cycle_dispatcher", str(_CD_PATH))
if _spec is not None and _spec.loader is not None:
    _mod = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_mod)  # type: ignore[union-attr]

    # Re-export public API
    next_action = _mod.next_action
else:
    raise ImportError(f"Cannot load plugin cycle_dispatcher from {_CD_PATH}")
