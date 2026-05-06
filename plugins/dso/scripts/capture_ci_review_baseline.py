#!/usr/bin/env python3
"""capture_ci_review_baseline.py — Pre-migration duration baseline script.

Runs the dso_ci_review.runner module in dry-run mode N times and records
timing percentiles (p50, p95) to tests/fixtures/ci-review-baseline.json.

Usage:
    python3 scripts/capture_ci_review_baseline.py
    # Run from the plugin scripts directory so PYTHONPATH resolves dso_ci_review

Environment variables:
    CI_REVIEW_BASELINE_ITERATIONS   Number of dry-run iterations (default: 20)
    CI_REVIEW_BASELINE_OUTPUT       Output JSON path
                                    (default: tests/fixtures/ci-review-baseline.json)

Exit codes:
    0  Baseline captured successfully
    1  Error
"""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).parents[3]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
FIXTURE_DIFF = (
    REPO_ROOT / "tests" / "fixtures" / "ci-review-corpus" / "fixture-diff.txt"
)

DEFAULT_OUTPUT = REPO_ROOT / "tests" / "fixtures" / "ci-review-baseline.json"
DEFAULT_ITERATIONS = 20


def _run_one(diff_path: Path) -> float:
    """Run runner.py in dry-run mode and return elapsed milliseconds."""
    env = {
        **os.environ,
        "PYTHONPATH": str(SCRIPTS_DIR),
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_path),
        "DSO_CI_REVIEW_DRY_RUN": "1",
    }
    start = time.perf_counter()
    result = subprocess.run(
        [sys.executable, "-m", "dso_ci_review.runner"],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    elapsed_ms = (time.perf_counter() - start) * 1000

    if result.returncode != 0:
        raise RuntimeError(
            f"runner exited {result.returncode}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return elapsed_ms


def main() -> int:
    iterations = int(
        os.environ.get("CI_REVIEW_BASELINE_ITERATIONS", DEFAULT_ITERATIONS)
    )
    output_path = Path(os.environ.get("CI_REVIEW_BASELINE_OUTPUT", DEFAULT_OUTPUT))

    if not FIXTURE_DIFF.exists():
        print(f"ERROR: fixture diff not found: {FIXTURE_DIFF}", file=sys.stderr)
        return 1

    print(f"Capturing CI review baseline ({iterations} dry-run iterations)...")
    durations_ms: list[float] = []

    for i in range(1, iterations + 1):
        try:
            ms = _run_one(FIXTURE_DIFF)
            durations_ms.append(ms)
            print(f"  [{i:>3}/{iterations}] {ms:.1f} ms")
        except Exception as exc:  # noqa: BLE001
            print(f"  [{i:>3}/{iterations}] ERROR: {exc}", file=sys.stderr)
            return 1

    durations_ms.sort()
    p50 = statistics.median(durations_ms)
    # Use quantiles for p95: statistics.quantiles returns n-1 cut points;
    # n=20 gives cut points at 5%,10%,...,95%,100% — index 18 is the 95th percentile.
    p95 = (
        statistics.quantiles(durations_ms, n=20)[18]
        if len(durations_ms) >= 2
        else durations_ms[0]
    )

    baseline = {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "iterations": iterations,
        "p50_ms": round(p50, 2),
        "p95_ms": round(p95, 2),
        "min_ms": round(min(durations_ms), 2),
        "max_ms": round(max(durations_ms), 2),
        "python_version": sys.version.split()[0],
        "mode": "dry_run",
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")

    print("\nBaseline captured:")
    print(f"  p50: {p50:.1f} ms")
    print(f"  p95: {p95:.1f} ms")
    print(f"  Written to: {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
