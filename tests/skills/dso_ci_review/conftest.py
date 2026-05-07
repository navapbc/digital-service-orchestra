"""Shared fixtures for dso_ci_review tests.

Path setup note: this conftest is loaded as part of the ``dso_ci_review``
test package (tests/skills/dso_ci_review/).  By the time this file executes,
pytest may have set ``sys.modules['dso_ci_review']`` to the test package.
We evict it here and re-insert the plugin package (plugins/dso/scripts) at
the front of sys.path so that ``from dso_ci_review.providers.config import
...`` in test_providers_config.py resolves to the real implementation.
"""

import json
import pathlib
import sys

import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")


def _ensure_plugin_package() -> None:
    """Place plugin scripts dir at front of sys.path and add providers sub-pkg.

    We cannot safely evict ``dso_ci_review`` from sys.modules while pytest is
    in the middle of loading this conftest (it's a sub-module of the test
    package, and pytest holds a reference in sys.modules that would KeyError).

    Instead we:
    1. Put _SCRIPTS_DIR at the front of sys.path.
    2. Import the real ``providers`` and ``providers.config`` sub-packages from
       the plugin and inject them into sys.modules under the names that the
       test file will look for (``dso_ci_review.providers`` etc.).
    """
    import importlib.util as _ilu

    while _SCRIPTS_DIR in sys.path:
        sys.path.remove(_SCRIPTS_DIR)
    sys.path.insert(0, _SCRIPTS_DIR)

    # Load the plugin's dso_ci_review package into a temporary name so we can
    # extract its providers sub-package without replacing the test-package entry
    # in sys.modules (which would break pytest's package tracking).
    _PLUGIN_PKG = "dso_ci_review"

    def _load_from_plugin(submodule: str) -> None:
        """Load submodule from _SCRIPTS_DIR and inject into sys.modules."""
        full_name = f"{_PLUGIN_PKG}.{submodule}" if submodule else _PLUGIN_PKG
        pkg_path = pathlib.Path(_SCRIPTS_DIR) / _PLUGIN_PKG.replace(".", "/")
        sub_path = pkg_path
        for part in submodule.split("."):
            sub_path = sub_path / part
        init = sub_path / "__init__.py"
        if not init.exists():
            init = sub_path.with_suffix(".py")
        if not init.exists():
            return
        spec = _ilu.spec_from_file_location(full_name, init)
        if spec is None or spec.loader is None:
            return
        mod = _ilu.module_from_spec(spec)
        # Only inject if not already pointing at the plugin
        existing = sys.modules.get(full_name)
        if existing is None or _SCRIPTS_DIR not in (
            getattr(existing, "__file__", None) or ""
        ):
            sys.modules[full_name] = mod
            spec.loader.exec_module(mod)  # type: ignore[union-attr]

    _load_from_plugin("providers")
    _load_from_plugin("providers.config")
    _load_from_plugin("context_request")
    _load_from_plugin("dispatch")
    _load_from_plugin("classifier")
    _load_from_plugin("findings")
    _load_from_plugin("speculation_markers")
    _load_from_plugin("runner")


_ensure_plugin_package()

REPO_ROOT = pathlib.Path(__file__).parents[3]
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus"


@pytest.fixture()
def fixture_diff_path():
    """Return path to the fixture diff file."""
    return FIXTURE_DIR / "fixture-diff.txt"


def pytest_configure(config):
    existing = config.getini("markers")
    if not any("integration:" in m for m in existing):
        config.addinivalue_line(
            "markers",
            "integration: mark test as a live-provider integration test (skipped without API keys)",
        )


@pytest.fixture()
def canned_findings_dict():
    """Return a minimal canned LLM response dict shaped like litellm.completion output."""
    return {
        "choices": [
            {
                "message": {
                    "content": json.dumps(
                        {
                            "findings": [
                                {
                                    "severity": "minor",
                                    "description": "Example finding from fixture",
                                    "cited_lines": ["plugins/dso/scripts/example.py:1"],
                                }
                            ]
                        }
                    )
                }
            }
        ]
    }
