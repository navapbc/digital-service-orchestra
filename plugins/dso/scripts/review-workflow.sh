#!/usr/bin/env bash
# DEPRECATED: review-workflow.sh is deprecated. The local review path is
# REVIEW-WORKFLOW.md executed inline by the LLM orchestrator (via
# commit-workflow-validation.md Step 6). This script delegates to
# local_workflow.py which lacks tier classification, overlays, deep-tier
# dispatch, and defense handling that REVIEW-WORKFLOW.md provides.
#
# This shim is retained for backward compatibility with any test or script
# that references it directly. New code should not call this script.
#
# Original purpose: thin shell shim for dso_ci_review.local_workflow module.

set -euo pipefail

echo "WARNING: review-workflow.sh is deprecated — use REVIEW-WORKFLOW.md via the LLM orchestrator" >&2

# Resolve plugin root: the directory containing this script's parent (scripts/).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "${_SCRIPT_DIR}/.." && pwd)"

export PYTHONPATH="${_PLUGIN_ROOT}/scripts${PYTHONPATH:+:${PYTHONPATH}}"

exec python3 -m dso_ci_review.local_workflow "$@"
