"""Tests for the no-unguarded-urlopen isolation rule (bug 1c68).

Verifies:
1. A test file with a bare urlopen() call and no patch is flagged.
2. A test file with a mock/patch for urlopen is NOT flagged.
3. A test file decorated with @pytest.mark.allow_network is NOT flagged.
4. Non-test Python files (no test_*.py / *_test.py naming) are not flagged.
5. Files with no urlopen call exit cleanly.
6. The staged-file path filter in check-test-isolation.sh correctly matches
   tests/ (not just app/tests/) after the path-prefix bug fix.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RULE_SCRIPT = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "scripts"
    / "test-isolation-rules"
    / "no-unguarded-urlopen.sh"
)
ISOLATION_CHECK_SCRIPT = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "check-test-isolation.sh"
)


def _run_rule(
    content: str, filename: str = "test_subject.py", tmp_path: Path = Path("/tmp")
) -> tuple[int, str]:
    """Write *content* to a temp file named *filename* and run the rule against it."""
    target = tmp_path / filename
    target.write_text(content, encoding="utf-8")
    result = subprocess.run(
        ["bash", str(RULE_SCRIPT), str(target)],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout.strip()


# ---------------------------------------------------------------------------
# Positive: flagged cases
# ---------------------------------------------------------------------------


def test_bare_urlopen_call_is_flagged(tmp_path: Path) -> None:
    """A test file that calls urllib.request.urlopen without a patch is flagged."""
    content = """\
import urllib.request

def test_reaches_network():
    resp = urllib.request.urlopen("http://example.com")
"""
    rc, output = _run_rule(content, "test_bare.py", tmp_path)
    assert rc == 0, "rule exits 0 (violations reported via stdout)"
    assert "no-unguarded-urlopen" in output, (
        f"expected violation in output; got: {output!r}"
    )
    assert "urlopen" in output


def test_multiple_urlopen_calls_reports_first(tmp_path: Path) -> None:
    """Rule reports the first urlopen call line (not all of them)."""
    content = """\
import urllib.request

def test_one():
    resp = urllib.request.urlopen("http://a.com")

def test_two():
    resp = urllib.request.urlopen("http://b.com")
"""
    rc, output = _run_rule(content, "test_multi.py", tmp_path)
    assert rc == 0
    # Only one violation emitted (file-level signal)
    assert output.count("no-unguarded-urlopen") == 1


# ---------------------------------------------------------------------------
# Negative: NOT flagged cases
# ---------------------------------------------------------------------------


def test_file_with_patch_for_urlopen_not_flagged(tmp_path: Path) -> None:
    """A file that patches urlopen must NOT be flagged."""
    content = """\
import urllib.request
from unittest.mock import patch

def test_good():
    with patch("urllib.request.urlopen") as mock_urlopen:
        mock_urlopen.return_value.__enter__ = lambda s: s
        mock_urlopen.return_value.__exit__ = lambda s, *a: False
        urllib.request.urlopen("http://example.com")
"""
    rc, output = _run_rule(content, "test_mocked.py", tmp_path)
    assert rc == 0
    assert output == "", f"expected no violations; got: {output!r}"


def test_file_with_allow_network_marker_not_flagged(tmp_path: Path) -> None:
    """A file with @pytest.mark.allow_network must NOT be flagged."""
    content = """\
import urllib.request
import pytest

@pytest.mark.allow_network
def test_live_probe():
    resp = urllib.request.urlopen("http://example.com")
"""
    rc, output = _run_rule(content, "test_allowed.py", tmp_path)
    assert rc == 0
    assert output == "", f"expected no violations; got: {output!r}"


def test_non_test_file_not_flagged(tmp_path: Path) -> None:
    """A production module (not named test_*.py) must NOT be flagged."""
    content = """\
import urllib.request

def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url) as resp:
        return resp.read()
"""
    rc, output = _run_rule(content, "my_module.py", tmp_path)
    assert rc == 0
    assert output == "", f"expected no violations for non-test file; got: {output!r}"


def test_no_urlopen_in_file_exits_clean(tmp_path: Path) -> None:
    """A test file with no urlopen call exits cleanly with no output."""
    content = """\
def test_pure_logic():
    assert 1 + 1 == 2
"""
    rc, output = _run_rule(content, "test_clean.py", tmp_path)
    assert rc == 0
    assert output == ""


def test_comment_line_with_urlopen_not_flagged(tmp_path: Path) -> None:
    """A comment mentioning urlopen( must not be flagged."""
    content = """\
# This test does NOT call urlopen() directly — it uses a stub
def test_stub():
    pass
"""
    rc, output = _run_rule(content, "test_comment.py", tmp_path)
    assert rc == 0
    assert output == ""


# ---------------------------------------------------------------------------
# Path-prefix fix: staged-only filter now matches tests/ not just app/tests/
# ---------------------------------------------------------------------------


def test_isolation_check_path_filter_matches_tests_prefix() -> None:
    """The staged-only grep pattern must match paths under tests/ (not just app/tests/).

    This validates the fix for the `^app/tests/.*\\.py$` → `^(app/)?tests/.*\\.py$`
    correction in check-test-isolation.sh.
    """
    # The corrected pattern must NOT match only `app/tests` — it must include the
    # optional group so plain `tests/` paths are also captured.
    # We check that the fixed pattern `(app/)?tests/` is present.
    script_text = ISOLATION_CHECK_SCRIPT.read_text(encoding="utf-8")
    assert "(app/)?" in script_text, (
        "check-test-isolation.sh STAGED_ONLY filter must include optional (app/)? "
        "prefix so tests/ paths are matched; found only app/tests/ (pre-fix pattern)"
    )
