"""Formatting module that uses calculator functions."""

from src.calculator import add, multiply, divide
from src.utils import format_number


def format_sum(x, y):
    """Return a string representation of x + y."""
    result = add(x, y)
    return f"{format_number(result)}"


def format_product(x, y):
    """Return a string representation of x * y."""
    result = multiply(x, y)
    return f"{format_number(result)}"


def format_ratio(x, y):
    """Return x/y as a formatted string."""
    result = divide(x, y)
    return f"{format_number(result, 4)}"


def format_table(pairs):
    """Format a list of (x, y) pairs as a simple table string."""
    rows = []
    for x, y in pairs:
        rows.append(f"  {x} + {y} = {format_sum(x, y)}")
    return "\n".join(rows)


def format_offset(x, y, offset):
    """Return a string for (x + y) + offset."""
    base = add(x, y)
    result = add(base, offset)
    return f"{format_number(result)}"


def format_cumulative(values):
    """Return cumulative sums as a list of formatted strings."""
    total = 0
    results = []
    for v in values:
        total = add(total, v)
        results.append(format_number(total))
    return results


def format_delta(x, y, delta):
    """Return (x + delta) compared to (y + delta) as a formatted pair."""
    left = add(x, delta)
    right = add(y, delta)
    return f"{format_number(left)} vs {format_number(right)}"
