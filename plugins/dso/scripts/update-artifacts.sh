#!/usr/bin/env bash
# update-artifacts.sh
# Orchestrator for dso artifact updates. Checks installed artifact stamps against
# the current plugin version, applies per-artifact merge strategy when stale,
# and updates stamps on success.
#
# Usage: update-artifacts.sh [OPTIONS]
#   --target <dir>         Host project root (default: git rev-parse --show-toplevel)
#   --plugin-root <dir>    Plugin root directory (default: directory of this script's parent)
#   --dryrun               Preview changes without writing
#   --conflict-keys <key>  Comma-separated list of config keys that trigger hard conflict
#                          when present in both host and plugin with different values
#
# Exit codes:
#   0 = success (all artifacts up to date or successfully updated)
#   2 = unresolvable conflict (JSON written to stdout)
#   1 = fatal error (missing required files, etc.)

set -uo pipefail

# ── Resolve script location (no hardcoded paths — use _PLUGIN_ROOT) ───────────
_SCRIPT_PATH="${BASH_SOURCE[0]}"
# Resolve symlinks
while [[ -L "$_SCRIPT_PATH" ]]; do
    _SCRIPT_PATH=$(readlink "$_SCRIPT_PATH")
done
_SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# ── Source artifact-merge-lib.sh ──────────────────────────────────────────────
_MERGE_LIB="$_SCRIPT_DIR/artifact-merge-lib.sh"
if [[ ! -f "$_MERGE_LIB" ]]; then
    echo "ERROR: artifact-merge-lib.sh not found at $_MERGE_LIB" >&2
    exit 1
fi
# shellcheck source=./artifact-merge-lib.sh
source "$_MERGE_LIB"

# ── Parse arguments ───────────────────────────────────────────────────────────
_TARGET=""
_GIVEN_PLUGIN_ROOT=""
_DRYRUN=""
_CONFLICT_KEYS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            _TARGET="$2"
            shift 2
            ;;
        --plugin-root)
            _GIVEN_PLUGIN_ROOT="$2"
            shift 2
            ;;
        --dryrun)
            _DRYRUN="1"
            shift
            ;;
        --conflict-keys)
            _CONFLICT_KEYS="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ── Resolve target repo ───────────────────────────────────────────────────────
if [[ -z "$_TARGET" ]]; then
    _TARGET=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "ERROR: --target not specified and current directory is not a git repo" >&2
        exit 1
    }
fi

if [[ ! -d "$_TARGET" ]]; then
    echo "ERROR: target directory does not exist: $_TARGET" >&2
    exit 1
fi

# ── Resolve plugin root (with template layout) ────────────────────────────────
# If --plugin-root was given, use it directly (tests pass a synthetic plugin dir).
# Otherwise, derive from _PLUGIN_ROOT (the real plugin directory).
if [[ -n "$_GIVEN_PLUGIN_ROOT" ]]; then
    _EFFECTIVE_PLUGIN_ROOT="$_GIVEN_PLUGIN_ROOT"
else
    _EFFECTIVE_PLUGIN_ROOT="$_PLUGIN_ROOT"
fi

# Template layout:
# When --plugin-root is given (test mode), templates live inside it:
#   $_EFFECTIVE_PLUGIN_ROOT/templates/host-project/dso
#   $_EFFECTIVE_PLUGIN_ROOT/templates/host-project/dso-config.conf
#   $_EFFECTIVE_PLUGIN_ROOT/docs/examples/pre-commit-config.example.yaml
#   $_EFFECTIVE_PLUGIN_ROOT/docs/examples/ci.example.${stack}.yml
#   $_EFFECTIVE_PLUGIN_ROOT/.claude-plugin/plugin.json
# When running from the real plugin, templates live at the plugin root:
#   $_EFFECTIVE_PLUGIN_ROOT/templates/host-project/dso
#   $_EFFECTIVE_PLUGIN_ROOT/docs/examples/ci.example.${stack}.yml
#   $_EFFECTIVE_PLUGIN_ROOT/docs/examples/pre-commit-config.example.yaml

# ── Resolve template root ─────────────────────────────────────────────────────
# Test mode (--plugin-root given): templates are inside the given plugin root.
# Real mode: templates live at the repo root.
#   Script lives at: $REPO_ROOT/<plugin>/scripts/update-artifacts.sh
#   _SCRIPT_DIR  =  $REPO_ROOT/<plugin>/scripts
#   _PLUGIN_ROOT =  $REPO_ROOT/<plugin-root>
#   Repo root    =  dirname(dirname(_SCRIPT_DIR)) = dirname(<plugin-root>) = plugins → no
#   Actually:    _SCRIPT_DIR/../.. = <plugin>/scripts/../../ = <plugin-root>/.. = plugins/
#   So repo root = dirname(_PLUGIN_ROOT) / dirname(dirname(_SCRIPT_DIR))
#   We need one more level: dirname(plugins) = REPO_ROOT
_TEMPLATE_ROOT=""
if [[ -d "$_EFFECTIVE_PLUGIN_ROOT/templates/host-project" ]]; then
    # Synthetic/test plugin dir has templates inside
    _TEMPLATE_ROOT="$_EFFECTIVE_PLUGIN_ROOT"
else
    # Real mode: compute repo root as the grandparent of _PLUGIN_ROOT
    # _PLUGIN_ROOT = $REPO_ROOT/<plugin-root>
    # dirname(_PLUGIN_ROOT) = $REPO_ROOT/plugins
    # dirname(dirname(_PLUGIN_ROOT)) = $REPO_ROOT
    _PLUGINS_DIR="$(dirname "$_PLUGIN_ROOT")"
    _REPO_ROOT_CANDIDATE="$(dirname "$_PLUGINS_DIR")"
    if [[ -d "$_REPO_ROOT_CANDIDATE/templates/host-project" ]]; then
        _TEMPLATE_ROOT="$_REPO_ROOT_CANDIDATE"
    fi
fi

# ── Read plugin version ───────────────────────────────────────────────────────
# Priority order:
# 1. plugin.json in the given/effective plugin root
# 2. Shim template's embedded stamp (fallback for synthetic/test plugin dirs)
# 3. Real plugin root's plugin.json (ultimate fallback)
_PLUGIN_JSON="$_EFFECTIVE_PLUGIN_ROOT/.claude-plugin/plugin.json"
_PLUGIN_VERSION=""

if [[ -f "$_PLUGIN_JSON" ]]; then
    _PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('$_PLUGIN_JSON'))['version'])" 2>/dev/null || echo "")
fi

# Fallback: read from shim template stamp
if [[ -z "$_PLUGIN_VERSION" ]]; then
    # Try inside effective plugin root (test mode)
    _SHIM_TEMPLATE_PATH="$_EFFECTIVE_PLUGIN_ROOT/templates/host-project/dso"
    if [[ ! -f "$_SHIM_TEMPLATE_PATH" ]]; then
        # Real mode: templates at repo root (two levels above plugin root)
        _PLUGINS_DIR2="$(dirname "$_EFFECTIVE_PLUGIN_ROOT")"
        _REPO_ROOT2="$(dirname "$_PLUGINS_DIR2")"
        _SHIM_TEMPLATE_PATH="$_REPO_ROOT2/templates/host-project/dso"
    fi
    if [[ -f "$_SHIM_TEMPLATE_PATH" ]]; then
        _PLUGIN_VERSION=$(grep '^# dso-version:' "$_SHIM_TEMPLATE_PATH" 2>/dev/null | head -1 | awk '{print $3}' || echo "")
    fi
fi

# Fallback: read from config template stamp
if [[ -z "$_PLUGIN_VERSION" ]]; then
    _CONFIG_TEMPLATE_PATH="$_EFFECTIVE_PLUGIN_ROOT/templates/host-project/dso-config.conf"
    if [[ ! -f "$_CONFIG_TEMPLATE_PATH" ]]; then
        _PLUGINS_DIR3="$(dirname "$_EFFECTIVE_PLUGIN_ROOT")"
        _REPO_ROOT3="$(dirname "$_PLUGINS_DIR3")"
        _CONFIG_TEMPLATE_PATH="$_REPO_ROOT3/templates/host-project/dso-config.conf"
    fi
    if [[ -f "$_CONFIG_TEMPLATE_PATH" ]]; then
        _PLUGIN_VERSION=$(grep '^# dso-version:' "$_CONFIG_TEMPLATE_PATH" 2>/dev/null | head -1 | awk '{print $3}' || echo "")
    fi
fi

# Ultimate fallback: real plugin root
if [[ -z "$_PLUGIN_VERSION" && -n "$_GIVEN_PLUGIN_ROOT" ]]; then
    _REAL_PLUGIN_JSON="$_PLUGIN_ROOT/.claude-plugin/plugin.json"
    if [[ -f "$_REAL_PLUGIN_JSON" ]]; then
        _PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('$_REAL_PLUGIN_JSON'))['version'])" 2>/dev/null || echo "")
    fi
fi

if [[ -z "$_PLUGIN_VERSION" ]]; then
    echo "ERROR: Could not determine plugin version from any source" >&2
    exit 1
fi

# ── Helper: stamp_artifact (inline — mirrors dso-setup.sh implementation) ─────
# stamp_artifact FILE_PATH STAMP_TYPE VERSION
# STAMP_TYPE: "text" → `# dso-version: <version>` | "yaml" → `x-dso-version: <version>`
_stamp_artifact() {
    local file_path="$1"
    local stamp_type="$2"
    local version="$3"

    if [[ ! -f "$file_path" ]]; then
        return 0
    fi

    if [[ "$stamp_type" == "text" ]]; then
        local stamp_line="# dso-version: $version"
        if grep -q '^# dso-version:' "$file_path" 2>/dev/null; then
            sed -i.bak "s|^# dso-version:.*|$stamp_line|" "$file_path" && rm -f "${file_path}.bak"
        else
            # Insert after the first line (shebang)
            local tmp
            tmp=$(mktemp)
            awk -v stamp="$stamp_line" 'NR==1{print; print stamp; next} {print}' "$file_path" > "$tmp"
            mv "$tmp" "$file_path"
        fi
    elif [[ "$stamp_type" == "yaml" ]]; then
        local stamp_line="x-dso-version: $version"
        if grep -q '^x-dso-version:' "$file_path" 2>/dev/null; then
            sed -i.bak "s|^x-dso-version:.*|$stamp_line|" "$file_path" && rm -f "${file_path}.bak"
        else
            # Prepend stamp as first line
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$file_path" "$stamp_line" <<'PYEOF'
import sys
file_path = sys.argv[1]
stamp_line = sys.argv[2]
with open(file_path, 'r') as f:
    content = f.read()
with open(file_path, 'w') as f:
    f.write(stamp_line + '\n' + content)
PYEOF
            else
                local tmp
                tmp=$(mktemp)
                { echo "$stamp_line"; cat "$file_path"; } > "$tmp"
                mv "$tmp" "$file_path"
            fi
        fi
    fi
}

# ── Helper: read stamp from artifact ─────────────────────────────────────────
# Returns the installed version stamp, or empty string if not found.
_read_artifact_stamp() {
    local file_path="$1"
    local stamp_type="$2"  # "text" or "yaml"

    if [[ ! -f "$file_path" ]]; then
        echo ""
        return 0
    fi

    if [[ "$stamp_type" == "text" ]]; then
        grep '^# dso-version:' "$file_path" 2>/dev/null | head -1 | awk '{print $3}' || echo ""
    elif [[ "$stamp_type" == "yaml" ]]; then
        grep '^x-dso-version:' "$file_path" 2>/dev/null | head -1 | awk '{print $2}' || echo ""
    else
        echo ""
    fi
}

# ── Helper: check if artifact is stale ────────────────────────────────────────
# Returns 0 if stale (needs update), 1 if current
_is_stale() {
    local installed_version="$1"
    local plugin_version="$2"

    # Empty stamp = legacy/unmanaged = stale
    [[ -z "$installed_version" ]] && return 0
    # Different version = stale
    [[ "$installed_version" != "$plugin_version" ]] && return 0
    # Same version = current
    return 1
}

# ── Helper: check conflict keys ───────────────────────────────────────────────
# Checks if any of the conflict keys have mismatched values between host and plugin.
# If a conflict is found, emits JSON to stdout and returns 2.
_check_config_conflict_keys() {
    local host_config="$1"
    local plugin_template="$2"

    [[ -z "$_CONFLICT_KEYS" ]] && return 0
    [[ ! -f "$host_config" ]] && return 0
    [[ ! -f "$plugin_template" ]] && return 0

    # Split comma-separated conflict keys
    local IFS_SAVE="$IFS"
    IFS=',' read -ra _conflict_key_list <<< "$_CONFLICT_KEYS"
    IFS="$IFS_SAVE"

    for _ckey in "${_conflict_key_list[@]}"; do
        _ckey="${_ckey// /}"  # trim whitespace
        [[ -z "$_ckey" ]] && continue

        local _escaped_ckey
        # shellcheck disable=SC2016  # single quotes intentional: & is a sed metachar, not a shell variable
        _escaped_ckey=$(printf '%s' "$_ckey" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

        local host_val plugin_val
        host_val=$(grep -E "^[[:space:]]*${_escaped_ckey}[[:space:]]*=" "$host_config" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ') || host_val=""
        plugin_val=$(grep -E "^[[:space:]]*${_escaped_ckey}[[:space:]]*=" "$plugin_template" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ') || plugin_val=""

        # Conflict: key present in both with different values
        if [[ -n "$host_val" && -n "$plugin_val" && "$host_val" != "$plugin_val" ]]; then
            local host_content plugin_content
            host_content=$(cat "$host_config")
            plugin_content=$(cat "$plugin_template")
            _emit_conflict_json "$host_config" "$host_content" "$plugin_content"
            return 2
        fi
    done

    return 0
}

# ── Collect conflict JSON for multi-artifact failures ─────────────────────────
_CONFLICT_JSON=""
_OVERALL_EXIT=0

# ── Artifact paths ────────────────────────────────────────────────────────────
_SHIM_DEST="$_TARGET/.claude/scripts/dso"
_CONFIG_DEST="$_TARGET/.claude/dso-config.conf"
_PRECOMMIT_DEST="$_TARGET/.pre-commit-config.yaml"
_CI_DEST="$_TARGET/.github/workflows/ci.yml"

_SHIM_TEMPLATE="${_TEMPLATE_ROOT:+$_TEMPLATE_ROOT/templates/host-project/dso}"
_CONFIG_TEMPLATE="${_TEMPLATE_ROOT:+$_TEMPLATE_ROOT/templates/host-project/dso-config.conf}"
_PRECOMMIT_EXAMPLE="${_TEMPLATE_ROOT:+$_TEMPLATE_ROOT/docs/examples/pre-commit-config.example.yaml}"
# Stack-aware CI example resolution: read `stack=` from target dso-config.conf
# then pick `ci.example.${stack}.yml`; fall back to python-poetry for legacy installs.
# Extracted as a function so the behavior can be tested directly against fixtures
# without replicating the resolution logic inline in the test.
#
# _resolve_ci_example_for_update TEMPLATE_ROOT TARGET
#   Prints the resolved CI example path (or empty string) on stdout.
_resolve_ci_example_for_update() {
    local template_root="$1"
    local target="$2"
    local ua_stack=""
    [[ -z "$template_root" ]] && { printf ''; return 0; }
    if [[ -f "$target/.claude/dso-config.conf" ]]; then
        ua_stack=$(grep '^stack=' "$target/.claude/dso-config.conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')
    fi
    if [[ -n "$ua_stack" && -f "$template_root/docs/examples/ci.example.${ua_stack}.yml" ]]; then
        printf '%s\n' "$template_root/docs/examples/ci.example.${ua_stack}.yml"
    elif [[ -f "$template_root/docs/examples/ci.example.python-poetry.yml" ]]; then
        printf '%s\n' "$template_root/docs/examples/ci.example.python-poetry.yml"
    fi
}
_CI_EXAMPLE=$(_resolve_ci_example_for_update "$_TEMPLATE_ROOT" "$_TARGET")

# ── 1. Shim: overwrite + stamp ────────────────────────────────────────────────
if [[ -f "$_SHIM_TEMPLATE" ]]; then
    _shim_stamp=$(_read_artifact_stamp "$_SHIM_DEST" "text")

    if _is_stale "$_shim_stamp" "$_PLUGIN_VERSION"; then
        if [[ -n "$_DRYRUN" ]]; then
            echo "[dryrun] Would overwrite shim at $_SHIM_DEST with template from $_SHIM_TEMPLATE" >&2
        else
            mkdir -p "$(dirname "$_SHIM_DEST")"
            cp "$_SHIM_TEMPLATE" "$_SHIM_DEST"
            chmod +x "$_SHIM_DEST"
            _stamp_artifact "$_SHIM_DEST" "text" "$_PLUGIN_VERSION"
            echo "[update-artifacts] Shim updated: $_SHIM_DEST (version: $_PLUGIN_VERSION)" >&2
        fi
    else
        echo "[update-artifacts] Shim already current (version: $_shim_stamp)" >&2
    fi
else
    if [[ -n "$_DRYRUN" ]]; then
        echo "[dryrun] Shim template not found at $_SHIM_TEMPLATE — skip" >&2
    fi
fi

# ── 2. Config: merge_config_file + stamp ─────────────────────────────────────
if [[ -f "$_CONFIG_TEMPLATE" ]]; then
    _config_stamp=$(_read_artifact_stamp "$_CONFIG_DEST" "text")

    if _is_stale "$_config_stamp" "$_PLUGIN_VERSION"; then
        # Check conflict keys before merge
        _conflict_check_result=0
        _conflict_json_output=""
        _conflict_json_output=$(_check_config_conflict_keys "$_CONFIG_DEST" "$_CONFIG_TEMPLATE") || _conflict_check_result=$?

        if [[ "$_conflict_check_result" -eq 2 ]]; then
            _CONFLICT_JSON="$_conflict_json_output"
            _OVERALL_EXIT=2
            echo "[update-artifacts] Conflict detected in config: $_CONFIG_DEST" >&2
        else
            if [[ -n "$_DRYRUN" ]]; then
                merge_config_file "$_CONFIG_DEST" "$_CONFIG_TEMPLATE" "dryrun" >&2
            else
                merge_config_file "$_CONFIG_DEST" "$_CONFIG_TEMPLATE" "" >&2
                _stamp_artifact "$_CONFIG_DEST" "text" "$_PLUGIN_VERSION"
                echo "[update-artifacts] Config merged: $_CONFIG_DEST (version: $_PLUGIN_VERSION)" >&2
            fi
        fi
    else
        echo "[update-artifacts] Config already current (version: $_config_stamp)" >&2
    fi
else
    if [[ -n "$_DRYRUN" ]]; then
        echo "[dryrun] Config template not found at $_CONFIG_TEMPLATE — skip" >&2
    fi
fi

# ── 3. Pre-commit hooks: merge_precommit_hooks + stamp ───────────────────────
if [[ -f "$_PRECOMMIT_EXAMPLE" && -f "$_PRECOMMIT_DEST" ]]; then
    _precommit_stamp=$(_read_artifact_stamp "$_PRECOMMIT_DEST" "yaml")

    if _is_stale "$_precommit_stamp" "$_PLUGIN_VERSION"; then
        if [[ -n "$_DRYRUN" ]]; then
            merge_precommit_hooks "$_PRECOMMIT_DEST" "$_PRECOMMIT_EXAMPLE" "dryrun" >&2
        else
            merge_precommit_hooks "$_PRECOMMIT_DEST" "$_PRECOMMIT_EXAMPLE" "" >&2
            _stamp_artifact "$_PRECOMMIT_DEST" "yaml" "$_PLUGIN_VERSION"
            echo "[update-artifacts] Pre-commit merged: $_PRECOMMIT_DEST (version: $_PLUGIN_VERSION)" >&2
        fi
    else
        echo "[update-artifacts] Pre-commit already current (version: $_precommit_stamp)" >&2
    fi
elif [[ -f "$_PRECOMMIT_EXAMPLE" && ! -f "$_PRECOMMIT_DEST" ]]; then
    echo "[update-artifacts] No pre-commit config at $_PRECOMMIT_DEST — skip" >&2
fi

# ── 4. CI workflow: merge_ci_workflow + stamp ─────────────────────────────────
if [[ -f "$_CI_EXAMPLE" && -f "$_CI_DEST" ]]; then
    _ci_stamp=$(_read_artifact_stamp "$_CI_DEST" "yaml")

    if _is_stale "$_ci_stamp" "$_PLUGIN_VERSION"; then
        if [[ -n "$_DRYRUN" ]]; then
            merge_ci_workflow "$_CI_DEST" "$_CI_EXAMPLE" "dryrun" >&2
        else
            merge_ci_workflow "$_CI_DEST" "$_CI_EXAMPLE" "" >&2
            _stamp_artifact "$_CI_DEST" "yaml" "$_PLUGIN_VERSION"
            echo "[update-artifacts] CI workflow merged: $_CI_DEST (version: $_PLUGIN_VERSION)" >&2
        fi
    else
        echo "[update-artifacts] CI workflow already current (version: $_ci_stamp)" >&2
    fi
elif [[ -f "$_CI_EXAMPLE" && ! -f "$_CI_DEST" ]]; then
    echo "[update-artifacts] No CI workflow at $_CI_DEST — skip" >&2
fi

# ── 5. Brainstorm tag migration ────────────────────────────────────────────────
if [[ -z "$_DRYRUN" ]]; then
    # best-effort — migration failure never fails artifact update
    bash "$_SCRIPT_DIR/ticket-migrate-brainstorm-tags.sh" --target "$_TARGET" &>/dev/stderr || {
        echo '[update-artifacts] Migration warning: brainstorm tag migration exited non-zero — see stderr for details' >&2
    }
fi

# ── 6. File impact migration (file-impact-v1) ─────────────────────────────────
if [[ -z "$_DRYRUN" ]]; then
    bash "$_SCRIPT_DIR/ticket-migrate-file-impact-v1.sh" --target "$_TARGET" &>/dev/stderr || {
        echo '[update-artifacts] Migration warning: file-impact-v1 migration exited non-zero -- see stderr for details' >&2
    }
fi

# ── Emit conflict JSON and exit 2 if any conflicts occurred ───────────────────
if [[ "$_OVERALL_EXIT" -eq 2 ]]; then
    printf '%s\n' "$_CONFLICT_JSON"
    exit 2
fi

exit 0
