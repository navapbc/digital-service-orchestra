"""Validation module that calls calculator and utils functions."""

from src.calculator import add, subtract
from src.utils import clamp, safe_divide


def is_positive(value):
    """Return True if value is greater than zero."""
    return value > 0


def is_in_range(value, low, high):
    """Return True if low <= value <= high."""
    clamped = clamp(value, low, high)
    return clamped == value


def validate_ratio(numerator, denominator, min_ratio=0.0, max_ratio=1.0):
    """Return True if numerator/denominator is within [min_ratio, max_ratio]."""
    ratio = safe_divide(numerator, denominator)
    return min_ratio <= ratio <= max_ratio


def validate_sum(x, y, expected):
    """Return True if x + y equals expected (within floating-point tolerance)."""
    result = add(x, y)
    return abs(result - expected) < 1e-9


def validate_difference(x, y, expected):
    """Return True if x - y equals expected."""
    result = subtract(x, y)
    return abs(result - expected) < 1e-9


def validate_pair_sum(pairs, expected_total):
    """Return True if the sum of all pair sums equals expected_total."""
    total = 0
    for x, y in pairs:
        total = add(total, add(x, y))
    return abs(total - expected_total) < 1e-9
