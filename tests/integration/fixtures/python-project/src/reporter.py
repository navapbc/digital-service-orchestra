"""Reporter module that calls calculator, formatter, and validator."""
import os
import sys

from src.calculator import add, multiply, power
from src.formatter import format_sum, format_product, format_table
from src.validator import is_positive, validate_ratio


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
