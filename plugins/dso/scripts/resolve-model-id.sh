#!/usr/bin/env bash
set -uo pipefail
# scripts/resolve-model-id.sh
# Resolve the canonical model ID for an agent tier from dso-config.conf.
#
# Usage: resolve-model-id.sh <tier> [config-file]
#
#   <tier>        — one of: haiku, sonnet, opus
#   [config-file] — optional path to dso-config.conf (defaults to auto-resolved
#                   via WORKFLOW_CONFIG_FILE env var or git root .claude/dso-config.conf)
#
# Output (stdout): model ID string (e.g. claude-sonnet-4-6-20260320)
# Exit codes:
#   0 — success, model ID printed to stdout
#   1 — tier unrecognized, key absent, or empty value

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ_CONFIG="$SCRIPT_DIR/read-config.sh"

tier="${1:-}"
config_file="${2:-}"

# Validate tier argument
if [[ -z "$tier" ]]; then
    echo "Error: tier argument required (haiku|sonnet|opus)" >&2
    exit 1
fi

case "$tier" in
    haiku|sonnet|opus)
        ;;
    *)
        echo "Error: unrecognized tier '$tier' — must be one of: haiku, sonnet, opus" >&2
        exit 1
        ;;
esac

# Build config key
key="model.${tier}"

# Resolve model ID via read-config.sh
if [[ -n "$config_file" ]]; then
    model_id=$(bash "$READ_CONFIG" "$key" "$config_file" 2>/dev/null)
else
    model_id=$(bash "$READ_CONFIG" "$key" 2>/dev/null)
fi

if [[ -z "$model_id" ]]; then
    echo "Error: config key '$key' is absent or empty in the config file" >&2
    exit 1
fi

printf '%s\n' "$model_id"
