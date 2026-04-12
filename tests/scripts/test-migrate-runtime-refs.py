"""RED tests for migrate-runtime-refs.py.

These tests are RED — they test functionality that does not yet exist.
All tests MUST FAIL with ImportError before migrate-runtime-refs.py is implemented.

The module under test is expected to expose:
    inject_plugin_root(lines: list[str]) -> list[str]
    replace_variable_refs(lines: list[str]) -> list[str]
    replace_git_relative_refs(lines: list[str]) -> list[str]
    replace_user_message_refs(lines: list[str]) -> list[str]
    derive_plugin_git_path_needed(lines: list[str]) -> bool
    migrate_file(path: str, dry_run: bool = False) -> dict

Contract:
  - inject_plugin_root inserts _PLUGIN_ROOT declaration after shebang+set-e
  - replace_variable_refs converts $REPO_ROOT/plugins/dso/... to ${_PLUGIN_ROOT}/...
  - replace_git_relative_refs converts bare plugins/dso/ in git patterns to ${_PLUGIN_GIT_PATH}/
  - replace_user_message_refs converts echo containing plugins/dso/ to ${_PLUGIN_ROOT}/
  - derive_plugin_git_path_needed returns True when git-relative patterns exist
  - migrate_file orchestrates all transforms; dry_run=True makes no file changes
  - Running migrate_file twice on the same input is idempotent

Test: python3 -m pytest tests/scripts/test-migrate-runtime-refs.py -x
All tests must return non-zero until migrate-runtime-refs.py is implemented.
"""

from __future__ import annotations

import importlib.util
import os
import tempfile
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "migrate-runtime-refs.py"

PLUGIN_ROOT_DECL = (
    '_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-'
    '$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"'
)

PLUGIN_GIT_PATH_DECL = (
    '_PLUGIN_GIT_PATH="${_PLUGIN_ROOT#$(git rev-parse --show-toplevel)/}"'
)


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("migrate_runtime_refs", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def mod() -> ModuleType:
    return _load_module()


# ---------------------------------------------------------------------------
# test_inject_plugin_root
# ---------------------------------------------------------------------------


class TestInjectPluginRoot:
    """inject_plugin_root inserts _PLUGIN_ROOT after shebang."""

    def test_missing_declaration_injected(self, mod: ModuleType) -> None:
        lines = [
            "#!/usr/bin/env bash\n",
            "echo hello\n",
        ]
        result = mod.inject_plugin_root(lines)
        assert PLUGIN_ROOT_DECL in "".join(result)

    def test_already_declared_unchanged(self, mod: ModuleType) -> None:
        lines = [
            "#!/usr/bin/env bash\n",
            f"{PLUGIN_ROOT_DECL}\n",
            "echo hello\n",
        ]
        result = mod.inject_plugin_root(lines)
        # Should not duplicate the declaration
        content = "".join(result)
        assert content.count("_PLUGIN_ROOT=") == 1


# ---------------------------------------------------------------------------
# test_inject_handles_set_e
# ---------------------------------------------------------------------------


class TestInjectHandlesSetE:
    """_PLUGIN_ROOT injected AFTER set -e when present on line 2."""

    def test_set_e_on_line2(self, mod: ModuleType) -> None:
        lines = [
            "#!/usr/bin/env bash\n",
            "set -e\n",
            "echo hello\n",
        ]
        result = mod.inject_plugin_root(lines)
        content = "".join(result)
        set_e_pos = content.index("set -e")
        plugin_root_pos = content.index("_PLUGIN_ROOT=")
        assert plugin_root_pos > set_e_pos


# ---------------------------------------------------------------------------
# test_replace_variable_anchored
# ---------------------------------------------------------------------------


class TestReplaceVariableAnchored:
    """$REPO_ROOT/plugins/dso/scripts/foo.sh -> ${_PLUGIN_ROOT}/scripts/foo.sh"""

    def test_repo_root_prefix_replaced(self, mod: ModuleType) -> None:
        lines = [
            '  source "$REPO_ROOT/plugins/dso/scripts/foo.sh"\n',
        ]
        result = mod.replace_variable_refs(lines)
        assert "${_PLUGIN_ROOT}/scripts/foo.sh" in result[0]
        assert "REPO_ROOT/plugins/dso" not in result[0]


# ---------------------------------------------------------------------------
# test_replace_skips_comment
# ---------------------------------------------------------------------------


class TestReplaceSkipsComment:
    """Comment lines with plugins/dso/ are NOT modified."""

    def test_comment_not_modified(self, mod: ModuleType) -> None:
        lines = [
            "# See plugins/dso/scripts/foo.sh for details\n",
        ]
        result = mod.replace_variable_refs(lines)
        assert result[0] == lines[0]


# ---------------------------------------------------------------------------
# test_derive_plugin_git_path
# ---------------------------------------------------------------------------


class TestDerivePluginGitPath:
    """Scripts needing git-relative paths get _PLUGIN_GIT_PATH derived."""

    def test_git_show_triggers_derivation(self, mod: ModuleType) -> None:
        lines = [
            "  git show HEAD:plugins/dso/hooks/foo.sh\n",
        ]
        assert mod.derive_plugin_git_path_needed(lines) is True

    def test_no_git_patterns_no_derivation(self, mod: ModuleType) -> None:
        lines = [
            '  source "${_PLUGIN_ROOT}/scripts/foo.sh"\n',
        ]
        assert mod.derive_plugin_git_path_needed(lines) is False


# ---------------------------------------------------------------------------
# test_replace_git_relative
# ---------------------------------------------------------------------------


class TestReplaceGitRelative:
    """bare plugins/dso/ in git show/diff/case patterns -> ${_PLUGIN_GIT_PATH}/"""

    def test_git_show_pattern(self, mod: ModuleType) -> None:
        lines = [
            "  git show HEAD:plugins/dso/hooks/foo.sh\n",
        ]
        result = mod.replace_git_relative_refs(lines)
        assert "${_PLUGIN_GIT_PATH}/" in result[0]
        assert "plugins/dso/" not in result[0]

    def test_git_diff_pattern(self, mod: ModuleType) -> None:
        lines = [
            "  git diff HEAD -- plugins/dso/scripts/bar.sh\n",
        ]
        result = mod.replace_git_relative_refs(lines)
        assert "${_PLUGIN_GIT_PATH}/" in result[0]


# ---------------------------------------------------------------------------
# test_replace_user_message
# ---------------------------------------------------------------------------


class TestReplaceUserMessage:
    """echo containing plugins/dso/scripts/foo -> ${_PLUGIN_ROOT}/scripts/foo"""

    def test_echo_message_replaced(self, mod: ModuleType) -> None:
        lines = [
            '  echo "Run plugins/dso/scripts/foo.sh to fix"\n',
        ]
        result = mod.replace_user_message_refs(lines)
        assert "${_PLUGIN_ROOT}/scripts/foo" in result[0]
        assert "plugins/dso/scripts/foo" not in result[0]


# ---------------------------------------------------------------------------
# test_dry_run_no_mutation
# ---------------------------------------------------------------------------


class TestDryRunNoMutation:
    """--dry-run makes no file changes."""

    def test_dry_run_preserves_file(self, mod: ModuleType) -> None:
        content = (
            '#!/usr/bin/env bash\nsource "$REPO_ROOT/plugins/dso/scripts/foo.sh"\n'
        )
        with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as f:
            f.write(content)
            f.flush()
            path = f.name
        try:
            mod.migrate_file(path, dry_run=True)
            with open(path) as f:
                assert f.read() == content
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# test_idempotent
# ---------------------------------------------------------------------------


class TestIdempotent:
    """Running migrate_file twice = running once."""

    def test_double_run_same_result(self, mod: ModuleType) -> None:
        content = '#!/usr/bin/env bash\nset -e\nsource "$REPO_ROOT/plugins/dso/scripts/foo.sh"\ngit show HEAD:plugins/dso/hooks/bar.sh\necho "See plugins/dso/scripts/baz.sh"\n'
        with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as f:
            f.write(content)
            f.flush()
            path = f.name
        try:
            mod.migrate_file(path, dry_run=False)
            with open(path) as f:
                after_first = f.read()
            mod.migrate_file(path, dry_run=False)
            with open(path) as f:
                after_second = f.read()
            assert after_first == after_second
        finally:
            os.unlink(path)
