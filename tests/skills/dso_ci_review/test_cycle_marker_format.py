"""Tests for cycle_marker_format module — bug 9788 fix.

Covers:
  - Round-trip (format -> parse) for v1.2.0 markers across an input sweep
  - Sentinel guard: format_cycle_marker(pr_number=0) raises ValueError
  - Backward compat: parser accepts v1.2.0, v1.1.0, v1.0.0 forms
  - Mixed-format dedup contract (cycle-ledger.md:80): v1.2.0 wins
  - Continuation marker parser support (writer wire-up is Bug D)
  - Arbiter marker round-trip
  - chunk_tuples behavior including edge cases
  - cycle_dedup_key + arbiter_dedup_key contract guarantees
"""

from __future__ import annotations

import json

import pytest

# conftest.py loads cycle_marker_format from plugins/dso/scripts and injects
# it as dso_ci_review.cycle_marker_format in sys.modules. Import the submodule
# path directly (matches the pattern other dso_ci_review tests use).
from dso_ci_review import cycle_marker_format as cmf


# ---------------------------------------------------------------------------
# Round-trip tests
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("cycle_num", [1, 2, 4, 99, 999])
@pytest.mark.parametrize("pr_number", [1, 42, 252, 999999])
@pytest.mark.parametrize(
    "tuples",
    [
        [],
        [["src/foo.py", "10", "critical"]],
        [["src/foo.py", "10", "critical"], ["src/bar.py", "20", "important"]],
        [["path with spaces.py", "1", "minor"]],
        [["src/foo.py", "10", "critical with : and = in text"]],
    ],
    ids=["empty", "one", "two", "spaces", "punctuation"],
)
def test_v12_round_trip(cycle_num, pr_number, tuples):
    """format -> parse returns the same fields."""
    line = cmf.format_cycle_marker(
        cycle_num=cycle_num,
        pr_number=pr_number,
        commit_sha="abc123def456",
        findings_hash="hash_xyz",
        tuples=tuples,
    )
    parsed = cmf.parse_cycle_marker(line)
    assert parsed is not None, f"failed to parse: {line!r}"
    assert parsed.cycle_num == cycle_num
    assert parsed.pr_number == pr_number
    assert parsed.commit_sha == "abc123def456"
    assert parsed.findings_hash == "hash_xyz"
    assert parsed.tuples == tuples
    assert parsed.schema_version == "1.2.0"
    assert parsed.continuation_index is None
    assert parsed.continuation_total is None


def test_v12_continuation_round_trip():
    line = cmf.format_cycle_marker(
        cycle_num=2,
        pr_number=42,
        commit_sha="abc",
        findings_hash="h",
        tuples=[["a.py", "1", "critical"]],
        continuation_index=2,
        continuation_total=3,
    )
    parsed = cmf.parse_cycle_marker(line)
    assert parsed is not None
    assert parsed.continuation_index == 2
    assert parsed.continuation_total == 3
    assert parsed.schema_version == "1.2.0"


# ---------------------------------------------------------------------------
# Sentinel guard
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bad_pr", [0, -1, -42])
def test_format_rejects_invalid_pr_number(bad_pr):
    with pytest.raises(ValueError, match=r"pr_number must be > 0"):
        cmf.format_cycle_marker(
            cycle_num=1,
            pr_number=bad_pr,
            commit_sha="abc",
            findings_hash="h",
            tuples=[],
        )


def test_format_rejects_none_pr_number():
    with pytest.raises(ValueError, match=r"pr_number must be > 0"):
        cmf.format_cycle_marker(
            cycle_num=1,
            pr_number=None,  # type: ignore[arg-type]
            commit_sha="abc",
            findings_hash="h",
            tuples=[],
        )


@pytest.mark.parametrize("bad_cycle", [0, -1])
def test_format_rejects_invalid_cycle_num(bad_cycle):
    with pytest.raises(ValueError, match=r"cycle_num must be >= 1"):
        cmf.format_cycle_marker(
            cycle_num=bad_cycle,
            pr_number=1,
            commit_sha="abc",
            findings_hash="h",
            tuples=[],
        )


def test_format_rejects_partial_continuation():
    with pytest.raises(ValueError, match=r"continuation_index and continuation_total"):
        cmf.format_cycle_marker(
            cycle_num=1,
            pr_number=1,
            commit_sha="abc",
            findings_hash="h",
            tuples=[],
            continuation_index=1,
            continuation_total=None,
        )


def test_format_rejects_continuation_index_exceeds_total():
    with pytest.raises(ValueError, match=r"<= continuation_total"):
        cmf.format_cycle_marker(
            cycle_num=1,
            pr_number=1,
            commit_sha="abc",
            findings_hash="h",
            tuples=[],
            continuation_index=5,
            continuation_total=3,
        )


@pytest.mark.parametrize(
    "idx,total",
    [(0, 1), (1, 0), (0, 0), (-1, 1), (1, -1)],
    ids=["idx_zero", "total_zero", "both_zero", "idx_neg", "total_neg"],
)
def test_format_rejects_zero_or_negative_continuation_values(idx, total):
    """continuation_index and continuation_total must both be >= 1."""
    with pytest.raises(
        ValueError, match=r"continuation_index and continuation_total must be >= 1"
    ):
        cmf.format_cycle_marker(
            cycle_num=1,
            pr_number=1,
            commit_sha="abc",
            findings_hash="h",
            tuples=[],
            continuation_index=idx,
            continuation_total=total,
        )


@pytest.mark.parametrize("bad", ["", None])
def test_format_rejects_empty_commit_sha(bad):
    with pytest.raises(ValueError, match=r"commit_sha must be a non-empty string"):
        cmf.format_cycle_marker(
            cycle_num=1,
            pr_number=1,
            commit_sha=bad,  # type: ignore[arg-type]
            findings_hash="h",
            tuples=[],
        )


@pytest.mark.parametrize("bad", ["", None])
def test_format_rejects_empty_findings_hash(bad):
    with pytest.raises(ValueError, match=r"findings_hash must be a non-empty string"):
        cmf.format_cycle_marker(
            cycle_num=1,
            pr_number=1,
            commit_sha="abc",
            findings_hash=bad,  # type: ignore[arg-type]
            tuples=[],
        )


# ---------------------------------------------------------------------------
# Backward compatibility — parser accepts older schemas
# ---------------------------------------------------------------------------


def test_parse_v11_marker():
    """v1.1.0 markers parse with pr_number=SENTINEL_PR_NUMBER (0)."""
    line = (
        "DSO-Review-Cycle: 3 commit_sha=abc123 findings_hash=h1 "
        'tuples=[["x.py","1","c"]]'
    )
    parsed = cmf.parse_cycle_marker(line)
    assert parsed is not None
    assert parsed.cycle_num == 3
    assert parsed.pr_number == cmf.SENTINEL_PR_NUMBER == 0
    assert parsed.commit_sha == "abc123"
    assert parsed.schema_version == "1.1.0"


def test_parse_v10_legacy_marker():
    """v1.0.0 markers parse with empty commit_sha/tuples and sentinel pr_number."""
    line = "DSO-Review-Cycle: 1 findings-hash=h_old"
    parsed = cmf.parse_cycle_marker(line)
    assert parsed is not None
    assert parsed.cycle_num == 1
    assert parsed.pr_number == cmf.SENTINEL_PR_NUMBER
    assert parsed.commit_sha == ""
    assert parsed.findings_hash == "h_old"
    assert parsed.tuples == []
    assert parsed.schema_version == "1.0.0"


def test_parse_v10_legacy_without_findings_hash():
    line = "DSO-Review-Cycle: 2"
    parsed = cmf.parse_cycle_marker(line)
    assert parsed is not None
    assert parsed.cycle_num == 2
    assert parsed.schema_version == "1.0.0"
    assert parsed.findings_hash == ""


def test_parse_rejects_broken_cycle_eq_form():
    """The pre-fix writer emitted `cycle=K` — that form must NOT parse as a
    cycle_num, otherwise we silently accept the broken historical format.

    This is the regression-guard for bug 9788.
    """
    line = (
        "DSO-Review-Cycle: cycle=1 commit_sha=abc findings_hash=h "
        'tuples=[["x.py","1","c"]]'
    )
    parsed = cmf.parse_cycle_marker(line)
    assert parsed is None, f"broken cycle=K form must not parse, got {parsed!r}"


def test_parse_returns_none_for_non_marker():
    assert cmf.parse_cycle_marker("") is None
    assert cmf.parse_cycle_marker("random text") is None
    assert cmf.parse_cycle_marker("DSO-Other-Marker: 1") is None


def test_parse_returns_none_for_malformed_tuples_json():
    line = (
        "DSO-Review-Cycle: 1 pr_number=42 commit_sha=abc findings_hash=h "
        "tuples=[not-json]"
    )
    parsed = cmf.parse_cycle_marker(line)
    assert parsed is None


# ---------------------------------------------------------------------------
# Mixed-format dedup contract (cycle-ledger.md:80 — v1.2.0 wins for same
# (cycle_num, commit_sha)). The supersession itself is the consumer's
# responsibility (cycle_ledger.py:_supersede_by_pr_sha); this test only
# validates that the parser surfaces enough schema info for that decision.
# ---------------------------------------------------------------------------


def test_schema_version_tagged_on_parse():
    """Three markers for same (cycle_num, commit_sha) parse with distinct
    schema_version tags so the consumer can apply the supersession rule."""
    v12 = cmf.format_cycle_marker(
        cycle_num=1, pr_number=42, commit_sha="abc", findings_hash="h", tuples=[]
    )
    v11 = "DSO-Review-Cycle: 1 commit_sha=abc findings_hash=h tuples=[]"
    v10 = "DSO-Review-Cycle: 1 findings-hash=h_old"

    p12 = cmf.parse_cycle_marker(v12)
    p11 = cmf.parse_cycle_marker(v11)
    p10 = cmf.parse_cycle_marker(v10)

    assert p12.schema_version == "1.2.0"
    assert p11.schema_version == "1.1.0"
    assert p10.schema_version == "1.0.0"
    assert p12.pr_number == 42
    assert p11.pr_number == cmf.SENTINEL_PR_NUMBER
    assert p10.pr_number == cmf.SENTINEL_PR_NUMBER


# ---------------------------------------------------------------------------
# Arbiter marker
# ---------------------------------------------------------------------------


def test_arbiter_marker_round_trip():
    line = cmf.format_arbiter_marker(cycle_num=4, commit_sha="deadbeef")
    parsed = cmf.parse_arbiter_marker(line)
    assert parsed is not None
    assert parsed.cycle_num == 4
    assert parsed.commit_sha == "deadbeef"


def test_arbiter_marker_rejects_broken_cycle_eq_form():
    """Regression guard: the pre-fix arbiter marker at runner.py:430 and :2411
    used `cycle=K` form. That form must NOT parse."""
    line = "DSO-Arbiter-Ruling: cycle=4 commit_sha=deadbeef"
    parsed = cmf.parse_arbiter_marker(line)
    assert parsed is None


def test_arbiter_marker_format_rejects_invalid_cycle():
    with pytest.raises(ValueError, match=r"cycle_num must be >= 1"):
        cmf.format_arbiter_marker(cycle_num=0, commit_sha="abc")


# ---------------------------------------------------------------------------
# Dedup key contract
# ---------------------------------------------------------------------------


def test_cycle_dedup_key_substrings_appear_in_formatted_marker():
    """The dedup_key contract: both substrings appear verbatim in the marker
    body emitted by format_cycle_marker."""
    cycle, sha = 7, "abc123"
    line = cmf.format_cycle_marker(
        cycle_num=cycle, pr_number=42, commit_sha=sha, findings_hash="h", tuples=[]
    )
    k1, k2 = cmf.cycle_dedup_key(cycle, sha)
    assert k1 in line, f"first dedup substring {k1!r} missing from {line!r}"
    assert k2 in line, f"second dedup substring {k2!r} missing from {line!r}"


def test_cycle_dedup_key_does_not_collide_across_cycles():
    """Two different cycle_nums on the same SHA produce distinct dedup pairs."""
    sha = "abc"
    k1_c1, k2_c1 = cmf.cycle_dedup_key(1, sha)
    k1_c2, k2_c2 = cmf.cycle_dedup_key(2, sha)
    assert k1_c1 != k1_c2  # the cycle substring differs
    assert k2_c1 == k2_c2  # the sha substring is identical


def test_cycle_dedup_key_does_not_collide_across_shas():
    cycle = 1
    k1_a, k2_a = cmf.cycle_dedup_key(cycle, "abc")
    k1_b, k2_b = cmf.cycle_dedup_key(cycle, "def")
    assert k1_a == k1_b  # the cycle substring is identical
    assert k2_a != k2_b  # the sha substring differs


def test_arbiter_dedup_key_matches_arbiter_marker_body():
    cycle, sha = 3, "abc"
    body = cmf.format_arbiter_marker(cycle_num=cycle, commit_sha=sha)
    key = cmf.arbiter_dedup_key(cycle, sha)
    assert key == body  # the full marker IS the dedup key


# ---------------------------------------------------------------------------
# chunk_tuples
# ---------------------------------------------------------------------------


def test_chunk_tuples_empty_input_returns_single_empty_chunk():
    assert cmf.chunk_tuples([]) == [[]]


def test_chunk_tuples_below_threshold_returns_single_chunk():
    items = [[i] for i in range(10)]
    chunks = cmf.chunk_tuples(items, max_per_chunk=50)
    assert len(chunks) == 1
    assert chunks[0] == items


def test_chunk_tuples_at_threshold_returns_single_chunk():
    items = [[i] for i in range(50)]
    chunks = cmf.chunk_tuples(items, max_per_chunk=50)
    assert len(chunks) == 1
    assert len(chunks[0]) == 50


def test_chunk_tuples_above_threshold_splits_correctly():
    items = [[i] for i in range(125)]
    chunks = cmf.chunk_tuples(items, max_per_chunk=50)
    assert len(chunks) == 3
    assert len(chunks[0]) == 50
    assert len(chunks[1]) == 50
    assert len(chunks[2]) == 25
    # round-trip: concat preserves input
    flat = [item for chunk in chunks for item in chunk]
    assert flat == items


def test_chunk_tuples_rejects_invalid_max():
    with pytest.raises(ValueError, match=r"max_per_chunk must be >= 1"):
        cmf.chunk_tuples([1, 2, 3], max_per_chunk=0)


# ---------------------------------------------------------------------------
# Format integrity — body contains exact pr_number=N unquoted decimal
# (dedup_key relies on this — see cycle_dedup_key docstring)
# ---------------------------------------------------------------------------


def test_format_emits_unquoted_decimal_pr_number():
    line = cmf.format_cycle_marker(
        cycle_num=1, pr_number=42, commit_sha="abc", findings_hash="h", tuples=[]
    )
    assert " pr_number=42 " in line  # unquoted, surrounded by spaces


def test_format_emits_valid_json_tuples():
    """The tuples field must be parseable as JSON regardless of input content."""
    weird_tuples = [["[bracket]", "='='", '"quote"', "back\\slash"]]
    line = cmf.format_cycle_marker(
        cycle_num=1,
        pr_number=42,
        commit_sha="abc",
        findings_hash="h",
        tuples=weird_tuples,
    )
    parsed = cmf.parse_cycle_marker(line)
    assert parsed is not None
    assert parsed.tuples == weird_tuples
    # Independently verify the tuples= segment is valid JSON
    tuples_segment = line.split("tuples=", 1)[1]
    assert json.loads(tuples_segment) == weird_tuples
