"""Regression test for bug ec9a-be6b-f50a-47b4.

Pre-fix: fetcher.py:160 used `from plugins.dso.scripts.dso_reconciler import alert_store`,
which only resolves when `plugins` is importable. Production CI does not pre-seed
the namespace; the import raised `ModuleNotFoundError: No module named 'plugins'`
at runtime inside fetch_snapshot.

Behavioral test: with no `plugins.*` namespace stubs in sys.modules, execute the
same importlib + sys.modules lazy-load pattern fetcher.py now uses and verify
alert_store loads and exposes its expected API. Exercises the load mechanism,
not source structure.
"""

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
FETCHER_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "fetcher.py"


def test_alert_store_loads_via_importlib_pattern_with_no_plugins_seeded(tmp_path):
    """Verify the lazy-load mechanism: clear out `plugins.*` from sys.modules,
    run the importlib + sys.modules registration block (mirroring fetcher.py's
    post-fix lazy-load), and assert alert_store loads and has the expected API.
    """
    plugins_keys = [k for k in list(sys.modules.keys()) if k.startswith("plugins")]
    saved = {k: sys.modules.pop(k) for k in plugins_keys}

    # Also clear any alert_store cache so we re-load fresh.
    sys.modules.pop("dso_reconciler.alert_store", None)

    try:
        # Replicate the lazy-load block fetcher.py uses post-fix
        _ALERT_STORE_KEY = "dso_reconciler.alert_store"
        if _ALERT_STORE_KEY in sys.modules:
            alert_store = sys.modules[_ALERT_STORE_KEY]
        else:
            spec = importlib.util.spec_from_file_location(
                _ALERT_STORE_KEY, FETCHER_PATH.parent / "alert_store.py"
            )
            # Defensive: surface a clear error if path/loader resolution breaks
            assert spec is not None, (
                f"spec_from_file_location returned None for "
                f"{FETCHER_PATH.parent / 'alert_store.py'}"
            )
            assert spec.loader is not None, (
                f"spec.loader is None for {_ALERT_STORE_KEY}"
            )
            alert_store = importlib.util.module_from_spec(spec)
            sys.modules[_ALERT_STORE_KEY] = alert_store
            spec.loader.exec_module(alert_store)

        # alert_store.append is the API fetcher.py calls in the dedup path
        assert hasattr(alert_store, "append"), (
            f"alert_store loaded via the fix's pattern but missing .append API "
            f"(public attrs: {sorted(a for a in dir(alert_store) if not a.startswith('_'))})"
        )
    finally:
        sys.modules.pop("dso_reconciler.alert_store", None)
        for k, v in saved.items():
            sys.modules[k] = v
