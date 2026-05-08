"""RED tests for dispatch.py agent loader behavioral contracts.

These tests define the behavior that the GREEN task will implement:
1. _load_agent_prompt raises RuntimeError on missing file (instead of silent fallback)
2. _load_agent_prompt returns file content when the file exists
3. _validate_agent_files raises RuntimeError listing missing files
4. _PLUGIN_ROOT prefers CLAUDE_PLUGIN_ROOT env var over file-relative path

All four tests must FAIL before the GREEN implementation in dispatch.py.
"""

from __future__ import annotations

import importlib
import importlib.util
import pathlib
import sys

import pytest

# ---------------------------------------------------------------------------
# Ensure plugin scripts dir is importable (mirrors conftest pattern)
# ---------------------------------------------------------------------------

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# Import directly from the plugin file to bypass the test-package dso_ci_review shadow.
_DISPATCH_PATH = (
    _REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_ci_review" / "dispatch.py"
)

# The 10 required code-reviewer agent files that _validate_agent_files must check.
_REQUIRED_AGENTS = [
    "code-reviewer-deep-arch",
    "code-reviewer-deep-correctness",
    "code-reviewer-deep-hygiene",
    "code-reviewer-deep-verification",
    "code-reviewer-light",
    "code-reviewer-performance",
    "code-reviewer-security-blue-team",
    "code-reviewer-security-red-team",
    "code-reviewer-standard",
    "code-reviewer-test-quality",
]


def _load_dispatch_fresh(plugin_root: pathlib.Path) -> object:
    """Load dispatch.py from the plugin path as an isolated module instance.

    Uses importlib.util.spec_from_file_location with a unique module name so
    each call gets a fresh module scope — no lru_cache or module-level constant
    bleed between tests.  CLAUDE_PLUGIN_ROOT must already be set in os.environ
    before calling this function.
    """
    # Use a unique name so Python's import machinery creates a brand-new module.
    unique_name = f"_test_dispatch_{id(plugin_root)}"
    spec = importlib.util.spec_from_file_location(unique_name, _DISPATCH_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


# ---------------------------------------------------------------------------
# Test 1: _load_agent_prompt raises RuntimeError when agent file is missing
# ---------------------------------------------------------------------------


def test_load_agent_prompt_raises_on_missing_file(monkeypatch, tmp_path):
    """_load_agent_prompt must raise RuntimeError when the agent file does not exist.

    Pre-implementation behavior: returns _SYSTEM_PROMPT fallback — test FAILS.
    Post-implementation behavior: raises RuntimeError — test PASSES.
    """
    # tmp_path has no agents/ subdirectory, so any agent file lookup will miss.
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    dispatch = _load_dispatch_fresh(tmp_path)

    with pytest.raises(RuntimeError):
        dispatch._load_agent_prompt("code-reviewer-light")


# ---------------------------------------------------------------------------
# Test 2: _load_agent_prompt returns file content when file exists
# ---------------------------------------------------------------------------


def test_load_agent_prompt_returns_file_content(monkeypatch, tmp_path):
    """_load_agent_prompt must return the body of the agent file when it exists.

    This test verifies that the disk-read path works correctly regardless of
    the raise-on-missing change.  It should pass pre-implementation IF the
    current code already reads from disk when the file is present; it is
    included as a regression guard.
    """
    agents_dir = tmp_path / "agents"
    agents_dir.mkdir(parents=True)
    agent_file = agents_dir / "code-reviewer-light.md"
    agent_file.write_text("test prompt", encoding="utf-8")

    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    dispatch = _load_dispatch_fresh(tmp_path)

    result = dispatch._load_agent_prompt("code-reviewer-light")
    assert result == "test prompt"


# ---------------------------------------------------------------------------
# Test 3: _validate_agent_files raises RuntimeError listing missing files
# ---------------------------------------------------------------------------


def test_validate_agent_files_raises_on_missing_agents(monkeypatch, tmp_path):
    """_validate_agent_files must raise RuntimeError when required agent files are absent.

    Pre-implementation behavior: function does not exist — test FAILS with AttributeError.
    Post-implementation behavior: raises RuntimeError with missing file names — test PASSES.
    """
    # Create agents/ dir but omit all files so every required agent is missing.
    agents_dir = tmp_path / "agents"
    agents_dir.mkdir(parents=True)

    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    dispatch = _load_dispatch_fresh(tmp_path)

    # The function must exist and raise RuntimeError listing the missing files.
    assert hasattr(dispatch, "_validate_agent_files"), (
        "_validate_agent_files function not found in dispatch module"
    )

    with pytest.raises(RuntimeError) as exc_info:
        dispatch._validate_agent_files()

    # The error message must name at least one missing file so operators know what to fix.
    error_text = str(exc_info.value)
    assert any(agent in error_text for agent in _REQUIRED_AGENTS), (
        f"RuntimeError did not mention any required agent; got: {error_text!r}"
    )


# ---------------------------------------------------------------------------
# Test 4: _PLUGIN_ROOT prefers CLAUDE_PLUGIN_ROOT env var
# ---------------------------------------------------------------------------


def test_plugin_root_prefers_env_var(monkeypatch, tmp_path):
    """_PLUGIN_ROOT must equal pathlib.Path(CLAUDE_PLUGIN_ROOT) when that env var is set.

    Pre-implementation behavior: _PLUGIN_ROOT is set at import time from __file__,
    ignoring CLAUDE_PLUGIN_ROOT — test FAILS because _PLUGIN_ROOT != tmp_path.
    Post-implementation behavior: _PLUGIN_ROOT is resolved from env var — test PASSES.
    """
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    dispatch = _load_dispatch_fresh(tmp_path)

    assert dispatch._PLUGIN_ROOT == tmp_path, (
        f"Expected _PLUGIN_ROOT == {tmp_path}, got {dispatch._PLUGIN_ROOT!r}. "
        "dispatch.py must read CLAUDE_PLUGIN_ROOT env var to set _PLUGIN_ROOT."
    )
