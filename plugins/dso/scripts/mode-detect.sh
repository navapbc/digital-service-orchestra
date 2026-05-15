#!/usr/bin/env bash
set -euo pipefail
# mode-detect.sh — Reads dso.workflow from project config via read-config.sh.
# Outputs: ci-pr | local
# Exit: propagates read-config.sh exit code (non-zero if config missing)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow test override via DSO_CONFIG_PATH
if [[ -n "${DSO_CONFIG_PATH:-}" ]]; then
    export WORKFLOW_CONFIG_FILE="$DSO_CONFIG_PATH"
fi

exec bash "$SCRIPT_DIR/read-config.sh" dso.workflow
