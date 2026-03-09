#!/usr/bin/env bash
# lockpick-workflow/scripts/read-config.sh
# Read a key from workflow-config.yaml and return its value to stdout.
#
# Usage (key-first form):
#   read-config.sh [--list] <key> [config-file]
#
# Usage (config-first form, also supported):
#   read-config.sh <config-file> <key>
#
# Usage (cache generation):
#   read-config.sh --generate-cache [config-file]
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
#   0  — success (key found), missing file, or missing key (scalar mode)
#   1  — malformed YAML, unknown argument, or list mode key not found
#        (in --list mode, absent/missing key exits 1 so callers can distinguish
#         "empty list" from "key does not exist")
#
# Flags:
#   --list            output list-valued keys as newline-separated items;
#                     scalars degrade to single-line output;
#                     absent key exits 1 (not 0) to distinguish from empty list
#   --generate-cache  dump all keys to a flat cache file for fast subsequent reads;
#                     cache location: /tmp/workflow-plugin-<hash>/config-cache
#
# Caching:
#   Normal reads check a flat cache file before spawning Python. The cache is
#   keyed by config file path and validated by mtime. On cache miss, the script
#   generates the cache via --generate-cache and retries. If cache generation
#   fails, it falls through to the Python parser (self-healing).
#
# Output:
#   stdout — value for found key (no trailing newline); empty for missing key/file
#            (with --list: newline-terminated lines)
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

# ── Cache infrastructure ──────────────────────────────────────────────────────
# Flat-file cache eliminates Python subprocess overhead (~100ms → ~3ms).
# Cache is per-repo/worktree, stored alongside other workflow plugin artifacts.

# Returns the workflow plugin artifacts dir path (matches deps.sh get_artifacts_dir).
# Does NOT source deps.sh — this script is called by non-hook consumers too.
_wcfg_cache_dir() {
    local repo="${REPO_ROOT:-}"
    [[ -z "$repo" ]] && return 1
    local hash
    hash=$(echo -n "$repo" | shasum -a 256 2>/dev/null | awk '{print $1}' | head -c 16)
    [[ -z "$hash" ]] && return 1
    echo "/tmp/workflow-plugin-${hash}"
}

# Cross-platform file mtime (macOS then Linux).
_wcfg_file_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Read a key from the flat cache file.
# Returns 0 on success (value on stdout), 1 on miss/error.
# Handles: scalars, lists, scalar-degradation in list mode,
# empty lists, and list-key-in-scalar-mode detection.
_wcfg_read_cache() {
    local key="$1" list_mode="$2" cache_file="$3"
    [[ ! -f "$cache_file" ]] && return 1

    if [[ -n "$list_mode" ]]; then
        # List mode: grep key.N= lines, extract values in order
        local results
        results=$(grep "^${key}\.[0-9]" "$cache_file" 2>/dev/null | cut -d= -f2-) || true
        if [[ -n "$results" ]]; then
            echo "$results"
            return 0
        fi
        # Scalar degradation: --list on a scalar key outputs scalar on one line
        local val
        val=$(grep "^${key}=" "$cache_file" 2>/dev/null | head -1 | cut -d= -f2-) || true
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
        # Empty list: key exists as a list but has no items
        if grep -q "^${key}\.__empty_list=" "$cache_file" 2>/dev/null; then
            return 0
        fi
        return 1
    else
        # Scalar mode: exact key match
        local val
        val=$(grep "^${key}=" "$cache_file" 2>/dev/null | head -1 | cut -d= -f2-) || true
        if [[ -z "$val" ]]; then
            # Check if key is a list/dict (has sub-keys) — non-scalar error
            if grep -q "^${key}\." "$cache_file" 2>/dev/null; then
                echo "Error: key '${key}' resolves to a non-scalar value" >&2
                return 1
            fi
        fi
        printf '%s' "$val"
        return 0
    fi
}

# ── Handle --generate-cache mode ─────────────────────────────────────────────
# Dumps all YAML leaf keys to a flat cache file for fast grep-based reads.
# Called on cache miss by the fast-path, or explicitly for pre-warming.
if [[ "${1:-}" == "--generate-cache" ]]; then
    shift
    _gc_config="${1:-}"
    # Resolve config file if not provided
    if [[ -z "$_gc_config" ]]; then
        if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ -f "${CLAUDE_PLUGIN_ROOT}/workflow-config.yaml" ]]; then
            _gc_config="${CLAUDE_PLUGIN_ROOT}/workflow-config.yaml"
        elif [[ -f "$(pwd)/workflow-config.yaml" ]]; then
            _gc_config="$(pwd)/workflow-config.yaml"
        else
            exit 0
        fi
    fi
    [[ ! -f "$_gc_config" ]] && exit 0

    _gc_cache_dir=$(_wcfg_cache_dir) || exit 0
    mkdir -p "$_gc_cache_dir" 2>/dev/null || exit 0
    _gc_cache_file="$_gc_cache_dir/config-cache"
    _gc_mtime=$(_wcfg_file_mtime "$_gc_config")

    _gc_tmp=$(mktemp "${_gc_cache_file}.tmp.XXXXXX" 2>/dev/null) || exit 0
    if "$PYTHON" - "$_gc_config" "$_gc_mtime" <<'PYEOF' > "$_gc_tmp"
import sys
import yaml

config_path = sys.argv[1]
mtime = sys.argv[2]

try:
    with open(config_path, "r") as f:
        data = yaml.safe_load(f)
except Exception:
    sys.exit(1)

if data is None:
    sys.exit(0)

print(f"# wcfg-cache v1")
print(f"# config={config_path}")
print(f"# mtime={mtime}")

def dump(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            dump(v, f"{prefix}{k}.")
    elif isinstance(obj, list):
        key = prefix.rstrip(".")
        if len(obj) == 0:
            # Mark empty lists so cache reader can distinguish from missing keys
            print(f"{key}.__empty_list=1")
        for i, item in enumerate(obj):
            if isinstance(item, (dict, list)):
                dump(item, f"{key}.{i}.")
            else:
                print(f"{key}.{i}={item}")
    elif obj is not None:
        key = prefix.rstrip(".")
        print(f"{key}={obj}")

dump(data)
PYEOF
    then
        mv "$_gc_tmp" "$_gc_cache_file" 2>/dev/null || true
    fi
    rm -f "$_gc_tmp" 2>/dev/null || true
    exit 0
fi

# ── Argument parsing ───────────────────────────────────────────────────────────
# Supports two calling conventions:
#   key-first:    read-config.sh <key> [config-file]
#   config-first: read-config.sh <config-file> <key>
#
# Detection: if first argument contains '/' or ends with .yaml/.yml,
# treat it as the config-file path; otherwise treat it as the key.

if [[ $# -eq 0 ]]; then
    echo "Usage: read-config.sh [--list] <key> [config-file]" >&2
    exit 1
fi

config_file=""
key=""
list_mode=""

# Detect --list flag
if [[ "$1" == "--list" ]]; then
    list_mode="1"
    shift
    if [[ $# -eq 0 ]]; then
        echo "Usage: read-config.sh --list <key> [config-file]" >&2
        exit 1
    fi
fi

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

# ── Fast-path: check cache before spawning Python ────────────────────────────
# On cache hit (~3ms): grep the flat cache file and return.
# On cache miss: generate cache via --generate-cache, retry, then fall through
# to Python if cache generation fails. Self-healing — cache failures degrade
# to the original Python path, never to wrong behavior.
_cache_dir=$(_wcfg_cache_dir 2>/dev/null) || true
if [[ -n "${_cache_dir:-}" ]]; then
    _cache="${_cache_dir}/config-cache"
    _cache_fresh=0

    if [[ -f "$_cache" ]]; then
        _cached_config=$(sed -n 's/^# config=//p' "$_cache" | head -1)
        _cached_mtime=$(sed -n 's/^# mtime=//p' "$_cache" | head -1)
        _current_mtime=$(_wcfg_file_mtime "$config_file")
        if [[ "$_cached_config" == "$config_file" && \
              "$_cached_mtime" == "$_current_mtime" && \
              -n "$_cached_mtime" ]]; then
            _cache_fresh=1
        fi
    fi

    if [[ "$_cache_fresh" -eq 1 ]]; then
        _wcfg_read_cache "$key" "${list_mode:-}" "$_cache"
        exit $?
    fi

    # Cache miss or stale — regenerate and retry
    "${BASH_SOURCE[0]}" --generate-cache "$config_file" 2>/dev/null || true
    if [[ -f "$_cache" ]]; then
        # Verify the regenerated cache is for our config file
        _new_config=$(sed -n 's/^# config=//p' "$_cache" | head -1)
        if [[ "$_new_config" == "$config_file" ]]; then
            _wcfg_read_cache "$key" "${list_mode:-}" "$_cache"
            exit $?
        fi
    fi
fi
# Cache unavailable — fall through to Python

# ── Parse YAML and extract key ─────────────────────────────────────────────────
"$PYTHON" - "$config_file" "$key" "${list_mode:-0}" <<'PYEOF'
import sys
import yaml

config_path = sys.argv[1]
key_path = sys.argv[2]
list_mode = sys.argv[3] == "1"

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
    # Empty file — key not found
    sys.exit(1 if list_mode else 0)

# Navigate dot-notation path
keys = key_path.split(".")
value = data
try:
    for k in keys:
        if not isinstance(value, dict):
            # Path leads to a non-dict — key not found
            sys.exit(1 if list_mode else 0)
        value = value[k]
    # Null value — treat as missing key
    if value is None:
        sys.exit(0)
    # List value — output newline-separated when --list, error otherwise
    if isinstance(value, list):
        if list_mode:
            for item in value:
                print(item)
            sys.exit(0)
        else:
            print(f"Error: key '{key_path}' resolves to a non-scalar value", file=sys.stderr)
            sys.exit(1)
    # Non-scalar, non-list value — error
    if not isinstance(value, (str, int, float, bool)):
        print(f"Error: key '{key_path}' resolves to a non-scalar value", file=sys.stderr)
        sys.exit(1)
    # Scalar — print (with newline in list mode for consistency, without otherwise)
    if list_mode:
        print(value)
    else:
        print(value, end="")
    sys.exit(0)
except KeyError:
    # Key not found
    sys.exit(1 if list_mode else 0)
PYEOF
