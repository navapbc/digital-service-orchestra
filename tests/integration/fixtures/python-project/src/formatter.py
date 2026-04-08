"""Formatting module that uses calculator functions."""
import sys
import os
import math

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
