"""Unit tests for scripts/migrate-markdown-refs.py."""

from __future__ import annotations

import os
import sys
import tempfile


# Add scripts/ to path so we can import the module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))

# Import as module
import importlib.util

spec = importlib.util.spec_from_file_location(
    "migrate_markdown_refs",
    os.path.join(
        os.path.dirname(__file__), "..", "..", "scripts", "migrate-markdown-refs.py"
    ),
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

classify_and_convert = mod.classify_and_convert
process_file = mod.process_file


class TestClassifyAndConvert:
    """Test classification and conversion logic."""

    def test_runtime_code_block_converts_to_plugin_root(self):
        line = "source plugins/dso/hooks/lib/deps.sh"
        result, conv_type = classify_and_convert(line, in_code_block=True)
        assert conv_type == "runtime"
        assert "${CLAUDE_PLUGIN_ROOT}/" in result
        assert "plugins/dso/" not in result

    def test_prose_backtick_strips_prefix(self):
        line = "See `plugins/dso/docs/INSTALL.md` for details."
        result, conv_type = classify_and_convert(line, in_code_block=False)
        assert conv_type == "prose"
        assert "`docs/INSTALL.md`" in result
        assert "plugins/dso" not in result

    def test_prose_bare_ref_strips_prefix(self):
        line = "Files in plugins/dso/hooks/ are dispatchers."
        result, conv_type = classify_and_convert(line, in_code_block=False)
        assert conv_type == "prose"
        assert "plugins/dso" not in result
        assert "hooks/" in result

    def test_no_conversion_when_no_ref(self):
        line = "This line has no references."
        result, conv_type = classify_and_convert(line, in_code_block=False)
        assert conv_type is None
        assert result == line

    def test_runtime_repo_root_prefix_converted(self):
        line = 'AGENT_FILE="$REPO_ROOT/plugins/dso/agents/foo.md"'
        result, conv_type = classify_and_convert(line, in_code_block=True)
        assert conv_type == "runtime"
        assert "${CLAUDE_PLUGIN_ROOT}/agents/foo.md" in result
        assert "plugins/dso" not in result

    def test_already_portable_skipped(self):
        line = 'source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"'
        result, conv_type = classify_and_convert(line, in_code_block=True)
        assert conv_type is None
        assert result == line

    def test_runtime_line_detection_source(self):
        line = "source plugins/dso/hooks/lib/merge-state.sh"
        result, conv_type = classify_and_convert(line, in_code_block=False)
        assert conv_type == "runtime"

    def test_runtime_line_detection_bash(self):
        line = "bash plugins/dso/scripts/validate.sh --ci"
        result, conv_type = classify_and_convert(line, in_code_block=False)
        assert conv_type == "runtime"

    def test_prose_bare_directory_ref(self):
        """plugins/dso/ alone in backticks becomes descriptive text."""
        line = "Files under `plugins/dso/` are distributed."
        result, conv_type = classify_and_convert(line, in_code_block=False)
        assert conv_type == "prose"
        assert "plugins/dso" not in result
        # Should not produce empty backticks
        assert "``" not in result

    def test_table_cell_command_is_runtime(self):
        line = "| Hook | `bash plugins/dso/hooks/pre-bash.sh '{}'` |"
        result, conv_type = classify_and_convert(line, in_code_block=False)
        assert conv_type == "runtime"
        assert "${CLAUDE_PLUGIN_ROOT}/" in result

    def test_no_annotation_produced(self):
        """Migration must never produce plugin-self-ref-ok annotations."""
        line = "source plugins/dso/hooks/lib/deps.sh"
        result, _ = classify_and_convert(line, in_code_block=True)
        assert "plugin-self-ref-ok" not in result


class TestProcessFile:
    """Test end-to-end file processing."""

    def test_process_file_runtime_and_prose(self):
        content = """# Test file

See `plugins/dso/docs/INSTALL.md` for setup.

```bash
source plugins/dso/hooks/lib/deps.sh
```

Reference: plugins/dso/skills/sprint/SKILL.md
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
            f.write(content)
            f.flush()
            path = f.name

        try:
            stats = process_file(path, dry_run=False)
            assert stats["runtime"] == 1
            assert stats["prose"] == 2

            with open(path) as f:
                result = f.read()
            assert "plugins/dso" not in result
            assert "${CLAUDE_PLUGIN_ROOT}/" in result
            assert "`docs/INSTALL.md`" in result
        finally:
            os.unlink(path)

    def test_process_file_runtime_only_mode(self):
        content = """See `plugins/dso/docs/foo.md`.

```bash
source plugins/dso/hooks/lib/deps.sh
```
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
            f.write(content)
            f.flush()
            path = f.name

        try:
            stats = process_file(path, dry_run=False, runtime_only=True)
            assert stats["runtime"] == 1
            assert stats["prose"] == 0
            assert stats["skipped"] == 1

            with open(path) as f:
                result = f.read()
            # Runtime converted
            assert "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh" in result
            # Prose NOT converted in runtime-only mode
            assert "plugins/dso/docs/foo.md" in result
        finally:
            os.unlink(path)

    def test_dry_run_does_not_modify(self):
        content = "See `plugins/dso/docs/foo.md`.\n"
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
            f.write(content)
            f.flush()
            path = f.name

        try:
            process_file(path, dry_run=True)
            with open(path) as f:
                assert f.read() == content
        finally:
            os.unlink(path)
