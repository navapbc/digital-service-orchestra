"""
Unit tests for migrate-comment-refs.py
These tests are written RED-first — the module does not exist yet.
Running them will produce ImportError/ModuleNotFoundError (the RED state).
"""

import sys
import textwrap
from pathlib import Path


# The module lives next to the script in plugins/dso/scripts/
REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

# This import will fail (ModuleNotFoundError) until Task 2 creates the module.
import migrate_comment_refs as mcr  # noqa: E402  # type: ignore[import]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _rewrite(line: str) -> str:
    """Run a single line through the rewriter and return the result."""
    return mcr.rewrite_comment_line(line)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestRewriteHeaderComment:
    """Category 1 – header comments: '# plugins/dso/.../filename' → '# filename'"""

    def test_simple_script_path(self):
        line = "# plugins/dso/scripts/foo.sh"
        result = _rewrite(line)
        assert result == "# foo.sh"

    def test_nested_path(self):
        line = "# plugins/dso/hooks/lib/fuzzy-match.sh"
        result = _rewrite(line)
        assert result == "# fuzzy-match.sh"

    def test_non_plugin_path_unchanged(self):
        line = "# src/foo.sh"
        result = _rewrite(line)
        assert result == "# src/foo.sh"


class TestRewriteUsageComment:
    """Category 2 – usage examples with .claude/scripts/dso or plugins/dso/scripts/"""

    def test_dot_claude_scripts_dso(self):
        line = "# Usage: .claude/scripts/dso foo.sh"
        result = _rewrite(line)
        assert "${_PLUGIN_ROOT}/scripts/" in result
        assert ".claude/scripts/dso" not in result

    def test_plugins_dso_scripts_reference(self):
        line = "#   plugins/dso/scripts/migrate-comment-refs.py --dry-run ."
        result = _rewrite(line)
        assert "${_PLUGIN_ROOT}/scripts/" in result
        assert "plugins/dso/scripts/" not in result

    def test_usage_line_preserves_script_name(self):
        line = "# Usage: plugins/dso/scripts/validate.sh --ci"
        result = _rewrite(line)
        assert "validate.sh" in result
        assert "${_PLUGIN_ROOT}/scripts/validate.sh" in result


class TestRewritePathAnchor:
    """Category 3 – prose 'See plugins/dso/docs/X.md' → 'See ${CLAUDE_PLUGIN_ROOT}/docs/X.md'"""

    def test_see_docs_reference(self):
        line = "# See plugins/dso/docs/INSTALL.md for details."
        result = _rewrite(line)
        assert "${CLAUDE_PLUGIN_ROOT}/docs/INSTALL.md" in result
        assert "plugins/dso/docs/" not in result

    def test_see_docs_nested(self):
        line = "#   See plugins/dso/docs/contracts/approach-decision-output.md"
        result = _rewrite(line)
        assert (
            "${CLAUDE_PLUGIN_ROOT}/docs/contracts/approach-decision-output.md" in result
        )

    def test_non_comment_line_unchanged(self):
        """Non-comment lines must not be touched."""
        line = 'echo "See plugins/dso/docs/README.md"'
        result = _rewrite(line)
        assert result == line


class TestRewriteCrossRef:
    """Category 4 – inline prose 'plugins/dso/<subdir>/' → '${CLAUDE_PLUGIN_ROOT}/<subdir>/'"""

    def test_hooks_subdir(self):
        line = "# Reads from plugins/dso/hooks/ at runtime."
        result = _rewrite(line)
        assert "${CLAUDE_PLUGIN_ROOT}/hooks/" in result
        assert "plugins/dso/hooks/" not in result

    def test_agents_subdir(self):
        line = "# agent files live in plugins/dso/agents/"
        result = _rewrite(line)
        assert "${CLAUDE_PLUGIN_ROOT}/agents/" in result

    def test_already_replaced_is_idempotent(self):
        already_replaced = "# Reads from ${CLAUDE_PLUGIN_ROOT}/hooks/ at runtime."
        result = _rewrite(already_replaced)
        assert result == already_replaced


class TestDryRunNoMutation:
    """--dry-run must not modify any files on disk."""

    def test_dry_run_does_not_write(self, tmp_path):
        target = tmp_path / "example.sh"
        original_content = textwrap.dedent("""\
            #!/usr/bin/env bash
            # plugins/dso/scripts/example.sh
            # See plugins/dso/docs/INSTALL.md
            echo hello
        """)
        target.write_text(original_content)

        mcr.process_directory(str(tmp_path), dry_run=True)

        assert target.read_text() == original_content, (
            "--dry-run must not alter file contents"
        )


class TestIdempotent:
    """Running the migration twice must produce the same result as once."""

    def test_idempotent_on_directory(self, tmp_path):
        target = tmp_path / "script.sh"
        original = textwrap.dedent("""\
            #!/usr/bin/env bash
            # plugins/dso/scripts/script.sh
            # See plugins/dso/docs/INSTALL.md for setup.
            # Usage: plugins/dso/scripts/validate.sh --ci
            echo done
        """)
        target.write_text(original)

        mcr.process_directory(str(tmp_path))
        after_first = target.read_text()

        mcr.process_directory(str(tmp_path))
        after_second = target.read_text()

        assert after_first == after_second, (
            "Running migration twice must produce the same output as running it once"
        )
        # Also verify that something actually changed from the original
        assert after_first != original, "Migration must have changed something"
