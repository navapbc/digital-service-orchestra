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

# Override path: if override.token exists with a matching diff_hash, allow this commit
_token_file="$ARTIFACTS_DIR/override.token"
if [[ -f "$_token_file" ]]; then
    _current_hash=$(git diff --cached 2>/dev/null | sha256sum | cut -c1-12)
    _token_hash=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    print(data.get('diff_hash', ''))
except Exception as e:
    print('WARNING: pre-commit-compliance-verifier: override.token is malformed (' + str(e) + ') — ignoring token', file=sys.stderr)
    print('')
" "$_token_file" || echo "")
    if [[ -n "$_token_hash" && "$_token_hash" == "$_current_hash" ]]; then
        exit 0
    fi
fi

# Check all required workflow steps
_required_steps=(test format lint classifier-dispatch reviewer-record)
_failed=0
for _step in "${_required_steps[@]}"; do
    _result="$ARTIFACTS_DIR/${_step}.result"
    _timeout="$ARTIFACTS_DIR/${_step}.timeout"
    _skipped="$ARTIFACTS_DIR/${_step}.skipped"
    if [[ -f "$_result" ]]; then
        : # step passed
    elif [[ -f "$_skipped" ]]; then
        : # step explicitly skipped — accepted in place of .result
    elif [[ -f "$_timeout" ]]; then
        echo "ERROR: pre-commit-compliance-verifier: step '${_step}' timed out (exit 144) — commit blocked" >&2
        _failed=1
    else
        echo "ERROR: pre-commit-compliance-verifier: required artifact '${_step}.result' not found — run commit-step before committing" >&2
        _failed=1
    fi
done
# Overlay verification: check overlay-specific findings files
_classifier_result="$ARTIFACTS_DIR/classifier-dispatch.result"
if [[ -f "$_classifier_result" ]]; then
    _registry="${OVERLAY_REGISTRY_PATH:-$_SCRIPT_DIR/../docs/contracts/overlay-registry.json}"
    _CLASSIFIER_RESULT="$_classifier_result" \
    _REGISTRY="$_registry" \
    _ARTIFACTS_DIR="$ARTIFACTS_DIR" \
    python3 -c "
import json, re, sys, os

result_file = os.environ['_CLASSIFIER_RESULT']
registry_file = os.environ['_REGISTRY']
artifacts_dir = os.environ['_ARTIFACTS_DIR']

def extract_overlays(raw_content):
    # Try standard JSON parse first (properly-escaped stdout field)
    try:
        result = json.loads(raw_content)
        stdout_val = result.get('stdout', '')
        if stdout_val:
            try:
                stdout_obj = json.loads(stdout_val)
                return stdout_obj.get('overlays') or []
            except (json.JSONDecodeError, ValueError):
                pass
        return []
    except (json.JSONDecodeError, ValueError):
        pass
    # Fallback: regex extraction from raw content.
    # Handles inline-embedded JSON where stdout value is not properly escaped.
    pat = r'\"overlays\"\s*:\s*(\[[^\]]*\])'
    m = re.search(pat, raw_content)
    if m:
        try:
            return json.loads(m.group(1))
        except (json.JSONDecodeError, ValueError):
            pass
    return []

try:
    with open(result_file) as f:
        raw_content = f.read()
    overlays = extract_overlays(raw_content)
    if not overlays:
        sys.exit(0)
    with open(registry_file) as f:
        registry = json.load(f)
    failed = 0
    for overlay in overlays:
        findings_file = registry.get(overlay)
        if findings_file is None:
            print('WARNING: pre-commit-compliance-verifier: overlay ' + overlay + ' not in registry, skipping', file=sys.stderr)
            continue
        findings_path = os.path.join(artifacts_dir, findings_file)
        if not os.path.isfile(findings_path):
            print('ERROR: pre-commit-compliance-verifier: overlay ' + overlay + ' findings file ' + findings_file + ' not found, commit blocked', file=sys.stderr)
            failed = 1
    sys.exit(failed)
except Exception as e:
    print('ERROR: pre-commit-compliance-verifier: overlay check failed: ' + str(e), file=sys.stderr)
    sys.exit(1)
"
    _overlay_exit=$?
    if [[ $_overlay_exit -ne 0 ]]; then
        _failed=1
    fi
fi

exit $_failed
