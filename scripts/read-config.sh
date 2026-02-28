#!/usr/bin/env bash
# lockpick-workflow/scripts/read-config.sh
# Read a key from workflow-config.yaml and return its value to stdout.
#
# Usage (key-first form):
#   read-config.sh <key> [config-file]
#
# Usage (config-first form, also supported):
#   read-config.sh <config-file> <key>
#
# Arguments:
#   <key>         dot-notation path (e.g. 'commands.test', 'stack', 'version')
#   [config-file] optional path to config file
#
# Resolution order (when no config-file is given):
#   1. ${CLAUDE_PLUGIN_ROOT}/workflow-config.yaml
#   2. $(pwd)/workflow-config.yaml
#   3. If neither exists, output empty string and exit 0
#
# Exit codes:
#   0  — success (key found), missing file, or missing key
#   1  — malformed YAML or unknown argument
#
# Output:
#   stdout — value for found key (no trailing newline); empty for missing key/file
#   stderr — error message for malformed YAML

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# ── Python resolution ──────────────────────────────────────────────────────────
# Caller can override via CLAUDE_PLUGIN_PYTHON env var. Otherwise, probe for a
# python3 that has pyyaml: check common venv locations, then fall back to system.
if [[ -n "${CLAUDE_PLUGIN_PYTHON:-}" ]]; then
    PYTHON="$CLAUDE_PLUGIN_PYTHON"
else
    PYTHON=""
    # Probe candidates in order: project venvs, then system python3
    for candidate in \
        "${REPO_ROOT:+$REPO_ROOT/app/.venv/bin/python3}" \
        "${REPO_ROOT:+$REPO_ROOT/.venv/bin/python3}" \
        "python3"; do
        [[ -z "$candidate" ]] && continue
        [[ "$candidate" != "python3" ]] && [[ ! -f "$candidate" ]] && continue
        if "$candidate" -c "import yaml" 2>/dev/null; then
            PYTHON="$candidate"
            break
        fi
    done
    if [[ -z "$PYTHON" ]]; then
        echo "Error: no python3 with pyyaml found. Install pyyaml or set CLAUDE_PLUGIN_PYTHON." >&2
        exit 1
    fi
fi

# ── Argument parsing ───────────────────────────────────────────────────────────
# Supports two calling conventions:
#   key-first:    read-config.sh <key> [config-file]
#   config-first: read-config.sh <config-file> <key>
#
# Detection: if first argument contains '/' or ends with .yaml/.yml,
# treat it as the config-file path; otherwise treat it as the key.

if [[ $# -eq 0 ]]; then
    echo "Usage: read-config.sh <key> [config-file]" >&2
    exit 1
fi

config_file=""
key=""

arg1="$1"
# Detect if first arg is a file path: contains '/' or ends with .yaml/.yml
if [[ "$arg1" == *"/"* ]] || [[ "$arg1" == *.yaml ]] || [[ "$arg1" == *.yml ]]; then
    # config-first form: read-config.sh <config-file> <key>
    config_file="$arg1"
    if [[ $# -ge 2 ]]; then
        key="$2"
    else
        echo "Usage: read-config.sh <config-file> <key>" >&2
        exit 1
    fi
else
    # key-first form: read-config.sh <key> [config-file]
    key="$arg1"
    if [[ $# -ge 2 ]]; then
        config_file="$2"
    fi
fi

# ── Config file resolution ─────────────────────────────────────────────────────
if [[ -z "$config_file" ]]; then
    # Resolution order:
    # 1. ${CLAUDE_PLUGIN_ROOT}/workflow-config.yaml
    # 2. $(pwd)/workflow-config.yaml
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ -f "${CLAUDE_PLUGIN_ROOT}/workflow-config.yaml" ]]; then
        config_file="${CLAUDE_PLUGIN_ROOT}/workflow-config.yaml"
    elif [[ -f "$(pwd)/workflow-config.yaml" ]]; then
        config_file="$(pwd)/workflow-config.yaml"
    else
        # No config file found — graceful exit
        exit 0
    fi
fi

# ── Missing file — graceful exit ───────────────────────────────────────────────
if [[ ! -f "$config_file" ]]; then
    exit 0
fi

# ── Parse YAML and extract key ─────────────────────────────────────────────────
"$PYTHON" - "$config_file" "$key" <<'PYEOF'
import sys
import yaml

config_path = sys.argv[1]
key_path = sys.argv[2]

try:
    with open(config_path, "r") as f:
        data = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"Error: malformed YAML in {config_path}: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Error: could not read {config_path}: {e}", file=sys.stderr)
    sys.exit(1)

if data is None:
    # Empty file — key not found, exit 0 with empty output
    sys.exit(0)

# Navigate dot-notation path
keys = key_path.split(".")
value = data
try:
    for k in keys:
        if not isinstance(value, dict):
            # Path leads to a non-dict — key not found
            sys.exit(0)
        value = value[k]
    # Null value — treat as missing key
    if value is None:
        sys.exit(0)
    # Non-scalar value — error (caller should request a deeper key)
    if not isinstance(value, (str, int, float, bool)):
        print(f"Error: key '{key_path}' resolves to a non-scalar value", file=sys.stderr)
        sys.exit(1)
    # Found — print without trailing newline
    print(value, end="")
    sys.exit(0)
except KeyError:
    # Key not found — exit 0 with empty output
    sys.exit(0)
PYEOF
