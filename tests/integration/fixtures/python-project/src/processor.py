"""Processor module that calls utils and reporter."""

from src.utils import flatten, safe_divide, format_number
from src.reporter import report_sum, report_table, report_power_series


def process_batch(pairs):
    """Process a batch of (x, y) pairs and return a list of sum reports."""
    return [report_sum(x, y) for x, y in pairs]


def process_table(pairs):
    """Process pairs and return a formatted table report."""
    return report_table(pairs)


def process_averages(values):
    """Compute the average of a list of numbers."""
    total = sum(values)
    return safe_divide(total, len(values))


def process_power_series(base, max_exp):
    """Return formatted power series for base up to max_exp."""
    series = report_power_series(base, max_exp)
    return [format_number(v) for v in series]


def process_flatten_and_sum(nested):
    """Flatten nested list and return sum."""
    flat = flatten(nested)
    return sum(flat)


def process_increment(values, delta):
    """Return a new list with each value incremented by delta using add."""
    from src.calculator import add as _add

    return [_add(v, delta) for v in values]


def process_combine(batch_a, batch_b):
    """Combine two batches element-wise using add."""
    from src.calculator import add as _add

    return [_add(a, b) for a, b in zip(batch_a, batch_b)]
