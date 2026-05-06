#!/usr/bin/env bash
set -euo pipefail
# scripts/write-reviewer-findings.sh
#
# Validate-then-write gate for reviewer-findings.json.
#
# Validates the JSON schema BEFORE writing to the canonical findings file.
# Only outputs the SHA-256 hash on success — making it mechanically impossible
# to obtain a valid REVIEWER_HASH without passing schema validation.
#
# Usage:
#   cat findings.json | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh"  # shim-exempt: usage example in script header
#   cat findings.json | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh" --output /path/to/slot.json  # shim-exempt: usage example in script header
#
#   Or with a heredoc:
#   cat <<'EOF' | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh"  # shim-exempt: usage example in script header
#   { "findings": [...], "summary": "..." }
#   EOF
#
# Options:
#   --output <path>  Write findings to <path> instead of the canonical reviewer-findings.json.
#                    Used by deep tier parallel sonnet agents to write to slot-specific paths.
#   FINDINGS_OUTPUT env var is also accepted as a fallback (--output takes precedence).
#
# Exit codes:
#   0 = valid; findings written; SHA-256 hash printed to stdout
#   1 = schema validation failed; errors printed to stderr; nothing written
#   2 = usage error (no stdin, missing dependency)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use get_artifacts_dir() for config-driven artifact directory
source "$PLUGIN_ROOT/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

# Parse flags
_OUTPUT_PATH=""
_REVIEW_TIER=""
_SELECTED_TIER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) _OUTPUT_PATH="${2:?--output requires a path argument}"; shift 2 ;;
        --review-tier)
            _REVIEW_TIER="${2:?--review-tier requires a value (light|standard|deep)}"
            if [[ "$_REVIEW_TIER" != "light" && "$_REVIEW_TIER" != "standard" && "$_REVIEW_TIER" != "deep" ]]; then
                echo "ERROR: --review-tier must be one of: light, standard, deep (got '$_REVIEW_TIER')" >&2
                exit 2
            fi
            shift 2
            ;;
        --selected-tier)
            _SELECTED_TIER="${2:?--selected-tier requires a value (light|standard|deep)}"
            if [[ "$_SELECTED_TIER" != "light" && "$_SELECTED_TIER" != "standard" && "$_SELECTED_TIER" != "deep" ]]; then
                echo "ERROR: --selected-tier must be one of: light, standard, deep (got '$_SELECTED_TIER')" >&2
                exit 2
            fi
            shift 2
            ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
_OUTPUT_PATH="${_OUTPUT_PATH:-${FINDINGS_OUTPUT:-}}"

FINDINGS_FILE="${_OUTPUT_PATH:-$ARTIFACTS_DIR/reviewer-findings.json}"
PENDING_FILE="$ARTIFACTS_DIR/reviewer-findings-pending.json"

# Require piped input (no interactive use)
if [ -t 0 ]; then
    echo "ERROR: No input provided. Pipe JSON to this script." >&2
    echo "Usage: cat findings.json | $0" >&2
    exit 2
fi

# Write to pending file (not the canonical location yet)
cat > "$PENDING_FILE"

if [ ! -s "$PENDING_FILE" ]; then
    echo "ERROR: Empty input — no JSON received." >&2
    rm -f "$PENDING_FILE"
    exit 2
fi

# Warn on deprecated 'scores' key during transition — scores key will be rejected
# once reviewer agents are updated in story f19a-c97e. During this transition, scores
# is tolerated so the review pipeline continues to function with existing agents.
python3 -c "
import json, sys
SCORE_DIMS = {'correctness', 'design', 'hygiene', 'maintainability', 'verification'}
FINDING_ITEM_KEYS = {'severity', 'category', 'description', 'file'}
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
changed = False
if 'scores' in data:
    print('DEPRECATION WARNING: \"scores\" key is deprecated. '
          'Update reviewer agents to 2-key schema {findings, summary} (story f19a-c97e).',
          file=sys.stderr)
# Normalization: when the arch agent emits a single finding dict at the top level
# (e.g., {category, description, severity, file}) instead of the {findings, summary}
# container, wrap it into the expected structure so the schema validator accepts it.
if 'findings' not in data and (FINDING_ITEM_KEYS & set(data.keys())):
    print('WARNING: Top-level keys look like a finding item; wrapping into '
          '{findings:[<finding>], summary: ...}', file=sys.stderr)
    finding = {k: v for k, v in data.items() if k in FINDING_ITEM_KEYS or k in {'rationale', 'recommendation'}}
    data = {'findings': [finding], 'summary': 'Single finding wrapped from non-container response.'}
    changed = True
# Add missing 'summary' field with diagnostic default
if 'summary' not in data:
    print('WARNING: Adding default summary field (arch agent did not provide one)', file=sys.stderr)
    data['summary'] = 'Summary unavailable — arch agent response did not include a summary field.'
    changed = True
# Add missing 'findings' field with empty list when absent
if 'findings' not in data:
    data['findings'] = []
    changed = True
if changed:
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f, indent=2)
" "$PENDING_FILE" >&2 || true  # warnings to stderr; normalization failure is non-fatal

# Inject review_tier field if --review-tier was provided
if [[ -n "$_REVIEW_TIER" ]]; then
    python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
data['review_tier'] = sys.argv[2]
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "$PENDING_FILE" "$_REVIEW_TIER"
fi

# Inject selected_tier field if --selected-tier was provided. This carries the
# classifier's recommended tier into findings so record-review.sh can verify tier
# match without depending on classifier-telemetry.jsonl (which lives in a separate
# artifacts dir in worktree dispatch flows — see bug 21d7-b84a).
if [[ -n "$_SELECTED_TIER" ]]; then
    python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
data['selected_tier'] = sys.argv[2]
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "$PENDING_FILE" "$_SELECTED_TIER"
fi

# Validate schema BEFORE writing to canonical location.
# If validation fails, pending file is removed and the sub-agent cannot obtain a hash.
if ! "$SCRIPT_DIR/validate-review-output.sh" code-review-dispatch "$PENDING_FILE" >&2; then
    rm -f "$PENDING_FILE"
    echo "ERROR: Fix the JSON and re-run write-reviewer-findings.sh." >&2
    exit 1
fi

# Validation passed — promote pending to canonical, write sidecar hash, output hash
mv "$PENDING_FILE" "$FINDINGS_FILE"
_FINDINGS_HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
# Sidecar hash file: lets record-review.sh verify integrity without depending on
# the sub-agent's stdout-transcribed REVIEWER_HASH (LLM output truncation has
# corrupted that value in the past — bug 8073-783f).
printf '%s\n' "$_FINDINGS_HASH" > "${FINDINGS_FILE}.sha256"
printf '%s\n' "$_FINDINGS_HASH"
