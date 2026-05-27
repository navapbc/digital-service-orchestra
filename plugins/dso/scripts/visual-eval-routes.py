#!/usr/bin/env python3
"""Route extraction from .ui-discovery-cache/route-map.json.

Usage:
  visual-eval-routes.py --route-map PATH          # prints routes one per line
  visual-eval-routes.py --route-map PATH --count   # prints integer count only
"""

from __future__ import annotations

import argparse
import json
import sys


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract routes from route-map.json")
    parser.add_argument(
        "--route-map", type=str, required=True, help="Path to route-map.json"
    )
    parser.add_argument("--count", action="store_true", help="Print route count only")
    args = parser.parse_args()

    try:
        with open(args.route_map) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"Error reading route map: {e}", file=sys.stderr)
        sys.exit(1)

    routes = data if isinstance(data, list) else data.get("routes", [])
    paths = []
    for r in routes:
        path = r.get("path", r) if isinstance(r, dict) else r
        if path:
            paths.append(str(path))

    if args.count:
        print(len(paths))
    else:
        for p in paths:
            print(p)


if __name__ == "__main__":
    main()
