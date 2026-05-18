#!/usr/bin/env bash
# review-workflow.sh — thin shell shim for the dso_ci_review.local_workflow module.
#
# Resolves the plugin root, sets PYTHONPATH, and delegates to the Python
# local_workflow entry point. All arguments are forwarded; exit code is
# propagated verbatim.
#
# Usage:
#   review-workflow.sh [args...]

set -euo pipefail

# Resolve plugin root: the directory containing this script's parent (scripts/).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"

export PYTHONPATH="${_PLUGIN_ROOT}/scripts${PYTHONPATH:+:${PYTHONPATH}}"

exec python3 -m dso_ci_review.local_workflow "$@"
