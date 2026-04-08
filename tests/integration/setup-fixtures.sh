#!/usr/bin/env bash
# tests/integration/setup-fixtures.sh
# Ensures integration test fixture projects are available.
# Uses synthetic fixtures committed to the repo — no network required.
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
