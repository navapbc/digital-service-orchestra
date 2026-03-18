#!/usr/bin/env bash
set -eu
# scripts/dso-setup.sh
# Install the DSO shim into a host project's .claude/scripts/ directory.
#
# Usage: dso-setup.sh [TARGET_REPO [PLUGIN_ROOT]]
#   TARGET_REPO: directory to install shim into; defaults to git repo root
#   PLUGIN_ROOT: plugin directory; defaults to parent of this script's directory
#
# Exit codes: 0=success, 1=fatal error (abort setup), 2=warnings-only (continue with caution)

# ── Prerequisite detection ────────────────────────────────────────────────────
# Prints warnings/errors to stderr. Exits 1 on fatal errors. Returns the number
# of warnings (non-fatal) so the caller can decide whether to exit 2 after setup.
detect_prerequisites() {
    local warnings=0

    # Platform detection
    local platform
    platform=$(uname -s 2>/dev/null || echo "Unknown")
    case "$platform" in
        Darwin)  platform="macOS" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                platform="WSL"
            else
                platform="Linux"
            fi
            ;;
        *)       platform="Unknown" ;;
    esac

    # Check bash major version (must be >=4)
    local bash_version
    bash_version=$(bash --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local bash_major
    bash_major=$(echo "$bash_version" | cut -d. -f1)
    if [[ -z "$bash_major" || "$bash_major" -lt 4 ]]; then
        echo "ERROR: bash >= 4 is required (found: ${bash_version:-unknown})." >&2
        if [[ "$platform" == "macOS" ]]; then
            echo "  Install: brew install bash" >&2
            echo "  Then ensure /usr/local/bin/bash or /opt/homebrew/bin/bash is in PATH." >&2
        else
            echo "  Install: sudo apt-get install bash  (or equivalent)" >&2
        fi
        exit 1
    fi

    # Check for timeout or gtimeout (coreutils)
    if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
        echo "ERROR: 'timeout' (or 'gtimeout') is required but not found." >&2
        if [[ "$platform" == "macOS" ]]; then
            echo "  Install: brew install coreutils" >&2
        else
            echo "  Install: sudo apt-get install coreutils" >&2
        fi
        exit 1
    fi

    # Check for pre-commit (warning only)
    if ! command -v pre-commit >/dev/null 2>&1; then
        echo "WARNING: 'pre-commit' not found. Git hooks will not run automatically." >&2
        echo "  Install: pip install pre-commit  OR  brew install pre-commit" >&2
        warnings=$(( warnings + 1 ))
    fi

    # Check for python3 (warning only)
    if ! command -v python3 >/dev/null 2>&1; then
        echo "WARNING: 'python3' not found. Some DSO scripts require Python 3." >&2
        if [[ "$platform" == "macOS" ]]; then
            echo "  Install: brew install python" >&2
        else
            echo "  Install: sudo apt-get install python3" >&2
        fi
        warnings=$(( warnings + 1 ))
    fi

    # Check for claude CLI (warning only)
    if ! command -v claude >/dev/null 2>&1; then
        echo "WARNING: 'claude' CLI not found. Install from https://claude.ai/claude-code" >&2
        warnings=$(( warnings + 1 ))
    fi

    echo "$warnings"
}

_prereq_warnings=$(detect_prerequisites)

# ── Parse --dryrun flag (position-independent) ────────────────────────────────
DRYRUN=''
_args_filtered=()
for _arg in "$@"; do
    if [[ "$_arg" == '--dryrun' ]]; then
        DRYRUN=1
    else
        _args_filtered+=("$_arg")
    fi
done
set -- "${_args_filtered[@]+"${_args_filtered[@]}"}"

TARGET_REPO="${1:-$(git rev-parse --show-toplevel)}"
PLUGIN_ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
# DIST_ROOT: the repository root containing shared assets (templates/, examples/)
# that live outside the plugin subdir. Falls back to PLUGIN_ROOT for backward
# compatibility when this script is called with the repo root as PLUGIN_ROOT.
# Resolve from git rev-parse (always reliable) rather than relative paths.
DIST_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || DIST_ROOT="$PLUGIN_ROOT"
# Verify DIST_ROOT has the expected assets; fall back to PLUGIN_ROOT otherwise
if [ ! -d "$DIST_ROOT/templates" ] && [ -d "$PLUGIN_ROOT/templates" ]; then
    DIST_ROOT="$PLUGIN_ROOT"
fi

# Ensure TARGET_REPO is a git repository so the dso shim can locate
# workflow-config.conf via `git rev-parse --show-toplevel`.
if ! git -C "$TARGET_REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
    if [[ -z "$DRYRUN" ]]; then
        git -C "$TARGET_REPO" init -q
    else
        echo "[dryrun] Would run: git init -q in $TARGET_REPO"
    fi
fi

if [[ -z "$DRYRUN" ]]; then
    mkdir -p "$TARGET_REPO/.claude/scripts/"
    cp "$DIST_ROOT/templates/host-project/dso" "$TARGET_REPO/.claude/scripts/dso"
    chmod +x "$TARGET_REPO/.claude/scripts/dso"
else
    echo "[dryrun] Would copy $DIST_ROOT/templates/host-project/dso -> $TARGET_REPO/.claude/scripts/dso (chmod +x)"
fi

CONFIG="$TARGET_REPO/workflow-config.conf"
if [[ -z "$DRYRUN" ]]; then
    if grep -q '^dso\.plugin_root=' "$CONFIG" 2>/dev/null; then
        # Update existing entry (idempotent)
        sed -i.bak "s|^dso\.plugin_root=.*|dso.plugin_root=$PLUGIN_ROOT|" "$CONFIG" && rm -f "$CONFIG.bak"
    else
        printf 'dso.plugin_root=%s\n' "$PLUGIN_ROOT" >> "$CONFIG"
    fi
else
    echo "[dryrun] Would write dso.plugin_root=$PLUGIN_ROOT to $CONFIG"
fi

# ── Copy example config files (only if absent — never overwrite) ──────────────
TARGET_PRECOMMIT="$TARGET_REPO/.pre-commit-config.yaml"
if [[ -z "$DRYRUN" ]]; then
    if [ ! -f "$TARGET_PRECOMMIT" ]; then
        cp "$DIST_ROOT/examples/pre-commit-config.example.yaml" "$TARGET_PRECOMMIT"
    fi

    mkdir -p "$TARGET_REPO/.github/workflows"
    if [ ! -f "$TARGET_REPO/.github/workflows/ci.yml" ]; then
        cp "$DIST_ROOT/examples/ci.example.yml" "$TARGET_REPO/.github/workflows/ci.yml"
    fi
else
    echo "[dryrun] Would copy pre-commit-config.example.yaml -> $TARGET_REPO/.pre-commit-config.yaml (only if absent)"
    echo "[dryrun] Would copy ci.example.yml -> $TARGET_REPO/.github/workflows/ci.yml (only if absent)"
fi

# ── Register pre-commit hooks (must come AFTER config copy) ───────────────────
if [[ -z "$DRYRUN" ]]; then
    if command -v pre-commit >/dev/null 2>&1 && [ -f "$TARGET_PRECOMMIT" ]; then
        (cd "$TARGET_REPO" && pre-commit install && pre-commit install --hook-type pre-push) || true
    fi
else
    if command -v pre-commit >/dev/null 2>&1; then
        echo "[dryrun] Would run: pre-commit install && pre-commit install --hook-type pre-push"
    fi
fi

# ── Optional dependency detection (non-blocking) ──────────────────────────────
if ! command -v acli >/dev/null 2>&1; then
    echo '[optional] acli not found. Install: brew install acli (enables Jira integration in DSO)'
fi
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo '[optional] PyYAML not found. Install: pip3 install pyyaml (enables legacy YAML config path)'
fi

# ── Environment variable guidance ─────────────────────────────────────────────
echo '=== Environment Variables (add to your shell profile) ==='
echo 'CLAUDE_PLUGIN_ROOT=  # Optional: overrides dso.plugin_root from workflow-config.conf'
echo 'JIRA_URL=https://your-org.atlassian.net  # Required for Jira sync'
echo 'JIRA_USER=you@example.com  # Required for Jira sync'
echo 'JIRA_API_TOKEN=...  # Required for Jira sync'

# ── Next steps ────────────────────────────────────────────────────────────────
echo '=== Setup complete. Next steps: ==='
echo '1. Edit workflow-config.conf to configure your project'
echo '2. Run /dso:init in Claude Code (dso project-setup interactive configuration)'
echo '3. See docs/INSTALL.md for full documentation'

# Exit 2 (warnings-only) if any warning-level prerequisites were missing.
# Setup has completed successfully — exit 2 signals "continue with caution".
if [[ "$_prereq_warnings" -gt 0 ]]; then
    exit 2
fi
