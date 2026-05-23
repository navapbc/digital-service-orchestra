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

import importlib
import importlib.util
import sys
from pathlib import Path
from typing import Callable

# Pipeline modules called in order.  Modules not yet implemented are skipped.
_PIPELINE_STEPS: list[str] = [
    "fetcher",
    "differ",
    "applier",
    "mapping",
    "manifest",
    "health",
]


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
    """Execute one steady-state reconciliation pass.

    Returns 0 on converged state, 1 on unrecoverable error.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    for step_name in _PIPELINE_STEPS:
        mod = _try_load_step(step_name)
        if mod is None:
            # Module not yet implemented — walking skeleton, skip gracefully.
            continue

        run_fn: Callable[..., int] | None = getattr(mod, "run", None)
        if run_fn is None:
            # Module exists but has no run() entrypoint yet — skip.
            continue

        try:
            rc = run_fn(repo_root=repo_root)
        except Exception as exc:  # noqa: BLE001
            print(
                f"ERROR: step '{step_name}' raised an unhandled exception: {exc}",
                file=sys.stderr,
            )
            return 1

        if rc != 0:
            print(
                f"ERROR: step '{step_name}' exited with non-zero code {rc}",
                file=sys.stderr,
            )
            return 1

    print("OK: steady-state pass converged")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point for ``python -m dso_reconciler``."""
    return run_pass()


if __name__ == "__main__":
    sys.exit(main())
