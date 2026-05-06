#!/usr/bin/env bash
# ci-llm-review-runner.sh — shim for dso_ci_review.runner Python module.
# Resolves _PLUGIN_ROOT, passes overlay flags as env vars, then execs python3 -m dso_ci_review.runner.
set -euo pipefail

_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Locate python3 (prefer plugin venv if present)
_VENV="$_PLUGIN_ROOT/scripts/.venv/bin/python3"
if [[ -x "$_VENV" ]]; then
    _PYTHON="$_VENV"
else
    _PYTHON="${PYTHON:-python3}"
fi

# Set plugin root for Python module resolution
export PYTHONPATH="${_PLUGIN_ROOT}/scripts${PYTHONPATH:+:$PYTHONPATH}"

# Pass overlay flags as environment variables (consumed by runner.py)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --overlay-security)     export DSO_CI_REVIEW_OVERLAY_SECURITY=1; shift ;;
        --overlay-performance)  export DSO_CI_REVIEW_OVERLAY_PERFORMANCE=1; shift ;;
        --overlay-test-quality) export DSO_CI_REVIEW_OVERLAY_TEST_QUALITY=1; shift ;;
        *) echo "ERROR: Unknown flag: $1" >&2; exit 1 ;;
    esac
done

exec "$_PYTHON" -m dso_ci_review.runner
