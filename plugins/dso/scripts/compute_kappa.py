"""
Cohen's kappa computation for visual-eval corpus.

Walks corpus directory, loads label pairs from llm_agent_run_1.json and
llm_agent_run_2.json per fixture, filters by provenance, computes kappa.

Formula: Cohen (1960) Educational and Psychological Measurement 20(1):37-46
Stdlib-only (no scipy, no sklearn).
"""

from __future__ import annotations

import json
from pathlib import Path


def load_labels(
    corpus_dir: str | Path,
    provenance_filter: str = "llm_agent",
) -> list[tuple[str, str]]:
    """Load (run_1.attribution_class, run_2.attribution_class) pairs.

    Skips fixtures where either label file is missing or has wrong provenance.
    """
    root = Path(corpus_dir)
    pairs: list[tuple[str, str]] = []

    for fixture_dir in sorted(root.iterdir()):
        if not fixture_dir.is_dir():
            continue
        run1_path = fixture_dir / "labels" / "llm_agent_run_1.json"
        run2_path = fixture_dir / "labels" / "llm_agent_run_2.json"

        if not run1_path.exists() or not run2_path.exists():
            continue

        try:
            run1 = json.loads(run1_path.read_text())
            run2 = json.loads(run2_path.read_text())
        except (json.JSONDecodeError, OSError):
            continue

        if run1.get("provenance") != provenance_filter:
            continue
        if run2.get("provenance") != provenance_filter:
            continue

        cls1 = run1.get("attribution_class")
        cls2 = run2.get("attribution_class")
        if cls1 and cls2:
            pairs.append((cls1, cls2))

    return pairs


def cohen_kappa(pairs: list[tuple[str, str]]) -> float:
    """Compute Cohen's kappa for a list of (rater1, rater2) label pairs.

    Raises ValueError if fewer than 2 pairs (kappa undefined).
    """
    if len(pairs) < 2:
        raise ValueError(f"Need at least 2 pairs to compute kappa, got {len(pairs)}")

    n = len(pairs)
    categories = sorted({c for pair in pairs for c in pair})
    k = len(categories)
    cat_index = {c: i for i, c in enumerate(categories)}

    # Build confusion matrix
    matrix = [[0] * k for _ in range(k)]
    for r1, r2 in pairs:
        matrix[cat_index[r1]][cat_index[r2]] += 1

    # Observed agreement
    p_o = sum(matrix[i][i] for i in range(k)) / n

    # Expected agreement by chance
    row_totals = [sum(row) for row in matrix]
    col_totals = [sum(matrix[i][j] for i in range(k)) for j in range(k)]
    p_e = sum((row_totals[i] / n) * (col_totals[i] / n) for i in range(k))

    if p_e == 1.0:
        return 1.0

    return (p_o - p_e) / (1.0 - p_e)


def compute_kappa(corpus_dir: str | Path) -> float:
    """Compute Cohen's kappa for llm_agent-labeled fixtures in corpus_dir."""
    pairs = load_labels(corpus_dir, provenance_filter="llm_agent")
    return cohen_kappa(pairs)
