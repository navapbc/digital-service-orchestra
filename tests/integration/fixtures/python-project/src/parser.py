"""Parser module — has intentionally unsorted and duplicate imports for normalize-imports tests."""

import json

from src.utils import flatten
from src.calculator import add


def parse_int(value):
    """Parse value as integer, returning None on failure."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_float(value):
    """Parse value as float, returning None on failure."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_list(value, separator=","):
    """Split value by separator and return list of stripped tokens."""
    if not value:
        return []
    parts = [v.strip() for v in value.split(separator)]
    return flatten([[p] for p in parts if p])


def parse_json_safe(text):
    """Parse JSON text; return None on error."""
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return None


def parse_and_add(a_str, b_str):
    """Parse two numeric strings and return their sum."""
    a = parse_float(a_str)
    b = parse_float(b_str)
    if a is None or b is None:
        return None
    return add(a, b)


def parse_offset(value_str, offset):
    """Parse a numeric string and add a fixed offset."""
    value = parse_float(value_str)
    if value is None:
        return None
    return add(value, offset)
