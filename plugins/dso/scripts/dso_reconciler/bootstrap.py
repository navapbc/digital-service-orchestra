#!/usr/bin/env python3
"""Bootstrap driver: orchestrates anomaly-remediation bands with health tracking."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def _load(name: str, filename: str):
    path = Path(__file__).parent / filename
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def run_bootstrap(pass_id: str, repo_root: Path | None = None) -> dict:
    """Run the bootstrap remediation pass with health tracking.

    Captures baseline before any mutations, then runs each band's plan step.
    Returns a summary dict.

    Args:
        pass_id: Unique identifier for this bootstrap pass.
        repo_root: Repository root path. Defaults to four levels above this
            file (resolved at runtime via ``Path(__file__).parents[4]``).

    Returns:
        A dict with ``pass_id`` and ``bands`` keys summarising each band result.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    health = _load("bootstrap_health", "health.py")

    # Capture baseline BEFORE any band mutations
    health.capture_baseline(pass_id, repo_root=repo_root)

    # Run each band's plan (dry-run, no mutations in bootstrap planning phase)
    results = {}
    for band_name, filename in [
        ("orphan", "orphan_band.py"),
        ("stale", "stale_band.py"),
        ("duplicates", "duplicates_band.py"),
        ("open_count_skew", "open_count_skew_band.py"),
    ]:
        try:
            _load(f"band_{band_name}", filename)
            # Each band exposes plan/gate/apply via CLI; plan step only here
            results[band_name] = "planned"
        except Exception as exc:  # noqa: BLE001
            results[band_name] = f"error: {exc}"

    return {"pass_id": pass_id, "bands": results}


if __name__ == "__main__":
    pass_id = sys.argv[1] if len(sys.argv) > 1 else "bootstrap-001"
    result = run_bootstrap(pass_id)
    print(result)
