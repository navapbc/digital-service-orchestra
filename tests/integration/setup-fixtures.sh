#!/usr/bin/env bash
# tests/integration/setup-fixtures.sh
# Ensures integration test fixture projects are available.
#
# Fixtures are committed to the repo and model the structure and scale of real-world
# open-source Python and TypeScript utility libraries. The Python fixture provides
# 15+ callers of calculator.add() across 8 source files, representative of a
# medium-sized utility library. The TypeScript fixture mirrors a similar structure.
#
# Env var override (for testing):
#   FIXTURES_OVERRIDE — use this path as FIXTURES_DIR instead of the default
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${FIXTURES_OVERRIDE:-$SCRIPT_DIR/fixtures}"
mkdir -p "$FIXTURES_DIR"

# Synthetic Python project
if [[ ! -f "$FIXTURES_DIR/python-project/pyproject.toml" ]]; then
    echo "ERROR: python-project fixture missing — run from repo root after cloning" >&2
    exit 1
fi

# Synthetic TypeScript project
if [[ ! -f "$FIXTURES_DIR/typescript-project/tsconfig.json" ]]; then
    echo "ERROR: typescript-project fixture missing — run from repo root after cloning" >&2
    exit 1
fi

echo "Fixtures ready at $FIXTURES_DIR"
