"""Utility functions for the fixture project."""



def clamp(value, minimum, maximum):
    """Return value clamped between minimum and maximum."""
    return max(minimum, min(maximum, value))


def safe_divide(numerator, denominator):
    """Divide numerator by denominator; return 0.0 if denominator is zero."""
    if denominator == 0:
        return 0.0
    return numerator / denominator


def flatten(nested_list):
    """Flatten a nested list one level deep."""
    result = []
    for item in nested_list:
        if isinstance(item, list):
            result.extend(item)
        else:
            result.append(item)
    return result


def format_number(value, decimals=2):
    """Format a number to a fixed number of decimal places."""
    return round(float(value), decimals)
