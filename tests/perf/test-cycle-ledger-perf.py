"""cycle_ledger hot-path microbenchmark: v1.2.0 vs v1.1.0 baseline.

Measures the two hot-path operations:
  - append_cycle        (write path)
  - reconstruct_from_pr_comments (read path)

Compares v1.1.0-only fixtures against v1.2.0-only fixtures (pr_number field
in both the marker grammar and the stored entry).

Exit code:
  0 — both operations are within the 10% regression threshold
  1 — one or both operations regressed more than 10%

Usage:
  python3 tests/perf/test-cycle-ledger-perf.py [--iterations=N] [--threshold=PCT]

GREEN test (task 4b23-1b50-b5a2-4b03): asserts <10% throughput regression on
both hot paths after v1.2.0 lands. The baseline numbers shipped in
tests/perf/cycle_ledger_baseline.json are the authoritative reference.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import statistics
import sys
import tempfile
import timeit
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

# ── Path setup ────────────────────────────────────────────────────────────────
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from dso_ci_review.cycle_ledger import (  # noqa: E402
    append_cycle,
    reconstruct_from_pr_comments,
    write_ledger,
)

# ── Fixture builders ──────────────────────────────────────────────────────────
_BASELINE_PATH = pathlib.Path(__file__).parent / "cycle_ledger_baseline.json"
_REGRESSION_THRESHOLD = 0.10  # 10% maximum allowed regression


def _build_v11_comments(num_entries: int = 1000) -> str:
    """Build a fake gh API JSON response with ``num_entries`` v1.1.0 markers.

    Spreads entries across comments in chunks of 20 to mirror realistic PR
    comment threading (many markers per comment body).
    """
    markers: list[str] = []
    for i in range(num_entries):
        sha = f"abc{i:06x}{'0' * 34}"[:40]
        marker = (
            f"DSO-Review-Cycle: {i + 1}"
            f" commit_sha={sha}"
            f" findings_hash=h{i}"
            f' tuples=[["x.py","{i}-{i + 5}","correctness"]]'
        )
        markers.append(marker)

    chunk = 20
    comments = [
        {"body": "\n".join(markers[j : j + chunk])}
        for j in range(0, num_entries, chunk)
    ]
    return json.dumps(comments)


def _build_v12_comments(num_entries: int = 1000, pr_number: int = 42) -> str:
    """Build a fake gh API JSON response with ``num_entries`` v1.2.0 markers.

    v1.2.0 markers include an explicit ``pr_number=`` field before commit_sha.
    """
    markers: list[str] = []
    for i in range(num_entries):
        sha = f"abc{i:06x}{'0' * 34}"[:40]
        marker = (
            f"DSO-Review-Cycle: {i + 1}"
            f" pr_number={pr_number}"
            f" commit_sha={sha}"
            f" findings_hash=h{i}"
            f' tuples=[["x.py","{i}-{i + 5}","correctness"]]'
        )
        markers.append(marker)

    chunk = 20
    comments = [
        {"body": "\n".join(markers[j : j + chunk])}
        for j in range(0, num_entries, chunk)
    ]
    return json.dumps(comments)


# ── Core measurement helpers ──────────────────────────────────────────────────


def _measure_append_cycle(
    n_batches: int = 100,
    batch_size: int = 10,
) -> dict:
    """Measure append_cycle (write path) using a temp ledger file.

    Each batch resets the ledger to an empty state so we measure a single
    append, not the accumulation of N entries.

    Returns dict with mean_s, median_s, stdev_s, ops_per_s, iterations.
    """
    timings: list[float] = []
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "ledger.json")

        for _ in range(n_batches):
            write_ledger(
                path,
                {"schema_version": "1.1.0", "epic_id": "e1", "cycles": []},
            )
            t = timeit.timeit(
                lambda: append_cycle(
                    path,
                    cycle_num=1,
                    findings_tuples=[
                        ["x.py", "1-10", "correctness"],
                        ["y.py", "20-30", "style"],
                    ],
                    commit_sha="abc" + "0" * 37,
                    findings_hash="h1abc123",
                ),
                number=batch_size,
            )
            timings.append(t / batch_size)

    iterations = n_batches * batch_size
    mean_s = statistics.mean(timings)
    return {
        "mean_s": mean_s,
        "median_s": statistics.median(timings),
        "stdev_s": statistics.stdev(timings) if len(timings) > 1 else 0.0,
        "ops_per_s": 1.0 / mean_s if mean_s > 0 else float("inf"),
        "mean_ms": mean_s * 1000,
        "median_ms": statistics.median(timings) * 1000,
        "iterations": iterations,
    }


def _measure_reconstruct(
    fixture_json: str,
    n_batches: int = 100,
    batch_size: int = 10,
) -> dict:
    """Measure reconstruct_from_pr_comments (read path) with a mocked gh call.

    ``fixture_json`` is the pre-built fake gh API response string.
    Returns dict with mean_s, median_s, stdev_s, ops_per_s, iterations.
    """
    timings: list[float] = []
    mock_result = MagicMock()
    mock_result.stdout = fixture_json
    mock_result.returncode = 0

    with patch("subprocess.run", return_value=mock_result):
        for _ in range(n_batches):
            t = timeit.timeit(
                lambda: reconstruct_from_pr_comments(42, "owner/repo"),
                number=batch_size,
            )
            timings.append(t / batch_size)

    iterations = n_batches * batch_size
    mean_s = statistics.mean(timings)
    return {
        "mean_s": mean_s,
        "median_s": statistics.median(timings),
        "stdev_s": statistics.stdev(timings) if len(timings) > 1 else 0.0,
        "ops_per_s": 1.0 / mean_s if mean_s > 0 else float("inf"),
        "mean_ms": mean_s * 1000,
        "median_ms": statistics.median(timings) * 1000,
        "iterations": iterations,
    }


# ── Regression assertion ──────────────────────────────────────────────────────


def _check_regression(
    op_name: str,
    baseline_mean_s: float,
    current_mean_s: float,
    threshold: float = _REGRESSION_THRESHOLD,
) -> bool:
    """Return True if current is within threshold of baseline (no regression).

    Regression = current_mean_s > baseline_mean_s * (1 + threshold).
    """
    allowed = baseline_mean_s * (1.0 + threshold)
    delta_pct = (current_mean_s - baseline_mean_s) / baseline_mean_s * 100.0
    verdict = "PASS" if current_mean_s <= allowed else "FAIL"
    sign = "+" if delta_pct >= 0 else ""
    print(
        f"  [{verdict}] {op_name}: "
        f"baseline={baseline_mean_s * 1000:.3f}ms "
        f"current={current_mean_s * 1000:.3f}ms "
        f"delta={sign}{delta_pct:.1f}% "
        f"(threshold=<+{threshold * 100:.0f}%)"
    )
    return verdict == "PASS"


# ── Individual test functions (named for RED marker extraction) ───────────────


def test_append_cycle_no_regression(
    baseline: dict,
    n_batches: int,
    batch_size: int,
    threshold: float,
) -> tuple[bool, dict]:
    """Benchmark append_cycle and assert no >threshold regression vs baseline.

    Fixture: empty ledger, single append per measurement (v1.1.0 style).
    """
    print("\n--- append_cycle (write path) ---")
    result = _measure_append_cycle(n_batches=n_batches, batch_size=batch_size)
    print(
        f"  measured: mean={result['mean_ms']:.3f}ms "
        f"median={result['median_ms']:.3f}ms "
        f"ops/s={result['ops_per_s']:.1f}"
    )
    baseline_mean_s = baseline.get("append_cycle", {}).get("mean_s", result["mean_s"])
    ok = _check_regression("append_cycle", baseline_mean_s, result["mean_s"], threshold)
    return ok, result


def test_reconstruct_v11_no_regression(
    baseline: dict,
    n_batches: int,
    batch_size: int,
    threshold: float,
    num_entries: int,
) -> tuple[bool, dict]:
    """Benchmark reconstruct_from_pr_comments with a pure v1.1.0 fixture.

    Fixture: 1000 v1.1.0 markers (no pr_number field).
    """
    print("\n--- reconstruct_from_pr_comments (v1.1.0 fixture, 1000 entries) ---")
    fixture = _build_v11_comments(num_entries)
    result = _measure_reconstruct(fixture, n_batches=n_batches, batch_size=batch_size)
    print(
        f"  measured: mean={result['mean_ms']:.3f}ms "
        f"median={result['median_ms']:.3f}ms "
        f"ops/s={result['ops_per_s']:.1f}"
    )
    baseline_mean_s = baseline.get("reconstruct_v11", {}).get(
        "mean_s", result["mean_s"]
    )
    ok = _check_regression(
        "reconstruct_v11", baseline_mean_s, result["mean_s"], threshold
    )
    return ok, result


def test_reconstruct_v12_no_regression(
    baseline: dict,
    n_batches: int,
    batch_size: int,
    threshold: float,
    num_entries: int,
) -> tuple[bool, dict]:
    """Benchmark reconstruct_from_pr_comments with a pure v1.2.0 fixture.

    Fixture: 1000 v1.2.0 markers (with explicit pr_number= field).
    The v1.2.0 fixture uses the extended grammar. When cycle_ledger v1.2.0 is
    implemented, this path exercises the new _MARKER_RE_V12 branch; before
    implementation, the markers fall through to the legacy matcher (slower path
    with no pr_number parsed — benchmark confirms grammar addition adds <10%).
    """
    print("\n--- reconstruct_from_pr_comments (v1.2.0 fixture, 1000 entries) ---")
    fixture = _build_v12_comments(num_entries, pr_number=42)
    result = _measure_reconstruct(fixture, n_batches=n_batches, batch_size=batch_size)
    print(
        f"  measured: mean={result['mean_ms']:.3f}ms "
        f"median={result['median_ms']:.3f}ms "
        f"ops/s={result['ops_per_s']:.1f}"
    )
    # Compare against v1.1.0 baseline — v1.2.0 must not be >threshold slower
    baseline_mean_s = baseline.get("reconstruct_v11", {}).get(
        "mean_s", result["mean_s"]
    )
    ok = _check_regression(
        "reconstruct_v12_vs_v11_baseline",
        baseline_mean_s,
        result["mean_s"],
        threshold,
    )
    return ok, result


# ── Main ──────────────────────────────────────────────────────────────────────


def _load_or_seed_baseline(
    path: pathlib.Path,
    n_batches: int,
    batch_size: int,
    num_entries: int,
) -> dict:
    """Load baseline JSON if it exists; seed it from a fresh measurement if not."""
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            print(f"Loaded baseline from {path}")
            return data
        except (json.JSONDecodeError, OSError) as exc:
            print(
                f"WARNING: could not load baseline ({exc}); re-seeding", file=sys.stderr
            )

    print(f"Seeding baseline (first run) — writing {path}")
    print("  Running append_cycle baseline measurement...")
    append_result = _measure_append_cycle(n_batches=n_batches, batch_size=batch_size)
    print("  Running reconstruct_v11 baseline measurement...")
    v11_fixture = _build_v11_comments(num_entries)
    reconstruct_result = _measure_reconstruct(
        v11_fixture, n_batches=n_batches, batch_size=batch_size
    )

    baseline = {
        "captured_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "platform": sys.platform,
        "python_version": sys.version.split()[0],
        "iterations_per_op": n_batches * batch_size,
        "fixture_entries": num_entries,
        "regression_threshold_pct": _REGRESSION_THRESHOLD * 100,
        "append_cycle": {
            "mean_s": append_result["mean_s"],
            "median_s": append_result["median_s"],
            "mean_ms": append_result["mean_ms"],
            "median_ms": append_result["median_ms"],
            "ops_per_s": append_result["ops_per_s"],
        },
        "reconstruct_v11": {
            "mean_s": reconstruct_result["mean_s"],
            "median_s": reconstruct_result["median_s"],
            "mean_ms": reconstruct_result["mean_ms"],
            "median_ms": reconstruct_result["median_ms"],
            "ops_per_s": reconstruct_result["ops_per_s"],
        },
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(baseline, indent=2), encoding="utf-8")
    return baseline


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="cycle_ledger v1.2.0 vs v1.1.0 performance benchmark"
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=1000,
        help="Total per-op iterations (split across 100 batches; default: 1000)",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=10.0,
        help="Maximum regression percentage allowed (default: 10)",
    )
    parser.add_argument(
        "--entries",
        type=int,
        default=1000,
        help="Number of cycle markers in reconstruct fixture (default: 1000)",
    )
    parser.add_argument(
        "--seed-baseline",
        action="store_true",
        help="Force re-seed the baseline file from current measurements",
    )
    args = parser.parse_args(argv)

    threshold = args.threshold / 100.0
    batch_size = 10
    n_batches = max(1, args.iterations // batch_size)
    num_entries = args.entries

    print("=" * 60)
    print("cycle_ledger hot-path benchmark: v1.2.0 vs v1.1.0 baseline")
    print(f"iterations/op: {n_batches * batch_size}  fixture_entries: {num_entries}")
    print(f"threshold: <+{args.threshold:.0f}% regression")
    print("=" * 60)

    # Load or seed baseline
    baseline_path = _BASELINE_PATH
    if args.seed_baseline and baseline_path.exists():
        baseline_path.unlink()

    baseline = _load_or_seed_baseline(baseline_path, n_batches, batch_size, num_entries)

    print("\n[Running benchmarks]")
    all_pass = True
    results: dict = {}

    ok1, r1 = test_append_cycle_no_regression(
        baseline, n_batches, batch_size, threshold
    )
    all_pass = all_pass and ok1
    results["append_cycle"] = r1

    ok2, r2 = test_reconstruct_v11_no_regression(
        baseline, n_batches, batch_size, threshold, num_entries
    )
    all_pass = all_pass and ok2
    results["reconstruct_v11"] = r2

    ok3, r3 = test_reconstruct_v12_no_regression(
        baseline, n_batches, batch_size, threshold, num_entries
    )
    all_pass = all_pass and ok3
    results["reconstruct_v12"] = r3

    print()
    print("=" * 60)
    if all_pass:
        print("BENCHMARK RESULT: PASS — no >10% regression detected")
    else:
        print("BENCHMARK RESULT: FAIL — one or more operations regressed >10%")
    print("=" * 60)

    # Emit machine-readable summary to stdout for CI consumption
    summary = {
        "verdict": "PASS" if all_pass else "FAIL",
        "threshold_pct": args.threshold,
        "ops": {
            "append_cycle": {
                "mean_ms": results["append_cycle"]["mean_ms"],
                "ops_per_s": results["append_cycle"]["ops_per_s"],
                "baseline_mean_ms": baseline.get("append_cycle", {}).get("mean_ms", 0),
            },
            "reconstruct_v11": {
                "mean_ms": results["reconstruct_v11"]["mean_ms"],
                "ops_per_s": results["reconstruct_v11"]["ops_per_s"],
                "baseline_mean_ms": baseline.get("reconstruct_v11", {}).get(
                    "mean_ms", 0
                ),
            },
            "reconstruct_v12": {
                "mean_ms": results["reconstruct_v12"]["mean_ms"],
                "ops_per_s": results["reconstruct_v12"]["ops_per_s"],
                "baseline_mean_ms": baseline.get("reconstruct_v11", {}).get(
                    "mean_ms", 0
                ),
            },
        },
    }
    print("\nJSON_SUMMARY:", json.dumps(summary))

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
