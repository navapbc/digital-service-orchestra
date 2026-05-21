"""Test-package shim: re-exports dso_ci_review.cycle_ledger from plugin scripts.

In multiprocessing 'spawn' mode on macOS, the child process inherits the
parent's sys.path verbatim. When pytest runs, tests/skills precedes
plugins/dso/scripts in sys.path, so 'dso_ci_review' resolves to this test
package. This shim makes cycle_ledger accessible from either location.
"""

from __future__ import annotations

import importlib.util as _ilu
import pathlib as _pathlib

_REPO_ROOT = _pathlib.Path(__file__).resolve().parents[3]
_CL_PATH = (
    _REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_ci_review" / "cycle_ledger.py"
)

_spec = _ilu.spec_from_file_location("dso_ci_review.cycle_ledger", str(_CL_PATH))
if _spec is not None and _spec.loader is not None:
    _mod = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_mod)  # type: ignore[union-attr]

    # Re-export all public API
    read_ledger = _mod.read_ledger
    write_ledger = _mod.write_ledger
    append_cycle = _mod.append_cycle
    reconstruct_from_pr_comments = _mod.reconstruct_from_pr_comments
    _resolve_artifacts_dir = _mod._resolve_artifacts_dir
    _empty_ledger = _mod._empty_ledger
else:
    raise ImportError(f"Cannot load plugin cycle_ledger from {_CL_PATH}")
