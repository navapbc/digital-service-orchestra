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
#   cat findings.json | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh"
#   cat findings.json | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh" --output /path/to/slot.json
#
#   Or with a heredoc:
#   cat <<'EOF' | "${CLAUDE_PLUGIN_ROOT}/scripts/write-reviewer-findings.sh"
#   { "scores": {...}, "findings": [...], "summary": "..." }
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

# Normalize 'dimensions' → 'scores' key if the LLM used the wrong top-level key name.
# The light reviewer (haiku) sometimes writes "dimensions" instead of "scores" due to
# positional bias in the agent prompt — the concept word "dimensions" competes with the
# JSON key name "scores". Also normalize nested score objects: the LLM sometimes writes
# { "dimensions": { "correctness": { "score": 4, "rationale": "..." } } } instead of
# flat integers — flatten { "score": N } values to just N (bug 8e5d-ade1).
python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
changed = False
# Normalize top-level 'dimensions' key to 'scores'
if 'dimensions' in data and 'scores' not in data:
    print('WARNING: Normalizing top-level key \"dimensions\" to \"scores\"', file=sys.stderr)
    data['scores'] = data.pop('dimensions')
    changed = True
# Normalize nested score objects: { 'score': N, 'rationale': '...' } -> N
if isinstance(data.get('scores'), dict):
    for k, v in list(data['scores'].items()):
        if isinstance(v, dict) and 'score' in v:
            print(f'WARNING: Flattening nested score object for \"{k}\"', file=sys.stderr)
            data['scores'][k] = v['score']
            changed = True
if changed:
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f, indent=2)
" "$PENDING_FILE" 2>&1 || true  # normalization failure is non-fatal

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

# Validate schema BEFORE writing to canonical location.
# If validation fails, pending file is removed and the sub-agent cannot obtain a hash.
if ! "$SCRIPT_DIR/validate-review-output.sh" code-review-dispatch "$PENDING_FILE" >&2; then
    rm -f "$PENDING_FILE"
    echo "ERROR: Fix the JSON and re-run write-reviewer-findings.sh." >&2
    exit 1
fi

# Validation passed — promote pending to canonical and output hash
mv "$PENDING_FILE" "$FINDINGS_FILE"
shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}'
