"""Scorer module for computing weighted scores using add operations."""


from src.calculator import add


def score_pair(x, y, weight=1):
    """Return the weighted score for a (x, y) pair: (x + y) * weight."""
    pair_sum = add(x, y)
    return pair_sum * weight


def score_batch(pairs, weight=1):
    """Return the total score for a batch of pairs."""
    total = 0
    for x, y in pairs:
        total = add(total, score_pair(x, y, weight))
    return total


def score_combined(a_scores, b_scores):
    """Combine two score lists by adding corresponding elements."""
    return [add(a, b) for a, b in zip(a_scores, b_scores)]
