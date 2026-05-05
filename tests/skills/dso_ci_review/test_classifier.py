"""Behavioral RED tests for dso_ci_review.classifier.classify_tier.

classifier.py does NOT exist yet — all tests fail with ImportError (RED phase).

Import strategy: uses importlib.util to load from the plugin scripts directory,
bypassing the test-package/plugin-package name collision that would occur with a
direct ``from dso_ci_review.classifier import classify_tier`` import.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = _REPO_ROOT / "plugins" / "dso" / "scripts"


def _load_classifier() -> object:
    """Load classify_tier from the plugin scripts directory.

    Returns the classify_tier callable, or raises ImportError if the module
    does not yet exist (expected RED state).
    """
    module_name = "dso_ci_review_plugin.classifier"

    if module_name in sys.modules:
        return sys.modules[module_name].classify_tier  # type: ignore[attr-defined]

    abs_path = _SCRIPTS_DIR / "dso_ci_review" / "classifier.py"
    spec = importlib.util.spec_from_file_location(module_name, abs_path)
    if spec is None or spec.loader is None:
        raise ImportError(
            f"Cannot load dso_ci_review.classifier from {abs_path} — "
            "file does not exist (expected RED state)"
        )
    mod = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod.classify_tier  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# Test 1 — empty/whitespace diff → light tier, no overlays, size_action "none"
# ---------------------------------------------------------------------------


def test_classify_tier_empty_diff() -> None:
    """
    Given: an empty string diff
    When:  classify_tier("") is called
    Then:  selected_tier is "light", size_action is "none", and all overlay
           flags are False — an empty diff carries zero blast-radius signals.
    """
    classify_tier = _load_classifier()
    result = classify_tier("")

    assert result["selected_tier"] == "light", (
        f"empty diff must produce 'light' tier; got {result['selected_tier']!r}"
    )
    assert result["size_action"] == "none", (
        f"empty diff must produce size_action 'none'; got {result['size_action']!r}"
    )
    assert result["security_overlay"] is False, (
        "empty diff must not trigger security_overlay"
    )
    assert result["performance_overlay"] is False, (
        "empty diff must not trigger performance_overlay"
    )
    assert result["test_quality_overlay"] is False, (
        "empty diff must not trigger test_quality_overlay"
    )


# ---------------------------------------------------------------------------
# Test 2 — large diff (>300 lines) → size_action is not "none"
# ---------------------------------------------------------------------------


def test_classify_tier_large_diff_warns() -> None:
    """
    Given: a diff that contains more than 300 changed lines
    When:  classify_tier(large_diff) is called
    Then:  size_action is not "none" — the classifier must signal that the
           diff exceeds the size threshold.
    """
    classify_tier = _load_classifier()

    # Build a diff with 310 added lines — well above the 300-line threshold.
    large_diff = "\n".join(f"+line {i}" for i in range(310))
    result = classify_tier(large_diff)

    assert result["size_action"] != "none", (
        f"diff with >300 lines must produce size_action != 'none'; "
        f"got {result['size_action']!r}"
    )
    assert result["diff_size_lines"] >= 300, (
        f"diff_size_lines must reflect the large diff; got {result['diff_size_lines']}"
    )


# ---------------------------------------------------------------------------
# Test 3 — security keywords in diff → security_overlay=True
# ---------------------------------------------------------------------------


def test_classify_tier_security_keywords() -> None:
    """
    Given: a diff that contains the words "password" and "secret"
    When:  classify_tier(security_diff) is called
    Then:  security_overlay is True — the classifier must detect security-
           sensitive terms and flag the overlay regardless of tier score.
    """
    classify_tier = _load_classifier()

    security_diff = "+    if user_password == stored_secret:\n+        grant_access()\n"
    result = classify_tier(security_diff)

    assert result["security_overlay"] is True, (
        "diff containing 'password' and 'secret' must set security_overlay=True; "
        f"got {result['security_overlay']!r}"
    )


# ---------------------------------------------------------------------------
# Test 4 — diff touching tests/ → test_quality_overlay=True
# ---------------------------------------------------------------------------


def test_classify_tier_test_files_touched() -> None:
    """
    Given: a diff whose file header includes a path under tests/
    When:  classify_tier(test_diff) is called
    Then:  test_quality_overlay is True — the classifier must recognise that
           test files are modified and activate the test quality overlay.
    """
    classify_tier = _load_classifier()

    test_diff = (
        "diff --git a/tests/unit/test_example.py b/tests/unit/test_example.py\n"
        "--- a/tests/unit/test_example.py\n"
        "+++ b/tests/unit/test_example.py\n"
        "+def test_new_behavior():\n"
        "+    assert True\n"
    )
    result = classify_tier(test_diff)

    assert result["test_quality_overlay"] is True, (
        "diff touching tests/ must set test_quality_overlay=True; "
        f"got {result['test_quality_overlay']!r}"
    )


# ---------------------------------------------------------------------------
# Test 5 — return dict always contains all required keys
# ---------------------------------------------------------------------------

_REQUIRED_KEYS = {
    "selected_tier",
    "size_action",
    "security_overlay",
    "performance_overlay",
    "test_quality_overlay",
    "diff_size_lines",
}


def test_classify_tier_returns_required_keys() -> None:
    """
    Given: any non-empty diff
    When:  classify_tier(diff) is called
    Then:  the returned dict contains every required key — callers must be
           able to rely on a stable interface regardless of the diff content.
    """
    classify_tier = _load_classifier()

    sample_diff = "+some change\n-old line\n"
    result = classify_tier(sample_diff)

    assert isinstance(result, dict), (
        f"classify_tier must return a dict; got {type(result).__name__}"
    )
    missing = _REQUIRED_KEYS - result.keys()
    assert not missing, (
        f"classify_tier return value is missing required keys: {sorted(missing)}"
    )

    # Spot-check types for key fields
    assert result["selected_tier"] in {"light", "standard", "deep"}, (
        f"selected_tier must be one of light/standard/deep; got {result['selected_tier']!r}"
    )
    assert result["size_action"] in {"none", "warn", "upgrade"}, (
        f"size_action must be one of none/warn/upgrade; got {result['size_action']!r}"
    )
    assert isinstance(result["diff_size_lines"], int), (
        f"diff_size_lines must be an int; got {type(result['diff_size_lines']).__name__}"
    )
