"""Test-package shim: re-exports dso_ci_review.local_workflow from plugin scripts.

In multiprocessing 'spawn' mode on macOS, the child process inherits the
parent's sys.path verbatim. When pytest runs, tests/skills precedes
plugins/dso/scripts in sys.path, so 'dso_ci_review' resolves to this test
package. This shim makes local_workflow accessible from either location.
"""

from __future__ import annotations

import importlib
import importlib.util as _ilu
import pathlib
import sys

# Ensure the plugin scripts directory is on sys.path so the real implementation
# can be imported. We must do this BEFORE importing from dso_ci_review to avoid
# infinite recursion.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
_PLUGIN_DSO_PKG_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_ci_review")

# Ensure scripts dir is on sys.path first so that the plugin package takes
# precedence for any fresh imports during exec_module.
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# Force-register the plugin's dso_ci_review package in sys.modules so that
# submodule imports inside local_workflow.py (e.g.
# `from dso_ci_review.arbiter_processor import process_rulings`) resolve to
# the plugin package tree rather than this test shim package.
# This is necessary in multiprocessing spawn mode where the test package's
# __init__.py is picked up first from sys.path.
_plugin_pkg_init = pathlib.Path(_PLUGIN_DSO_PKG_DIR) / "__init__.py"
if _plugin_pkg_init.exists() and (
    "dso_ci_review" not in sys.modules
    or sys.modules["dso_ci_review"].__file__ != str(_plugin_pkg_init)
):
    _pkg_spec = _ilu.spec_from_file_location(
        "dso_ci_review", str(_plugin_pkg_init),
        submodule_search_locations=[_PLUGIN_DSO_PKG_DIR],
    )
    if _pkg_spec is not None and _pkg_spec.loader is not None:
        _plugin_pkg_mod = _ilu.module_from_spec(_pkg_spec)
        _plugin_pkg_mod.__path__ = [_PLUGIN_DSO_PKG_DIR]  # type: ignore[attr-defined]
        sys.modules["dso_ci_review"] = _plugin_pkg_mod
        _pkg_spec.loader.exec_module(_plugin_pkg_mod)

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
