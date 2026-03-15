#!/usr/bin/env bash
set -uo pipefail
# lockpick-workflow/scripts/read-config.sh
# YAML/conf reader for workflow-config.yaml (or .conf) files.
#
# Usage (key-first):  read-config.sh [--list] <key> [config-file]
# Usage (config-first): read-config.sh <config-file> <key>
#
# Supports:
#   - Arbitrary nesting depth via dot-notation (e.g. "tickets.sync.jira_project_key")
#   - List/sequence values with --list flag (one item per line)
#   - Malformed YAML detection (exits 1 with error message)
#   - Non-scalar detection in scalar mode (exits 1 with "non-scalar" error)
#   - Empty list → empty output, exit 0
#   - Absent key in --list mode → exit 1
#   - Absent key in scalar mode → empty output, exit 0
#   - Missing file → empty output, exit 0
#   - CLAUDE_PLUGIN_PYTHON env var to override Python interpreter
#
# Exit codes:
#   0 — success, missing file, or missing key (scalar mode)
#   1 — missing key in --list mode (distinguishes "empty" from "absent")
#   1 — malformed YAML
#   1 — non-scalar value in scalar mode

set -uo pipefail
list_mode=""; batch_mode=""; [[ "${1:-}" == "--list" ]] && { list_mode=1; shift; }
[[ "${1:-}" == "--batch" ]] && { batch_mode=1; shift; }

# Detect config-first form: first arg contains '/' or ends with .conf/.yaml/.yml
arg1="${1:-}"
if [[ "$arg1" == *"/"* || "$arg1" == *.conf || "$arg1" == *.yaml || "$arg1" == *.yml ]]; then
    config_file="$arg1"; key="${2:-}"
else
    key="$arg1"; config_file="${2:-}"
fi

# Resolve config file when not specified (.conf preferred, .yaml fallback)
if [[ -z "$config_file" ]]; then
    root="${CLAUDE_PLUGIN_ROOT:-$(pwd)}"
    if [[ -f "$root/workflow-config.conf" ]]; then config_file="$root/workflow-config.conf"
    elif [[ -f "$root/workflow-config.yaml" ]]; then config_file="$root/workflow-config.yaml" # fallback for migration
    else exit 0; fi
fi
# Missing file: try swapping extension, else exit 0
if [[ ! -f "$config_file" ]]; then
    alt="${config_file%.yaml}.conf"; [[ "$alt" == "$config_file" ]] && alt="${config_file%.conf}.yaml"
    [[ -f "$alt" ]] && config_file="$alt" || exit 0
fi
# Prefer .conf sibling over .yaml when both exist
if [[ "$config_file" == *.yaml || "$config_file" == *.yml ]]; then
    sib="${config_file%.yaml}.conf"; [[ "$config_file" == *.yml ]] && sib="${config_file%.yml}.conf"
    [[ -f "$sib" ]] && config_file="$sib"
fi

# ── .conf format: flat KEY=VALUE lines ───────────────────────────────────────
if [[ "$config_file" == *.conf ]]; then
    _conf_lines() { grep -v '^\s*#' "$config_file"; }
    if [[ -n "$batch_mode" ]]; then
        # Output all keys as UPPER_CASE_WITH_UNDERSCORES=value lines (safe for eval)
        while read -r line; do
            [[ -z "$line" ]] && continue
            raw_key="${line%%=*}"
            raw_val="${line#*=}"
            var_name="${raw_key^^}"        # uppercase
            var_name="${var_name//./_}"    # dots to underscores
            # Single-quote value for safe eval; escape any single quotes in value
            safe_val="${raw_val//\'/\'\\\'\'}"
            printf "%s='%s'\n" "$var_name" "$safe_val"
        done < <(_conf_lines | grep -E '^[^=]+=')
        exit 0
    elif [[ -n "$list_mode" ]]; then
        results=$(_conf_lines | grep "^${key}=" | cut -d= -f2-)
        [[ -n "$results" ]] && { printf '%s\n' "$results"; exit 0; }; exit 1
    else
        printf '%s' "$(_conf_lines | grep -m1 "^${key}=" | cut -d= -f2-)"; exit 0
    fi
fi

# ── YAML format: use Python/pyyaml for full YAML support ──────────────────────

# Source config-paths.sh for CFG_PYTHON_VENV (guard against circular sourcing:
# config-paths.sh calls _cfg_read() which invokes read-config.sh as a subprocess)
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_config_paths="${CLAUDE_PLUGIN_ROOT:-$_script_dir/..}/hooks/lib/config-paths.sh"
if [[ -z "${_READ_CONFIG_IN_PROGRESS:-}" && -f "$_config_paths" ]]; then
    export _READ_CONFIG_IN_PROGRESS=1
    source "$_config_paths"
    unset _READ_CONFIG_IN_PROGRESS
fi

# Resolve Python interpreter (CLAUDE_PLUGIN_PYTHON env var or probe)
PYTHON="${CLAUDE_PLUGIN_PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
    # Derive actual repo root from script location (not necessarily CLAUDE_PLUGIN_ROOT)
    _actual_repo_root="$(cd "$_script_dir" && git rev-parse --show-toplevel 2>/dev/null || echo "")"
    # CFG_PYTHON_VENV and CFG_APP_DIR are set by config-paths.sh (sourced above)
    _py_venv="${CFG_PYTHON_VENV:-${CFG_APP_DIR:-app}/.venv/bin/python3}"
    for candidate in \
        "${_actual_repo_root:+$_actual_repo_root/$_py_venv}" \
        "${_actual_repo_root:+$_actual_repo_root/.venv/bin/python3}" \
        "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/$_py_venv}" \
        "python3"; do
        [[ -z "$candidate" ]] && continue
        [[ "$candidate" != "python3" ]] && [[ ! -f "$candidate" ]] && continue
        if "$candidate" -c "import yaml" 2>/dev/null; then
            PYTHON="$candidate"
            break
        fi
    done
fi

if [[ -z "$PYTHON" ]]; then
    echo "Error: no python3 with pyyaml found — cannot parse YAML config" >&2
    exit 1
fi

# Python script: resolve a dotted key path in YAML, handling lists and scalars.
# Outputs differ by mode:
#   scalar mode:  print scalar value (str/int/bool/float), error on list/dict
#   list mode:    print each list item on its own line, scalar on one line,
#                 empty list → empty output, absent key → exit 1
#   batch mode:   print all scalar leaf keys as UPPER_CASE_WITH_UNDERSCORES=value
_PY_SCRIPT='
import sys, yaml

config_file = sys.argv[1]
key_path    = sys.argv[2]
list_mode   = sys.argv[3] == "1"
batch_mode  = sys.argv[4] == "1"

# Load and validate YAML
try:
    with open(config_file) as f:
        data = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"Error: malformed YAML in {config_file}: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Error: cannot read {config_file}: {e}", file=sys.stderr)
    sys.exit(1)

if data is None:
    data = {}

# Batch mode: walk all scalar leaves, output UPPER_CASE_WITH_UNDERSCORES=value
if batch_mode:
    def _walk(node, prefix=""):
        if isinstance(node, dict):
            for k, v in node.items():
                _walk(v, f"{prefix}{k}." if prefix else f"{k}.")
        elif isinstance(node, list):
            pass  # skip list values in batch mode
        else:
            key_name = prefix.rstrip(".").replace(".", "_").upper()
            # Single-quote value for safe eval; escape embedded single quotes
            safe_val = str(node).replace("'", "'\\''")
            print(f"{key_name}='{safe_val}'")
    _walk(data)
    sys.exit(0)

# Traverse dot-notation key path
parts = key_path.split(".")
value = data
for part in parts:
    if not isinstance(value, dict):
        value = None
        break
    value = value.get(part)
    if value is None:
        break

# Key absent
if value is None:
    if list_mode:
        sys.exit(1)  # absent key in list mode = error
    else:
        sys.exit(0)  # absent key in scalar mode = empty output

# List mode
if list_mode:
    if isinstance(value, list):
        for item in value:
            print(item)          # empty list prints nothing
    else:
        print(value)             # scalar degrades gracefully
    sys.exit(0)

# Scalar mode
if isinstance(value, (list, dict)):
    print(f"Error: key \"{key_path}\" is non-scalar (use --list to read sequences)", file=sys.stderr)
    sys.exit(1)
print(value, end="")
sys.exit(0)
'

"$PYTHON" -c "$_PY_SCRIPT" "$config_file" "${key:-}" "${list_mode:-0}" "${batch_mode:-0}"
