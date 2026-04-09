"""Aggregator module that combines results from multiple calculator operations."""

from src.calculator import add


def aggregate_pairs(pairs):
    """Return the total sum of all (x, y) pair sums."""
    total = 0
    for x, y in pairs:
        total = add(total, add(x, y))
    return total


def aggregate_with_offset(values, offset):
    """Return a list where each value has offset added."""
    return [add(v, offset) for v in values]


def aggregate_total(batches):
    """Sum all values across multiple batches using add."""
    total = 0
    for batch in batches:
        for v in batch:
            total = add(total, v)
    return total
