#!/usr/bin/env python3
"""capture_ci_review_post_migration.py — Post-migration duration capture script.

Runs the dso_ci_review.runner module in dry-run mode N times and records
timing percentiles (p50, p95) to tests/fixtures/ci-review-post-migration.json.

Usage:
    python3 scripts/capture_ci_review_post_migration.py [--run-count N] [--output PATH]
    # Run from the plugin scripts directory so PYTHONPATH resolves dso_ci_review

Environment variables:
    CI_REVIEW_POST_MIGRATION_ITERATIONS   Number of dry-run iterations (default: 20)
    CI_REVIEW_POST_MIGRATION_OUTPUT       Output JSON path
                                          (default: tests/fixtures/ci-review-post-migration.json)

Exit codes:
    0  Metrics captured successfully
    1  Error
"""

from __future__ import annotations

import argparse
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

DEFAULT_OUTPUT = REPO_ROOT / "tests" / "fixtures" / "ci-review-post-migration.json"
DEFAULT_ITERATIONS = 20


def _run_one(diff_path: Path) -> float:
    """Run runner.py in dry-run mode and return elapsed seconds."""
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
    elapsed_s = time.perf_counter() - start

    if result.returncode != 0:
        raise RuntimeError(
            f"runner exited {result.returncode}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return elapsed_s


def main(run_count: int | None = None, output: Path | None = None) -> int:
    iterations = run_count or int(
        os.environ.get("CI_REVIEW_POST_MIGRATION_ITERATIONS", DEFAULT_ITERATIONS)
    )
    output_path = output or Path(
        os.environ.get("CI_REVIEW_POST_MIGRATION_OUTPUT", DEFAULT_OUTPUT)
    )

    if not FIXTURE_DIFF.exists():
        print(f"ERROR: fixture diff not found: {FIXTURE_DIFF}", file=sys.stderr)
        return 1

    print(
        f"Capturing CI review post-migration metrics ({iterations} dry-run iterations)..."
    )
    durations_s: list[float] = []

    for i in range(1, iterations + 1):
        try:
            s = _run_one(FIXTURE_DIFF)
            durations_s.append(s)
            print(f"  [{i:>3}/{iterations}] {s * 1000:.1f} ms")
        except Exception as exc:  # noqa: BLE001
            print(f"  [{i:>3}/{iterations}] ERROR: {exc}", file=sys.stderr)
            return 1

    durations_s.sort()
    p50 = statistics.median(durations_s)
    # Use quantiles for p95: statistics.quantiles returns n-1 cut points;
    # n=20 gives cut points at 5%,10%,...,95%,100% — index 18 is the 95th percentile.
    p95 = (
        statistics.quantiles(durations_s, n=20)[18]
        if len(durations_s) >= 2
        else durations_s[0]
    )

    artifact = {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "run_count": iterations,
        "p50_seconds": round(p50, 3),
        "p95_seconds": round(p95, 3),
        "min_seconds": round(min(durations_s), 3),
        "max_seconds": round(max(durations_s), 3),
        "python_version": sys.version.split()[0],
        "mode": "dry_run",
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(artifact, indent=2) + "\n", encoding="utf-8")

    print("\nPost-migration metrics captured:")
    print(f"  p50: {p50 * 1000:.1f} ms")
    print(f"  p95: {p95 * 1000:.1f} ms")
    print(f"  Written to: {output_path}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Capture post-migration CI review duration metrics."
    )
    parser.add_argument(
        "--run-count",
        type=int,
        default=None,
        help="Number of dry-run iterations (default: 20 or CI_REVIEW_POST_MIGRATION_ITERATIONS)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output JSON path (default: tests/fixtures/ci-review-post-migration.json)",
    )
    args = parser.parse_args()
    sys.exit(main(run_count=args.run_count, output=args.output))
