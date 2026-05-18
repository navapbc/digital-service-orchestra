"""RED tests for cycle marker comment and findings hash functionality in runner.py.

Tests for two not-yet-implemented functions:
- _post_cycle_marker_comment(pr_number, cycle_num, commit_sha, findings_hash, tuples)
- _compute_findings_hash(tuples)

All tests in this file MUST FAIL until those functions are implemented.
Task: 5a3b-eb6e-8177-44c3
"""

import json
import re
from unittest.mock import MagicMock, patch

import pytest

# These imports will fail until the functions are implemented.
# Use try/except so tests collect properly but fail at call time.
try:
    from dso_ci_review.runner import _compute_findings_hash, _post_cycle_marker_comment
except ImportError:
    _post_cycle_marker_comment = None
    _compute_findings_hash = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_MARKER_PREFIX = "DSO-Review-Cycle:"


def _make_comment(body: str, comment_id: int = 1001) -> dict:
    """Return a minimal GitHub comment dict with given body and id."""
    return {"id": comment_id, "body": body}


def _marker_body(cycle_num: int, commit_sha: str, findings_hash: str) -> str:
    """Return the expected marker body string."""
    return (
        f"{_MARKER_PREFIX} cycle={cycle_num} commit_sha={commit_sha} "
        f"findings_hash={findings_hash}"
    )


# ---------------------------------------------------------------------------
# Test 1: CREATE new comment when no existing marker
# ---------------------------------------------------------------------------


def test_post_cycle_marker_creates_new_comment_when_absent():
    """
    Given: PR 123, no existing DSO-Review-Cycle marker for (cycle_num=1, commit_sha=abc123)
    When: _post_cycle_marker_comment is called
    Then: a CREATE (POST) gh api call is made with body matching the marker format

    RED: fails because _post_cycle_marker_comment does not exist yet.
    """
    if _post_cycle_marker_comment is None:
        pytest.fail("_post_cycle_marker_comment not implemented in dso_ci_review.runner")

    pr_number = "123"
    cycle_num = 1
    commit_sha = "abc123"
    findings_hash = "h1"
    tuples = [("file.py", "1", "correctness")]

    list_response = MagicMock()
    list_response.returncode = 0
    list_response.stdout = json.dumps([])
    list_response.stderr = ""

    create_response = MagicMock()
    create_response.returncode = 0
    create_response.stdout = json.dumps({"id": 9999})
    create_response.stderr = ""

    with patch("subprocess.run", side_effect=[list_response, create_response]) as mock_run:
        _post_cycle_marker_comment(
            pr_number=pr_number,
            cycle_num=cycle_num,
            commit_sha=commit_sha,
            findings_hash=findings_hash,
            tuples=tuples,
        )

    # Verify a CREATE call was made (second call) with the expected marker body
    assert mock_run.call_count >= 2, (
        f"Expected at least 2 subprocess.run calls (list + create), got {mock_run.call_count}"
    )

    # Inspect all call args for the CREATE call containing the marker body
    all_call_args = [str(c) for c in mock_run.call_args_list]
    expected_marker = _marker_body(cycle_num, commit_sha, findings_hash)
    create_calls_with_marker = [
        c for c in all_call_args if expected_marker in c
    ]
    assert create_calls_with_marker, (
        f"Expected a gh api call containing '{expected_marker}' in its args.\n"
        f"Actual calls: {all_call_args}"
    )


# ---------------------------------------------------------------------------
# Test 2: UPDATE existing comment when cycle+SHA match
# ---------------------------------------------------------------------------


def test_post_cycle_marker_updates_existing_with_same_cycle_and_sha():
    """
    Given: existing comment with DSO-Review-Cycle: cycle=2 commit_sha=abc
    When: _post_cycle_marker_comment is called with (cycle_num=2, commit_sha=abc)
    Then: a PATCH/UPDATE call is made, NOT a new CREATE call

    RED: fails because _post_cycle_marker_comment does not exist yet.
    """
    if _post_cycle_marker_comment is None:
        pytest.fail("_post_cycle_marker_comment not implemented in dso_ci_review.runner")

    existing_body = _marker_body(cycle_num=2, commit_sha="abc", findings_hash="old_hash")
    existing_comment = _make_comment(existing_body, comment_id=5555)

    list_response = MagicMock()
    list_response.returncode = 0
    list_response.stdout = json.dumps([existing_comment])
    list_response.stderr = ""

    patch_response = MagicMock()
    patch_response.returncode = 0
    patch_response.stdout = json.dumps({"id": 5555})
    patch_response.stderr = ""

    with patch("subprocess.run", side_effect=[list_response, patch_response]) as mock_run:
        _post_cycle_marker_comment(
            pr_number="99",
            cycle_num=2,
            commit_sha="abc",
            findings_hash="h2",
            tuples=[],
        )

    assert mock_run.call_count >= 2, (
        f"Expected list call + patch/update call, got {mock_run.call_count}"
    )

    # The update call must reference the existing comment id (5555), not create a new one.
    all_call_args = [str(c) for c in mock_run.call_args_list]
    calls_with_comment_id = [c for c in all_call_args if "5555" in c]
    assert calls_with_comment_id, (
        f"Expected PATCH call referencing existing comment id 5555.\n"
        f"Actual calls: {all_call_args}"
    )

    # Ensure no CREATE (POST without comment id) was made — no new endpoint like
    # /repos/.../issues/comments without an id suffix in path.
    new_marker = _marker_body(cycle_num=2, commit_sha="abc", findings_hash="h2")
    # The update call should include the new hash but reference the old comment id.
    update_calls = [c for c in all_call_args if new_marker in c and "5555" in c]
    assert update_calls, (
        f"Expected a PATCH call with comment id 5555 and updated marker body '{new_marker}'.\n"
        f"Actual calls: {all_call_args}"
    )


# ---------------------------------------------------------------------------
# Test 3: CREATE new comment when SHA differs (no overwrite of old marker)
# ---------------------------------------------------------------------------


def test_post_cycle_marker_does_not_overwrite_marker_for_different_sha():
    """
    Given: existing comment for (cycle_num=1, commit_sha=old_sha)
    When: _post_cycle_marker_comment called with (cycle_num=1, commit_sha=new_sha)
    Then: CREATE call for new_sha (different SHA → new comment), NOT PATCH of old comment

    RED: fails because _post_cycle_marker_comment does not exist yet.
    """
    if _post_cycle_marker_comment is None:
        pytest.fail("_post_cycle_marker_comment not implemented in dso_ci_review.runner")

    old_sha = "old_sha"
    new_sha = "new_sha"
    old_body = _marker_body(cycle_num=1, commit_sha=old_sha, findings_hash="old_h")
    old_comment = _make_comment(old_body, comment_id=7777)

    list_response = MagicMock()
    list_response.returncode = 0
    list_response.stdout = json.dumps([old_comment])
    list_response.stderr = ""

    create_response = MagicMock()
    create_response.returncode = 0
    create_response.stdout = json.dumps({"id": 8888})
    create_response.stderr = ""

    with patch("subprocess.run", side_effect=[list_response, create_response]) as mock_run:
        _post_cycle_marker_comment(
            pr_number="55",
            cycle_num=1,
            commit_sha=new_sha,
            findings_hash="new_h",
            tuples=[],
        )

    assert mock_run.call_count >= 2, (
        f"Expected list call + create call for new SHA, got {mock_run.call_count}"
    )

    all_call_args = [str(c) for c in mock_run.call_args_list]

    # Must NOT patch old comment (7777)
    patch_calls_for_old = [c for c in all_call_args if "7777" in c]
    assert not patch_calls_for_old, (
        f"Should NOT have patched the old comment (id=7777) for a different SHA.\n"
        f"Actual calls: {all_call_args}"
    )

    # Must CREATE a new comment with new_sha marker
    new_marker = _marker_body(cycle_num=1, commit_sha=new_sha, findings_hash="new_h")
    create_calls = [c for c in all_call_args if new_marker in c]
    assert create_calls, (
        f"Expected a CREATE call with marker '{new_marker}'.\n"
        f"Actual calls: {all_call_args}"
    )


# ---------------------------------------------------------------------------
# Test 4: Skip all gh CLI calls when pr_number is None
# ---------------------------------------------------------------------------


def test_post_cycle_marker_skips_when_no_pr():
    """
    Given: pr_number=None
    When: _post_cycle_marker_comment is called
    Then: no subprocess.run calls are made (no gh CLI invocations)

    RED: fails because _post_cycle_marker_comment does not exist yet.
    """
    if _post_cycle_marker_comment is None:
        pytest.fail("_post_cycle_marker_comment not implemented in dso_ci_review.runner")

    with patch("subprocess.run") as mock_run:
        _post_cycle_marker_comment(
            pr_number=None,
            cycle_num=1,
            commit_sha="abc",
            findings_hash="h",
            tuples=[],
        )

    assert mock_run.call_count == 0, (
        f"Expected no subprocess.run calls when pr_number=None, "
        f"got {mock_run.call_count} call(s): {mock_run.call_args_list}"
    )


# ---------------------------------------------------------------------------
# Test 5: main() calls cycle_ledger.append_cycle after review
# ---------------------------------------------------------------------------


def test_append_cycle_called_after_review(tmp_path):
    """
    Given: runner.main() called with mocked dispatch returning findings
    When: main() completes the review pipeline
    Then: cycle_ledger.append_cycle is called with correct positional args:
          (path, cycle_num, findings_tuples, commit_sha, findings_hash, halt_reason=None)

    RED: fails because:
      1. _post_cycle_marker_comment doesn't exist yet (import error surfaces here), AND
      2. cycle_ledger.append_cycle is not called by the current main() implementation.
    """
    if _post_cycle_marker_comment is None:
        pytest.fail(
            "_post_cycle_marker_comment not implemented — main() cannot call it, "
            "so cycle_ledger.append_cycle will never be reached with correct args"
        )

    import dso_ci_review.runner as runner_mod

    diff_text = "diff --git a/foo.py b/foo.py\n+added line\n"
    output_file = tmp_path / "findings.json"
    diff_file = tmp_path / "input.diff"
    diff_file.write_text(diff_text)

    tier_result = {
        "selected_tier": "standard",
        "size_action": "none",
        "security_overlay": False,
        "performance_overlay": False,
        "test_quality_overlay": False,
        "diff_size_lines": 1,
        "blast_radius": 1,
        "critical_path": 0,
        "anti_shortcut": 0,
        "staleness": 0,
        "cross_cutting": 0,
        "diff_lines": 0,
        "change_volume": 0,
        "computed_total": 1,
        "is_merge_commit": False,
    }
    specialist_findings = [
        {
            "findings": [
                {
                    "severity": "minor",
                    "description": "test finding",
                    "cited_lines": ["foo.py:1"],
                }
            ],
            "scores": {"correctness": 1},
            "summary": "minor issue",
        }
    ]

    async def mock_dispatch(agents):
        return specialist_findings

    append_cycle_calls: list = []

    def mock_append_cycle(path, cycle_num, findings_tuples, commit_sha, findings_hash, halt_reason=None):
        append_cycle_calls.append(
            dict(
                path=path,
                cycle_num=cycle_num,
                findings_tuples=findings_tuples,
                commit_sha=commit_sha,
                findings_hash=findings_hash,
                halt_reason=halt_reason,
            )
        )

    with (
        patch.dict(
            "os.environ",
            {
                "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
                "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
                "CI_REVIEW_PROVIDER": "anthropic",
                "ANTHROPIC_API_KEY": "test-key",
                "WORKFLOW_PLUGIN_ARTIFACTS_DIR": str(tmp_path),
            },
        ),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=tier_result,
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        ),
        patch(
            "dso_ci_review.runner._init_cycle_ledger",
            return_value=1,
        ),
        patch(
            "dso_ci_review.runner.cycle_ledger.read_ledger",
            return_value={"cycles": []},
        ),
        patch(
            "dso_ci_review.runner.cycle_next_action",
            return_value={"action": "CONTINUE"},
        ),
        patch(
            "subprocess.check_output",
            return_value="deadbeef1234\n",
        ),
        patch(
            "dso_ci_review.runner._post_pr_review",
            return_value=(0, 0),
        ),
        patch(
            "dso_ci_review.runner.cycle_ledger.append_cycle",
            side_effect=mock_append_cycle,
        ),
    ):
        runner_mod.main()

    assert len(append_cycle_calls) == 1, (
        f"Expected cycle_ledger.append_cycle called exactly once after review, "
        f"got {len(append_cycle_calls)} call(s)"
    )

    recorded = append_cycle_calls[0]
    assert recorded["cycle_num"] == 1, (
        f"Expected cycle_num=1, got {recorded['cycle_num']}"
    )
    assert recorded["commit_sha"] == "deadbeef1234", (
        f"Expected commit_sha='deadbeef1234', got {recorded['commit_sha']!r}"
    )
    assert isinstance(recorded["findings_tuples"], list), (
        f"Expected findings_tuples to be a list, got {type(recorded['findings_tuples'])}"
    )
    assert isinstance(recorded["findings_hash"], str) and recorded["findings_hash"], (
        f"Expected non-empty findings_hash string, got {recorded['findings_hash']!r}"
    )
    assert recorded["halt_reason"] is None, (
        f"Expected halt_reason=None for passing review, got {recorded['halt_reason']!r}"
    )


# ---------------------------------------------------------------------------
# Test 6: _compute_findings_hash is deterministic and returns 16-char hex
# ---------------------------------------------------------------------------


def test_findings_hash_determinism():
    """
    Given: same set of findings tuples (potentially different order)
    When: _compute_findings_hash called twice
    Then: both calls return the same hash, matching ^[0-9a-f]{16}$

    RED: fails because _compute_findings_hash does not exist yet.
    """
    if _compute_findings_hash is None:
        pytest.fail("_compute_findings_hash not implemented in dso_ci_review.runner")

    tuples_a = [
        ("file_a.py", "10", "correctness"),
        ("file_b.py", "20", "security"),
        ("file_c.py", "5", "hygiene"),
    ]
    tuples_b = [
        ("file_c.py", "5", "hygiene"),
        ("file_a.py", "10", "correctness"),
        ("file_b.py", "20", "security"),
    ]

    hash_a = _compute_findings_hash(tuples_a)
    hash_b = _compute_findings_hash(tuples_b)

    # Both orderings must produce the same hash (order-independent)
    assert hash_a == hash_b, (
        f"_compute_findings_hash must be order-independent. "
        f"Got '{hash_a}' for order A and '{hash_b}' for order B."
    )

    # Hash must be a 16-character lowercase hex string
    hex_pattern = re.compile(r"^[0-9a-f]{16}$")
    assert hex_pattern.match(hash_a), (
        f"Expected 16-char hex string, got '{hash_a}'"
    )

    # Calling again with same input must produce same result (pure function)
    hash_a2 = _compute_findings_hash(tuples_a)
    assert hash_a == hash_a2, (
        f"_compute_findings_hash must be deterministic across calls. "
        f"First call: '{hash_a}', second call: '{hash_a2}'."
    )

    # Empty tuple list must also return a valid 16-char hex string
    empty_hash = _compute_findings_hash([])
    assert hex_pattern.match(empty_hash), (
        f"Expected 16-char hex for empty input, got '{empty_hash}'"
    )
