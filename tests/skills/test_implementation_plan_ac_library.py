"""Tests for new categories in ACCEPTANCE-CRITERIA-LIBRARY.md.

These are RED-phase xfail tests. They assert the presence of two new
categories that have not yet been added to the file. Once the GREEN task
(dso-gp00) adds the content, these tests will pass and should be converted
to normal assertions.
"""

import os

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
AC_LIBRARY_PATH = os.path.join(
    REPO_ROOT,
    "plugins",
    "dso",
    "docs",
    "ACCEPTANCE-CRITERIA-LIBRARY.md",
)


def _read_ac_library() -> str:
    with open(AC_LIBRARY_PATH) as f:
        return f.read()


@pytest.mark.xfail(strict=True, reason="Category not yet added (dso-gp00)")
def test_red_test_task_category_present() -> None:
    """'Category: RED Test Task' must be present in ACCEPTANCE-CRITERIA-LIBRARY.md."""
    content = _read_ac_library()
    assert "Category: RED Test Task" in content


@pytest.mark.xfail(strict=True, reason="Category not yet added (dso-gp00)")
def test_test_exempt_task_category_present() -> None:
    """'Category: Test-Exempt Task' must be present in ACCEPTANCE-CRITERIA-LIBRARY.md."""
    content = _read_ac_library()
    assert "Category: Test-Exempt Task" in content


@pytest.mark.xfail(
    strict=True, reason="Justification criterion not yet added (dso-gp00)"
)
def test_test_exempt_justification_criterion_present() -> None:
    """The test-exempt category must include a justification criterion."""
    content = _read_ac_library()
    # Confirm the category exists and has justification text after it
    assert "Category: Test-Exempt Task" in content
    idx = content.index("Category: Test-Exempt Task")
    section = content[idx : idx + 500]
    assert "justification" in section.lower()
