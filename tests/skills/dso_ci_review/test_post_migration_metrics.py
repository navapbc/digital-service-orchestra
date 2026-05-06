"""
DD4 — post-migration duration artifact tests.

Verifies that the post-migration timing fixture and capture script are
present and structurally correct.  All three tests are RED until the
implementation creates the required artifacts.
"""

import json
import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURE_PATH = REPO_ROOT / "tests" / "fixtures" / "ci-review-post-migration.json"
CAPTURE_SCRIPT_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "capture_ci_review_post_migration.py"
)


def test_post_migration_fixture_exists():
    """
    Given: the post-migration timing baseline has been captured
    When:  the fixture file path is checked
    Then:  tests/fixtures/ci-review-post-migration.json exists and is non-empty

    RED: file does not exist yet (implementation must create it).
    """
    assert FIXTURE_PATH.exists(), (
        f"Post-migration fixture not found at {FIXTURE_PATH}. "
        "Run capture_ci_review_post_migration.py to generate it."
    )
    assert FIXTURE_PATH.stat().st_size > 0, (
        f"Post-migration fixture at {FIXTURE_PATH} is empty."
    )


def test_post_migration_fixture_has_required_keys():
    """
    Given: tests/fixtures/ci-review-post-migration.json exists
    When:  the file is loaded as JSON
    Then:  the parsed dict contains 'p50_seconds', 'p95_seconds', and 'run_count' keys

    RED: file does not exist yet; json.loads() will never be reached until it does.
    """
    assert FIXTURE_PATH.exists(), (
        f"Post-migration fixture not found at {FIXTURE_PATH}. "
        "Cannot validate required keys."
    )
    content = FIXTURE_PATH.read_text(encoding="utf-8")
    try:
        data = json.loads(content)
    except json.JSONDecodeError as exc:
        raise AssertionError(
            f"Post-migration fixture at {FIXTURE_PATH} is not valid JSON: {exc}"
        ) from exc

    required_keys = {"p50_seconds", "p95_seconds", "run_count"}
    missing = required_keys - set(data.keys())
    assert not missing, (
        f"Post-migration fixture is missing required keys: {sorted(missing)}. "
        f"Present keys: {sorted(data.keys())}"
    )


def test_capture_script_exists():
    """
    Given: the DD4 capture script has been written
    When:  the script path is checked
    Then:  plugins/dso/scripts/capture_ci_review_post_migration.py exists

    RED: script does not exist yet (implementation must create it).
    """
    assert CAPTURE_SCRIPT_PATH.exists(), (
        f"Capture script not found at {CAPTURE_SCRIPT_PATH}. "
        "Implementation must create capture_ci_review_post_migration.py."
    )
