#!/usr/bin/env python3
"""dso_reconciler.__main__ — steady-state pass orchestrator.

Invoked as ``python -m dso_reconciler`` by the GHA reconcile-bridge workflow.
Orchestrates one steady-state pass calling the pipeline modules in sequence:
  fetcher → differ → applier → mapping → manifest → health

Modules that do not exist yet are skipped gracefully (walking-skeleton pattern).

Exit codes:
  0 — all present modules converged successfully
  1 — an unrecoverable error occurred in a pipeline step
"""

from __future__ import annotations

import argparse
import datetime
import importlib
import importlib.util
import sys
from pathlib import Path


def _try_load_step(name: str):
    """Attempt to import a sibling module by name; return None if absent."""
    here = Path(__file__).parent
    module_path = here / f"{name}.py"
    if not module_path.exists():
        return None
    spec = importlib.util.spec_from_file_location(
        f"dso_reconciler.{name}", module_path
    )
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def run_pass(repo_root: Path | None = None) -> int:
    """Execute one steady-state reconciliation pass via reconcile.reconcile_once().

    Returns 0 on converged state, 1 on unrecoverable error.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    reconcile = _try_load_step("reconcile")
    if reconcile is None:
        # Walking-skeleton path: no pipeline modules implemented yet — exit cleanly.
        print("OK: walking-skeleton no-op (reconcile.py not present)")
        return 0

    pass_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H-%M-%S")
    try:
        result = reconcile.reconcile_once(pass_id, repo_root=repo_root)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: reconcile_once raised: {exc}", file=sys.stderr)
        return 1

    print(f"OK: steady-state pass converged — {result['mutation_count']} mutations")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point for ``python -m dso_reconciler``."""
    parser = argparse.ArgumentParser(prog="dso_reconciler")
    parser.add_argument(
        "--repo-root",
        default=None,
        help="Repository root (default: auto-detect from script location)",
    )
    args = parser.parse_args(argv)
    repo_root = Path(args.repo_root) if args.repo_root else None
    return run_pass(repo_root=repo_root)


if __name__ == "__main__":
    sys.exit(main())
