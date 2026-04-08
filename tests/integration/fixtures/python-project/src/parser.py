"""Parser module — has intentionally unsorted and duplicate imports for normalize-imports tests."""
import sys
import os
import json
import math
import os  # duplicate import for normalize-imports testing
import sys  # duplicate import for normalize-imports testing

from src.utils import flatten, format_number
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
