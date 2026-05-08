#!/usr/bin/env bash
set -uo pipefail

# pre-commit-compliance-verifier.sh
# Verifies that required workflow artifacts exist before allowing a commit.
# Feature-flagged via hooks.compliance_verifier.enabled in dso-config.conf.

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SCRIPT_DIR/lib/deps.sh"

# Feature flag — tests use DSO_COMPLIANCE_VERIFIER_ENABLED env var to override config
_enabled="${DSO_COMPLIANCE_VERIFIER_ENABLED:-}"

# If env var not set, read from dso-config.conf
if [[ -z "$_enabled" ]]; then
    _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_REPO_ROOT" ]]; then
        _enabled=$(grep -m1 '^hooks\.compliance_verifier\.enabled=' "$_REPO_ROOT/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2-)
    fi
fi

# If disabled or absent, exit 0 (no-op)
if [[ "$_enabled" != "true" ]]; then
    exit 0
fi

# First-run guard: if override dir explicitly set but doesn't exist → warn and exit 0 (not a blocker)
if [[ -n "${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-}" && ! -d "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}" ]]; then
    echo "WARNING: pre-commit-compliance-verifier: artifacts dir not found (${WORKFLOW_PLUGIN_ARTIFACTS_DIR}) — first run, skipping verification" >&2
    exit 0
fi

# Resolve artifacts dir (WORKFLOW_PLUGIN_ARTIFACTS_DIR override handled by get_artifacts_dir())
# get_artifacts_dir() derives path from REPO_ROOT — each worktree gets its own isolated ARTIFACTS_DIR
ARTIFACTS_DIR=$(get_artifacts_dir)

# First-run guard: ARTIFACTS_DIR absent → warn and exit 0 (not a blocker)
if [[ ! -d "$ARTIFACTS_DIR" ]]; then
    echo "WARNING: pre-commit-compliance-verifier: artifacts dir not found ($ARTIFACTS_DIR) — first run, skipping verification" >&2
    exit 0
fi

# Check all required workflow steps
_required_steps=(test format lint classifier-dispatch reviewer-record)
_failed=0
for _step in "${_required_steps[@]}"; do
    _result="$ARTIFACTS_DIR/${_step}.result"
    _timeout="$ARTIFACTS_DIR/${_step}.timeout"
    if [[ -f "$_result" ]]; then
        : # step passed
    elif [[ -f "$_timeout" ]]; then
        echo "ERROR: pre-commit-compliance-verifier: step '${_step}' timed out (exit 144) — commit blocked" >&2
        _failed=1
    else
        echo "ERROR: pre-commit-compliance-verifier: required artifact '${_step}.result' not found — run commit-step before committing" >&2
        _failed=1
    fi
done
exit $_failed
