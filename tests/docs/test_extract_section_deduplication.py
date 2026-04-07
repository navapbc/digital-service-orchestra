"""Tests that _extract_section helpers are deduplicated into tests/lib/markdown_helpers.py.

Bug: f633-a6e5 — identical _extract_section was duplicated across
tests/docs/test_sub_agent_boundaries_anti_coverup.py and
tests/skills/test_task_execution_template.py.
"""

from __future__ import annotations

import ast
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _get_local_function_names(filepath: Path) -> set[str]:
    """Return the set of top-level function names defined in a Python file."""
    source = filepath.read_text()
    tree = ast.parse(source, filename=str(filepath))
    return {
        node.name
        for node in ast.iter_child_nodes(tree)
        if isinstance(node, ast.FunctionDef)
    }


def test_shared_helper_module_exists() -> None:
    """tests/lib/markdown_helpers.py must exist as the shared location."""
    helper = REPO_ROOT / "tests" / "lib" / "markdown_helpers.py"
    assert helper.exists(), (
        f"Shared helper module not found at {helper}. "
        "Create it with the extract_section function to deduplicate."
    )


def test_shared_helper_defines_extract_section() -> None:
    """The shared module must define extract_section."""
    helper = REPO_ROOT / "tests" / "lib" / "markdown_helpers.py"
    if not helper.exists():
        raise AssertionError("Shared helper module not found")
    names = _get_local_function_names(helper)
    assert "extract_section" in names, (
        f"extract_section not defined in {helper}. Found: {names}"
    )


def test_sub_agent_boundaries_does_not_define_extract_section_locally() -> None:
    """test_sub_agent_boundaries_anti_coverup.py must import, not define, _extract_section."""
    filepath = (
        REPO_ROOT / "tests" / "docs" / "test_sub_agent_boundaries_anti_coverup.py"
    )
    names = _get_local_function_names(filepath)
    assert "_extract_section" not in names, (
        f"{filepath.name} still defines _extract_section locally. "
        "It should import from tests.lib.markdown_helpers instead."
    )


def test_task_execution_template_does_not_define_extract_section_locally() -> None:
    """test_task_execution_template.py must import, not define, _extract_section_from_template.

    If the file was deleted (change-detection test cleanup), this test is
    vacuously satisfied — the duplication is gone.
    """
    filepath = REPO_ROOT / "tests" / "skills" / "test_task_execution_template.py"
    if not filepath.exists():
        return  # File deleted — deduplication concern no longer applies
    names = _get_local_function_names(filepath)
    assert "_extract_section_from_template" not in names, (
        f"{filepath.name} still defines _extract_section_from_template locally. "
        "It should import from tests.lib.markdown_helpers instead."
    )
