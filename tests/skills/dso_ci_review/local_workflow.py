"""Test-package shim: re-exports dso_ci_review.local_workflow from plugin scripts.

In multiprocessing 'spawn' mode on macOS, the child process inherits the
parent's sys.path verbatim. When pytest runs, tests/skills precedes
plugins/dso/scripts in sys.path, so 'dso_ci_review' resolves to this test
package. This shim makes local_workflow accessible from either location.
"""

from __future__ import annotations

import pathlib
import sys

# Ensure the plugin scripts directory is on sys.path so the real implementation
# can be imported. We must do this BEFORE importing from dso_ci_review to avoid
# infinite recursion.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")

# Temporarily redirect dso_ci_review to the plugin package for this import.
# Save any existing reference so we can restore it afterward.
import importlib.util as _ilu

_plugin_lw_path = pathlib.Path(_SCRIPTS_DIR) / "dso_ci_review" / "local_workflow.py"
_spec = _ilu.spec_from_file_location(
    "dso_ci_review._plugin_local_workflow", str(_plugin_lw_path)
)
if _spec is not None and _spec.loader is not None:
    _plugin_mod = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_plugin_mod)  # type: ignore[union-attr]

    # Re-export public API
    _init_local_ledger = _plugin_mod._init_local_ledger
    main = _plugin_mod.main
else:
    raise ImportError(f"Cannot load plugin local_workflow from {_plugin_lw_path}")
