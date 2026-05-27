#!/usr/bin/env python3
"""CLI wrapper around visual_eval_api.evaluate_screenshot().

Usage:
  visual-eval-run.py --screenshot PATH [--manifest PATH] [--params PATH] [--schema PATH]
  visual-eval-run.py --summarize DIR

Outputs JSON to stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run visual evaluation on a screenshot"
    )
    parser.add_argument("--screenshot", type=Path, help="Path to screenshot PNG")
    parser.add_argument(
        "--manifest", type=Path, default=None, help="Path to design manifest JSON"
    )
    _default_params = (
        Path(os.environ.get("CLAUDE_PLUGIN_ROOT", Path(__file__).parent.parent))
        / "config"
        / "visual-evaluator-params.yaml"
    )
    parser.add_argument(
        "--params",
        type=Path,
        default=_default_params,
    )
    parser.add_argument("--schema", type=Path, default=None)
    parser.add_argument(
        "--summarize",
        type=Path,
        default=None,
        help="Summarize results from a directory of JSON files",
    )
    args = parser.parse_args()

    if args.summarize:
        summarize(args.summarize)
        return

    if not args.screenshot:
        parser.error("--screenshot is required unless --summarize is used")

    # Import here so argparse errors don't require the module
    sys.path.insert(0, str(Path(__file__).parent))
    from visual_eval_api import evaluate_screenshot

    design_manifest = None
    if args.manifest and args.manifest.exists():
        with open(args.manifest) as f:
            design_manifest = json.load(f)

    result = evaluate_screenshot(
        screenshot_path=args.screenshot,
        design_manifest=design_manifest,
        params_path=args.params,
        schema_path=args.schema,
    )
    json.dump(result, sys.stdout, indent=2)
    print()


def summarize(results_dir: Path) -> None:
    """Compute summary stats from a directory of evaluation JSON files."""
    route_count = 0
    finding_count = 0
    intent_match_sum = 0
    intent_match_count = 0

    for f in sorted(results_dir.glob("*.json")):
        try:
            with open(f) as fh:
                data = json.load(fh)
        except (json.JSONDecodeError, OSError):
            continue

        if "visual_eval_inapplicable" in data:
            continue

        route_count += 1
        findings = data.get("findings", [])
        finding_count += len(findings)
        scores = data.get("scores", {})
        if "intent_match" in scores:
            intent_match_sum += scores["intent_match"]
            intent_match_count += 1

    mean_im = (
        round(intent_match_sum / intent_match_count, 1) if intent_match_count > 0 else 0
    )
    summary = {
        "routes": route_count,
        "findings": finding_count,
        "mean_intent_match": mean_im,
    }
    json.dump(summary, sys.stdout)
    print()


if __name__ == "__main__":
    main()
