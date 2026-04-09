"""Reporter module that calls calculator, formatter, and validator."""

from src.calculator import add, multiply, power
from src.formatter import format_sum, format_product, format_table
from src.validator import is_positive


def report_sum(x, y):
    """Return a report string for the sum of x and y."""
    result = add(x, y)
    label = "positive" if is_positive(result) else "non-positive"
    return f"sum({x}, {y}) = {format_sum(x, y)} [{label}]"


def report_product(x, y):
    """Return a report string for the product of x and y."""
    result = multiply(x, y)
    label = "positive" if is_positive(result) else "non-positive"
    return f"product({x}, {y}) = {format_product(x, y)} [{label}]"


def report_table(pairs):
    """Return a formatted table of sums."""
    return "Sums:\n" + format_table(pairs)


def report_power_series(base, max_exp):
    """Return a list of base^n for n in 0..max_exp."""
    return [power(base, n) for n in range(max_exp + 1)]


def report_running_total(values):
    """Return a report of running totals using add."""
    total = 0
    lines = []
    for i, v in enumerate(values):
        total = add(total, v)
        lines.append(f"  [{i}] +{v} = {total}")
    return "Running totals:\n" + "\n".join(lines)


def report_pair_sums(pairs):
    """Return a list of sum values for each pair."""
    return [add(x, y) for x, y in pairs]
