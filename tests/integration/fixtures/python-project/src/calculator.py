"""Calculator module with arithmetic operations."""
import math
import os
import sys

from src.utils import clamp, safe_divide


def add(x, y):
    """Add two numbers."""
    return x + y


def subtract(x, y):
    """Subtract y from x."""
    return x - y


def multiply(x, y):
    """Multiply two numbers."""
    return x * y


def divide(x, y):
    """Divide x by y, returning 0.0 on division by zero."""
    return safe_divide(x, y)


def power(base, exponent):
    """Raise base to exponent."""
    return base ** exponent


def sqrt(value):
    """Return square root of value; clamp to 0 if negative."""
    return math.sqrt(clamp(value, 0, float('inf')))
