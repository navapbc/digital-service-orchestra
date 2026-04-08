"""Tests for modules that call calculator.add — verifies callers work after add-parameter transform."""


from src.formatter import format_sum, format_offset, format_cumulative, format_delta
from src.reporter import report_sum, report_running_total, report_pair_sums
from src.validator import validate_sum, validate_pair_sum
from src.parser import parse_and_add, parse_offset
from src.aggregator import aggregate_pairs, aggregate_with_offset, aggregate_total
from src.scorer import score_pair, score_batch, score_combined


# ── formatter tests ────────────────────────────────────────────────────────────


def test_format_sum():
    assert format_sum(2, 3) == "5.0"


def test_format_offset():
    # (1 + 2) + 4 = 7
    assert format_offset(1, 2, 4) == "7.0"


def test_format_cumulative():
    result = format_cumulative([1, 2, 3])
    assert result == [1.0, 3.0, 6.0]


def test_format_delta():
    result = format_delta(1, 2, 10)
    assert "11" in result and "12" in result


# ── reporter tests ─────────────────────────────────────────────────────────────


def test_report_sum():
    r = report_sum(3, 4)
    assert "7" in r and "positive" in r


def test_report_running_total():
    r = report_running_total([1, 2, 3])
    assert "Running totals" in r


def test_report_pair_sums():
    result = report_pair_sums([(1, 2), (3, 4)])
    assert result == [3, 7]


# ── validator tests ────────────────────────────────────────────────────────────


def test_validate_sum():
    assert validate_sum(2, 3, 5)
    assert not validate_sum(2, 3, 6)


def test_validate_pair_sum():
    # (1+2) + (3+4) = 10
    assert validate_pair_sum([(1, 2), (3, 4)], 10)
    assert not validate_pair_sum([(1, 2), (3, 4)], 11)


# ── parser tests ──────────────────────────────────────────────────────────────


def test_parse_and_add():
    assert parse_and_add("2.5", "3.5") == 6.0
    assert parse_and_add("bad", "3") is None


def test_parse_offset():
    assert parse_offset("10", 5) == 15.0
    assert parse_offset("not-a-number", 5) is None


# ── aggregator tests ──────────────────────────────────────────────────────────


def test_aggregate_pairs():
    # (1+2) + (3+4) = 10
    assert aggregate_pairs([(1, 2), (3, 4)]) == 10


def test_aggregate_with_offset():
    result = aggregate_with_offset([1, 2, 3], 10)
    assert result == [11, 12, 13]


def test_aggregate_total():
    result = aggregate_total([[1, 2], [3, 4]])
    assert result == 10


# ── scorer tests ──────────────────────────────────────────────────────────────


def test_score_pair():
    assert score_pair(3, 4) == 7
    assert score_pair(3, 4, weight=2) == 14


def test_score_batch():
    assert score_batch([(1, 2), (3, 4)]) == 10


def test_score_combined():
    result = score_combined([1, 2, 3], [4, 5, 6])
    assert result == [5, 7, 9]
