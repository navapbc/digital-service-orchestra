#!/usr/bin/env bash
# resolve-dso-version.sh
# Resolves the active DSO plugin version via a 3-tier chain:
#   Tier 1: ~/.claude/plugins/installed_plugins.json (Claude plugin tracker)
#   Tier 2: ci.dso_plugin_version key in .claude/dso-config.conf
#   Tier 3: ${CLAUDE_PLUGIN_ROOT}/../marketplace.json (local marketplace copy)
#
# Security: all resolved URLs must match the canonical upstream repo.
#
# Output (on success, printed to stdout):
#   RESOLVED_VERSION=<version>
#   RESOLVED_TIER=<1|2|3>
#   RESOLVED_SOURCE=<brief description>
#
# Exit codes:
#   0  Version resolved
#   1  All tiers exhausted or security validation failed
#
# Test isolation (env-var overrides):
#   PLUGIN_TRACKING_FILE  — override for installed_plugins.json path (Tier 1)
#   DSO_CONFIG_FILE       — override for dso-config.conf path (Tier 2)
#   MARKETPLACE_JSON      — override for marketplace.json path (Tier 3)

set -euo pipefail

# ── Resolve plugin root ────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# ── Constants ──────────────────────────────────────────────────────────────────
readonly _CANONICAL_REPO_URL="https://github.com/navapbc/digital-service-orchestra"
readonly _CANONICAL_REPO_URL_GIT="${_CANONICAL_REPO_URL}.git"
readonly _DSO_PLUGIN_KEY="dso@digital-service-orchestra"

# ── Helpers ────────────────────────────────────────────────────────────────────

# Validate that a URL (if non-empty) matches the canonical upstream repo.
# Returns 0 if valid or empty; exits 1 with a message to stderr if invalid.
_validate_url() {
    local url="$1"
    local tier="$2"
    [[ -z "$url" ]] && return 0
    if [[ "$url" != "$_CANONICAL_REPO_URL" && "$url" != "$_CANONICAL_REPO_URL_GIT" ]]; then
        printf '[resolve-dso-version] SECURITY: Tier %s resolved a non-upstream URL: %s\n' \
            "$tier" "$url" >&2
        printf '[resolve-dso-version] Expected: %s (with or without .git suffix)\n' \
            "$_CANONICAL_REPO_URL" >&2
        exit 1
    fi
}

# Emit final resolved output and exit 0.
_emit() {
    local version="$1" tier="$2" source="$3"
    printf 'RESOLVED_VERSION=%s\n' "$version"
    printf 'RESOLVED_TIER=%s\n' "$tier"
    printf 'RESOLVED_SOURCE=%s\n' "$source"
    exit 0
}

# ── Tier 1: Claude plugin tracking file ───────────────────────────────────────
_tier1_failure=""
_resolve_tier1() {
    # Default path is ~/.claude/plugins/installed_plugins.json; override via env.
    local tracking_file="${PLUGIN_TRACKING_FILE:-$HOME/.claude/plugins/installed_plugins.json}"

    if [[ ! -f "$tracking_file" ]]; then
        _tier1_failure="tracking file not found: $tracking_file"
        return 1
    fi

    # Use python3 to parse JSON — jq is not guaranteed in all environments.
    local result
    result=$(python3 - "$tracking_file" "$_DSO_PLUGIN_KEY" <<'PYEOF'
import sys, json

tracking_file = sys.argv[1]
plugin_key    = sys.argv[2]

try:
    with open(tracking_file) as f:
        data = json.load(f)
except Exception as e:
    sys.stderr.write(f"[resolve-dso-version] Tier 1: failed to parse {tracking_file}: {e}\n")
    sys.exit(1)

plugins_map = data.get("plugins", {})
entries = plugins_map.get(plugin_key, [])
if not entries:
    sys.exit(2)   # key absent — not an error, just not found

# Pick the most-recently-updated entry that has a version.
best = None
for entry in entries:
    version = entry.get("version", "").strip()
    if version:
        if best is None:
            best = entry
        else:
            # Prefer later lastUpdated timestamp (lexicographic ISO-8601 sort is correct)
            if entry.get("lastUpdated", "") > best.get("lastUpdated", ""):
                best = entry

if best is None:
    sys.exit(2)

version = best.get("version", "").strip()
install_path = best.get("installPath", "").strip()
print(f"{version}\t{install_path}")
PYEOF
    )
    local py_exit=$?

    if [[ $py_exit -eq 2 ]]; then
        _tier1_failure="plugin key '${_DSO_PLUGIN_KEY}' not found in ${tracking_file}"
        return 1
    elif [[ $py_exit -ne 0 ]] || [[ -z "$result" ]]; then
        _tier1_failure="failed to parse ${tracking_file} (python exit ${py_exit})"
        return 1
    fi

    local version install_path
    version="${result%%	*}"
    install_path="${result##*	}"

    if [[ -z "$version" ]]; then
        _tier1_failure="empty version in ${tracking_file}"
        return 1
    fi

    # Tier 1 entries don't carry a URL — they reference a local install cache.
    # No URL to validate; the key name already implies navapbc/digital-service-orchestra.
    _emit "$version" "1" "installed_plugins.json (${install_path:-cache})"
}

# ── Tier 2: dso-config.conf ───────────────────────────────────────────────────
_tier2_failure=""
_resolve_tier2() {
    local config_file
    if [[ -n "${DSO_CONFIG_FILE:-}" ]]; then
        config_file="$DSO_CONFIG_FILE"
    else
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -n "$git_root" ]]; then
            config_file="$git_root/.claude/dso-config.conf"
        else
            config_file=".claude/dso-config.conf"
        fi
    fi

    if [[ ! -f "$config_file" ]]; then
        _tier2_failure="config file not found: ${config_file}"
        return 1
    fi

    # Extract ci.dso_plugin_version from KEY=VALUE format (ignore comments)
    local version
    version=$(grep -v '^\s*#' "$config_file" | grep -m1 '^ci\.dso_plugin_version=' | cut -d= -f2-)

    if [[ -z "$version" ]]; then
        _tier2_failure="ci.dso_plugin_version absent or empty in ${config_file}"
        return 1
    fi

    _emit "$version" "2" "ci.dso_plugin_version in ${config_file}"
}

# ── Tier 3: local marketplace.json ────────────────────────────────────────────
_tier3_failure=""
_resolve_tier3() {
    local marketplace_file
    if [[ -n "${MARKETPLACE_JSON:-}" ]]; then
        marketplace_file="$MARKETPLACE_JSON"
    else
        # Default: <plugin-root>/.claude-plugin/../marketplace.json doesn't exist;
        # the local copy shipped in the repo is at .claude-plugin/marketplace.json
        # one level up from the plugin root.
        marketplace_file="$_PLUGIN_ROOT/.claude-plugin/marketplace.json"
        # Fallback: repo-root level
        if [[ ! -f "$marketplace_file" ]]; then
            local git_root
            git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
            if [[ -n "$git_root" && -f "$git_root/.claude-plugin/marketplace.json" ]]; then
                marketplace_file="$git_root/.claude-plugin/marketplace.json"
            fi
        fi
    fi

    if [[ ! -f "$marketplace_file" ]]; then
        _tier3_failure="marketplace.json not found: ${marketplace_file}"
        return 1
    fi

    local result
    result=$(python3 - "$marketplace_file" <<'PYEOF'
import sys, json

marketplace_file = sys.argv[1]

try:
    with open(marketplace_file) as f:
        data = json.load(f)
except Exception as e:
    sys.stderr.write(f"[resolve-dso-version] Tier 3: failed to parse {marketplace_file}: {e}\n")
    sys.exit(1)

plugins = data.get("plugins", [])
dso_entry = None
for plugin in plugins:
    if plugin.get("name") == "dso":
        dso_entry = plugin
        break

if dso_entry is None:
    sys.stderr.write("[resolve-dso-version] Tier 3: 'dso' channel not found in marketplace.json\n")
    sys.exit(2)

source = dso_entry.get("source", {})
ref = source.get("ref", "").strip()
url = source.get("url", "").strip()

if not ref:
    sys.stderr.write("[resolve-dso-version] Tier 3: 'dso' channel source.ref is empty or missing\n")
    sys.exit(3)

print(f"{ref}\t{url}")
PYEOF
    )
    local py_exit=$?

    if [[ $py_exit -eq 2 ]]; then
        _tier3_failure="'dso' channel entry absent in ${marketplace_file}"
        return 1
    elif [[ $py_exit -eq 3 ]]; then
        _tier3_failure="'dso' channel source.ref empty in ${marketplace_file}"
        return 1
    elif [[ $py_exit -ne 0 ]] || [[ -z "$result" ]]; then
        _tier3_failure="failed to parse ${marketplace_file} (python exit ${py_exit})"
        return 1
    fi

    local ref url
    ref="${result%%	*}"
    url="${result##*	}"

    if [[ -z "$ref" ]]; then
        _tier3_failure="empty ref in ${marketplace_file}"
        return 1
    fi

    # Security: validate the URL before accepting this version.
    _validate_url "$url" "3"

    _emit "$ref" "3" "marketplace.json dso channel (${marketplace_file})"
}

# ── Main resolution chain ─────────────────────────────────────────────────────
_resolve_tier1 || true
_resolve_tier2 || true
_resolve_tier3 || true

# All tiers failed — emit diagnostic and exit 1.
printf '[resolve-dso-version] ERROR: failed to resolve DSO version from all tiers:\n' >&2
printf '  Tier 1 (installed_plugins.json): %s\n' "${_tier1_failure:-unknown failure}" >&2
printf '  Tier 2 (dso-config.conf):        %s\n' "${_tier2_failure:-unknown failure}" >&2
printf '  Tier 3 (marketplace.json):       %s\n' "${_tier3_failure:-unknown failure}" >&2
exit 1
