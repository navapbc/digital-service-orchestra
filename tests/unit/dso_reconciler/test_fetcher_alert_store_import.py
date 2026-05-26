"""Regression test for bug ec9a-be6b-f50a-47b4.

Pre-fix: fetcher.py:160 used `from plugins.dso.scripts.dso_reconciler import alert_store`,
which only resolves when `plugins` is importable. Production CI does not pre-seed
the namespace; the import raised `ModuleNotFoundError: No module named 'plugins'`
at runtime inside fetch_snapshot.

This test asserts two structural facts in an isolated environment with NO
`plugins.*` namespace stubs:
  1. The fetcher source no longer contains the buggy top-level pattern AT ITS
     LAZY-LOAD CALL SITE (the only place it can actually fail at runtime — the
     comment block referencing the historical bug is fine, but the executable
     code must not contain `from plugins...alert_store`).
  2. The replacement importlib-based sibling-load works: alert_store is loadable
     via the same pattern fetcher.py uses, against a clean sys.modules.
"""

import ast
import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
FETCHER_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "fetcher.py"


def _executable_from_imports_in(source: str) -> list[str]:
    """Return the dotted module names of every executable `from X import Y` in source.

    Uses AST parsing so we ignore strings and comments. Returns the X part
    (the module) for each ImportFrom node.
    """
    tree = ast.parse(source)
    modules: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module is not None:
            modules.append(node.module)
    return modules


def test_fetcher_does_not_contain_plugins_dotted_import_at_call_site():
    """fetcher.py's executable `from X import Y` statements must NOT include
    `plugins.dso.scripts.dso_reconciler` — that dotted form is the bug.

    Uses AST parsing so the comment block referencing the historical pattern
    does not falsely trigger the assertion.
    """
    source = FETCHER_PATH.read_text()
    modules = _executable_from_imports_in(source)
    bad = [m for m in modules if m.startswith("plugins.dso.scripts.dso_reconciler")]
    assert not bad, (
        f"Regression: fetcher.py contains an executable `from {bad[0]} import ...` "
        f"statement. This form only resolves when the test suite pre-seeds "
        f"sys.modules with `plugins.*` namespace stubs; production CI does not "
        f"and the import raises ModuleNotFoundError. Use importlib-based "
        f"sibling load with sys.modules registration instead. "
        f"See bug ec9a-be6b-f50a-47b4."
    )


def test_alert_store_loads_via_importlib_pattern_with_no_plugins_seeded(tmp_path):
    """Verify the replacement load pattern works: clean out `plugins.*` from
    sys.modules, run the importlib + sys.modules registration block (mirroring
    fetcher.py's new lazy-load), and assert alert_store has the expected API.

    This is the positive proof that the fix's load pattern is sound.
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
            alert_store = importlib.util.module_from_spec(spec)
            sys.modules[_ALERT_STORE_KEY] = alert_store
            spec.loader.exec_module(alert_store)

        # alert_store.append is the API fetcher.py calls
        assert hasattr(alert_store, "append"), (
            f"alert_store loaded via the fix's pattern but missing .append API "
            f"(public attrs: {sorted(a for a in dir(alert_store) if not a.startswith('_'))})"
        )
    finally:
        sys.modules.pop("dso_reconciler.alert_store", None)
        for k, v in saved.items():
            sys.modules[k] = v
