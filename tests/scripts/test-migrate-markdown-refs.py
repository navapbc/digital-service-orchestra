"""RED tests for scripts/migrate-markdown-refs.py (S3 – plugin portability).

These tests import from migrate_markdown_refs which does not yet exist.
The expected RED state is ImportError on every test.
"""

from __future__ import annotations

import importlib.util
import os
import textwrap
from pathlib import Path
from types import ModuleType

# Module loading — filename has hyphens so we use importlib
REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "migrate-markdown-refs.py"

_mod: ModuleType | None = None


def _load_module() -> ModuleType:
    global _mod
    if _mod is not None:
        return _mod
    spec = importlib.util.spec_from_file_location("migrate_markdown_refs", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    _mod = module
    return module


def _get_migrate_file():
    return _load_module().migrate_file


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write(tmp: str, name: str, content: str) -> str:
    path = os.path.join(tmp, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(textwrap.dedent(content))
    return path


def _read(path: str) -> str:
    with open(path) as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestRuntimeCodeBlock:
    """plugins/dso/foo/bar.sh inside a fenced ```bash block
    must become ${CLAUDE_PLUGIN_ROOT}/foo/bar.sh."""

    def test_runtime_code_block(self, tmp_path: str) -> None:
        src = _write(
            str(tmp_path),
            "doc.md",
            """\
            Some prose.

            ```bash
            source plugins/dso/foo/bar.sh
            ```
            """,
        )
        _get_migrate_file()(src)
        result = _read(src)
        assert "${CLAUDE_PLUGIN_ROOT}/foo/bar.sh" in result
        assert "plugins/dso/foo/bar.sh" not in result


class TestRuntimeToolInvocation:
    """Read("plugins/dso/foo") must become Read("${CLAUDE_PLUGIN_ROOT}/foo")."""

    def test_runtime_tool_invocation(self, tmp_path: str) -> None:
        src = _write(
            str(tmp_path),
            "skill.md",
            """\
            Use Read("plugins/dso/foo") to inspect.
            """,
        )
        _get_migrate_file()(src)
        result = _read(src)
        assert 'Read("${CLAUDE_PLUGIN_ROOT}/foo")' in result
        assert 'Read("plugins/dso/foo")' not in result


class TestProseStripPrefix:
    """Backtick `plugins/dso/docs/foo.md` in prose
    must become `docs/foo.md`."""

    def test_prose_strip_prefix(self, tmp_path: str) -> None:
        src = _write(
            str(tmp_path),
            "readme.md",
            """\
            See `plugins/dso/docs/foo.md` for details.
            """,
        )
        _get_migrate_file()(src)
        result = _read(src)
        assert "`docs/foo.md`" in result
        assert "`plugins/dso/docs/foo.md`" not in result


class TestSkipShimExempt:
    """Lines with # shim-exempt: must NOT be modified."""

    def test_skip_shim_exempt(self, tmp_path: str) -> None:
        src = _write(
            str(tmp_path),
            "exempt.md",
            """\
            ```bash
            source plugins/dso/hooks/lib/deps.sh  # shim-exempt: needed for bootstrap
            ```
            """,
        )
        _get_migrate_file()(src)
        result = _read(src)
        assert "plugins/dso/hooks/lib/deps.sh" in result
        assert "shim-exempt:" in result


class TestDryRunNoMutation:
    """--dry-run makes no changes to files."""

    def test_dry_run_no_mutation(self, tmp_path: str) -> None:
        src = _write(
            str(tmp_path),
            "doc.md",
            """\
            ```bash
            source plugins/dso/foo/bar.sh
            ```
            """,
        )
        original = _read(src)
        _get_migrate_file()(src, dry_run=True)
        assert _read(src) == original


class TestIdempotent:
    """Running migrate_file twice produces the same result as once."""

    def test_idempotent(self, tmp_path: str) -> None:
        src = _write(
            str(tmp_path),
            "doc.md",
            """\
            ```bash
            source plugins/dso/foo/bar.sh
            ```

            See `plugins/dso/docs/foo.md` for details.
            """,
        )
        _get_migrate_file()(src)
        first_pass = _read(src)
        _get_migrate_file()(src)
        second_pass = _read(src)
        assert first_pass == second_pass


class TestNoBypassAnnotations:
    """Output files must contain zero plugin-self-ref-ok annotations."""

    def test_no_bypass_annotations(self, tmp_path: str) -> None:
        src = _write(
            str(tmp_path),
            "doc.md",
            """\
            ```bash
            source plugins/dso/foo/bar.sh
            ```
            """,
        )
        _get_migrate_file()(src)
        result = _read(src)
        assert "plugin-self-ref-ok" not in result
