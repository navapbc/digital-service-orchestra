#!/usr/bin/env bash
# create-dso-app.sh — DSO NextJS Starter one-command bootstrap installer
# Partial-download protection: all logic inside main(), invoked at end of file.
set -euo pipefail

# Self-detect plugin root via BASH_SOURCE (never hardcode paths)
# When invoked via bash <(curl ...), BASH_SOURCE[0] is /dev/stdin — fall back to pwd
if [ "${BASH_SOURCE[0]}" != "/dev/stdin" ] && [ -n "${BASH_SOURCE[0]}" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # _PLUGIN_ROOT is parent of scripts/
  _PLUGIN_ROOT="$(dirname "$_SCRIPT_DIR")"
else
  # Invoked via curl pipe — use installed path from dso-config.conf if available
  _PLUGIN_ROOT="${DSO_PLUGIN_ROOT:-}"
fi

# Capture test-isolation env vars at source/load time while they are in scope.
# When sourced via "MARKETPLACE_BASE=X CLAUDE_PLUGIN_ROOT=Y source script",
# these env vars are available during source execution but may revert after the
# source call returns. Saving them to script-level globals lets
# detect_dso_plugin_root() honour the intended overrides when called later.
#
# _DSO_CLAUDE_PLUGIN_ROOT_SET: "1" if CLAUDE_PLUGIN_ROOT was explicitly present
#   at load time (even if empty), "" if absent. Distinguishes "cleared to empty"
#   from "never set".
if [ -n "${CLAUDE_PLUGIN_ROOT+x}" ]; then
  _DSO_CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
  _DSO_CLAUDE_PLUGIN_ROOT_SET="1"
else
  _DSO_CLAUDE_PLUGIN_ROOT=""
  _DSO_CLAUDE_PLUGIN_ROOT_SET=""
fi
_DSO_MARKETPLACE_BASE="${MARKETPLACE_BASE:-}"

# detect_dso_plugin_root <project_dir>
# Resolve the installed DSO plugin root, write it to project dso-config.conf,
# and run a smoke test. Prints the detected path on stdout.
#
# Priority:
#   1. $CLAUDE_PLUGIN_ROOT env var — if set and sentinel exists
#   2. ${MARKETPLACE_BASE:-$HOME/.claude/plugins/marketplaces}/digital-service-orchestra/
#      (MARKETPLACE_BASE is an env var override for test isolation)
#   3. Dev env: _PLUGIN_ROOT (resolved from BASH_SOURCE) when it contains the sentinel
#   4. Fatal error — prints actionable message and exits 1
detect_dso_plugin_root() {
  local project_dir="${1:-}"
  local plugin_root=""

  # Determine effective CLAUDE_PLUGIN_ROOT: prefer load-time capture when it was
  # explicitly set (including to empty — that disables this probe).
  local _effective_plugin_root
  if [ -n "$_DSO_CLAUDE_PLUGIN_ROOT_SET" ]; then
    _effective_plugin_root="$_DSO_CLAUDE_PLUGIN_ROOT"
  else
    _effective_plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
  fi

  # Determine effective MARKETPLACE_BASE: load-time capture takes precedence when
  # non-empty (runtime fallback used for non-test invocations).
  local _effective_marketplace_base
  if [ -n "$_DSO_MARKETPLACE_BASE" ]; then
    _effective_marketplace_base="$_DSO_MARKETPLACE_BASE"
  else
    _effective_marketplace_base="${MARKETPLACE_BASE:-}"
  fi

  # 1. CLAUDE_PLUGIN_ROOT env var
  if [ -n "$_effective_plugin_root" ] && \
     [ -f "$_effective_plugin_root/.claude-plugin/plugin.json" ]; then
    plugin_root="$_effective_plugin_root"
  fi

  # 2. Marketplace path
  if [ -z "$plugin_root" ]; then
    local _marketplace_base="${_effective_marketplace_base:-$HOME/.claude/plugins/marketplaces}"
    local _marketplace_path="$_marketplace_base/digital-service-orchestra"
    if [ -f "$_marketplace_path/.claude-plugin/plugin.json" ]; then
      plugin_root="$_marketplace_path"
    fi
  fi

  # 3. Dev env: _PLUGIN_ROOT resolved at script load time via BASH_SOURCE
  if [ -z "$plugin_root" ]; then
    if [ -n "${_PLUGIN_ROOT:-}" ] && \
       [ -f "$_PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
      plugin_root="$_PLUGIN_ROOT"
    fi
  fi

  # 4. Fatal error
  if [ -z "$plugin_root" ]; then
    echo "Error: DSO plugin not found. Install via Claude Code marketplace or set CLAUDE_PLUGIN_ROOT." >&2
    exit 1
  fi

  # Write dso.plugin_root to project config if the file already exists
  if [ -n "$project_dir" ] && [ -f "$project_dir/.claude/dso-config.conf" ]; then
    if grep -q '^dso\.plugin_root=' "$project_dir/.claude/dso-config.conf" 2>/dev/null; then
      sed -i.bak "s|^dso\.plugin_root=.*|dso.plugin_root=$plugin_root|" \
        "$project_dir/.claude/dso-config.conf" && \
        rm -f "$project_dir/.claude/dso-config.conf.bak"
    else
      printf 'dso.plugin_root=%s\n' "$plugin_root" >> "$project_dir/.claude/dso-config.conf"
    fi

    # Smoke test: verify the DSO CLI works in the scaffolded project
    # (gated on .tickets-tracker to avoid false-negative on fresh clone)
    if [ -d "$project_dir/.tickets-tracker" ]; then
      (cd "$project_dir" && .claude/scripts/dso ticket list) || \
        { echo "Error: smoke test failed — dso ticket list returned non-zero" >&2; exit 1; }
    else
      (cd "$project_dir" && .claude/scripts/dso ticket show --help >/dev/null 2>&1) || true
    fi
  fi

  echo "$plugin_root"
}

check_homebrew_deps() {
  # Check Homebrew first
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required but not installed."
    echo "Install it from https://brew.sh, then re-run this installer."
    exit 1
  fi

  local missing=()

  # Check bash 4+
  local bash_ver
  bash_ver=$(bash --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")
  local bash_major="${bash_ver%%.*}"
  if [ "${bash_major:-0}" -lt 4 ]; then
    missing+=("bash")
  fi

  # Check git
  if ! command -v git >/dev/null 2>&1; then missing+=("git"); fi

  # Check GNU coreutils (greadlink as proxy)
  if ! command -v greadlink >/dev/null 2>&1; then missing+=("coreutils"); fi

  # Check pre-commit
  if ! command -v pre-commit >/dev/null 2>&1; then missing+=("pre-commit"); fi

  # Check Node 20.x
  local node_ver=""
  if command -v node >/dev/null 2>&1; then
    node_ver=$(node --version 2>/dev/null | grep -oE '^v([0-9]+)' | tr -d 'v' || echo "0")
  fi
  if [ "${node_ver:-0}" -lt 20 ]; then
    echo "Installing Node 20.x via Homebrew..."
    brew install node@20 || missing+=("node@20")
  fi

  # Inject Node 20.x PATH (keg-only — must be explicit)
  if brew list node@20 >/dev/null 2>&1; then
    local node20_prefix
    node20_prefix="$(brew --prefix node@20)"
    export PATH="$node20_prefix/bin:$PATH"
  fi

  # Check Claude Code
  if ! command -v claude >/dev/null 2>&1; then
    echo "Installing Claude Code via Homebrew..."
    brew install --cask claude-code || missing+=("claude-code (cask)")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    for pkg in "${missing[@]}"; do
      echo "  Run: brew install $pkg"
    done
    echo "Prerequisites not met — re-run after installing the above."
    exit 1
  fi

  echo "All dependencies satisfied."
}

# sanitize_project_name <name>
# Strips or replaces shell-unsafe characters with hyphens.
# Allowed characters: alphanumeric, hyphen, underscore.
# Exits with an actionable error if the sanitized result is empty.
sanitize_project_name() {
  local raw="$1"
  # Replace spaces, slashes, $, *, ?, [, ], \, ^ with hyphens
  local sanitized
  sanitized="$(printf '%s' "$raw" | tr ' /\\$*?[]^' '-')"
  # Strip any remaining characters that aren't alphanumeric, hyphen, or underscore
  sanitized="$(printf '%s' "$sanitized" | tr -cd 'A-Za-z0-9_-')"
  # Collapse multiple consecutive hyphens into one
  sanitized="$(printf '%s' "$sanitized" | sed 's/--*/-/g')"
  # Strip leading/trailing hyphens
  sanitized="${sanitized#-}"
  sanitized="${sanitized%-}"

  if [ -z "$sanitized" ]; then
    echo "ERROR: Project name '$raw' contains only unsafe characters and cannot be sanitized." >&2
    echo "       Provide a name containing at least one alphanumeric character (e.g. 'my-project')." >&2
    exit 1
  fi

  printf '%s' "$sanitized"
}

main() {
  # Step 1: Check dependencies — always runs, even in dep-check-only mode (no project name)
  check_homebrew_deps

  local project_name="${1:-}"
  # $2: optional target directory (parent dir where project is created); defaults to $PWD
  local target_dir="${2:-$PWD}"
  # Repo URL is always the DSO NextJS template — not user-configurable via CLI args
  local repo_url="https://github.com/navapbc/digital-service-orchestra-nextjs-template"

  # Dep-check-only mode: no project name means the caller just wanted to verify deps
  if [ -z "$project_name" ]; then
    exit 0
  fi

  # Step 2: Sanitize project name
  local sanitized_name
  sanitized_name="$(sanitize_project_name "$project_name")"
  if [ "$sanitized_name" != "$project_name" ]; then
    echo "Project name sanitized: '$project_name' → '$sanitized_name'"
  fi

  local project_dir="$target_dir/$sanitized_name"

  local _skip_ack=false
  local _resume_mode=false
  if [ -e "$project_dir" ]; then
    # Idempotency: project fully initialized — exit 0 with informative message
    if [ -f "$project_dir/.dso-init-complete" ]; then
      echo "Project '$sanitized_name' is already initialized in $project_dir."
      echo "Nothing to do. To re-install, remove $project_dir and re-run."
      exit 0
    fi
    # Partial init: directory exists but installation was never completed.
    # Offer resume (continue from last completed step), start fresh, or cancel.
    echo "WARNING: Directory '$project_dir' exists but installation was not completed."
    echo "  [R] Resume installation from last completed step"
    echo "  [S] Start fresh (removes partial directory and reinstalls)"
    echo "  [C] Cancel"
    local _choice
    if ! read -r -p "Choose [R/s/C]: " _choice 2>/dev/null; then
      echo "Installation cancelled."
      exit 1
    fi
    case "$_choice" in
      r|R|"")
        echo "Resuming installation..."
        _resume_mode=true
        _skip_ack=true  # user already confirmed intent — skip the ack prompt below
        ;;
      s|S)
        echo "Removing partial directory and starting fresh..."
        rm -rf "$project_dir"
        _skip_ack=true  # user already confirmed intent — skip the ack prompt below
        ;;
      *)
        echo "Installation cancelled. Remove '$project_dir' and re-run to start fresh." >&2
        exit 1
        ;;
    esac
  fi

  echo "Creating DSO NextJS project '$sanitized_name' in $project_dir"
  echo "Template source: $repo_url"

  # User acknowledgment before installation
  # (skipped when user already confirmed start-fresh for a partial install)
  # Re-attach stdin to the terminal when invoked via "curl | bash" pipe
  # (in that form bash reads the script from stdin, so exec < /dev/tty is needed
  # to allow interactive prompts; safe no-op for all other invocation forms).
  if [ "${BASH_SOURCE[0]}" = "/dev/stdin" ] && [ -e /dev/tty ]; then
    exec < /dev/tty 2>/dev/null || true
  fi

  if [ "$_skip_ack" != "true" ]; then
    echo ""
    echo "About to install:"
    echo "  (1) DSO (digital-service-orchestra) is the Claude Code plugin that powers this project"
    echo "  (2) The installer requires permission to install the DSO plugin via Claude Code"
    echo "  (3) Steps: clone template, install npm dependencies, configure DSO, launch Claude Code"
    echo ""
    echo "Press Enter to continue or Ctrl-C to cancel."
    local _ack
    if ! read -r _ack 2>/dev/null; then
      echo ""
      echo "Installation cancelled."
      exit 1
    fi
  fi

  # Step 3: Clone template repository (--no-single-branch fetches all branches,
  # including the tickets orphan branch used by DSO).
  # Skipped in resume mode — directory already contains the prior partial clone.
  if [ "$_resume_mode" = "true" ]; then
    echo "Resuming installation (skipping clone — directory already present)..."
  else
    echo "Cloning template repository..."
    if ! git clone --no-single-branch "$repo_url" "$project_dir"; then
      echo "ERROR: git clone failed. Verify the repository URL is accessible: $repo_url" >&2
      # Clean up partial clone if it exists
      [ -d "$project_dir" ] && rm -rf "$project_dir"
      exit 1
    fi

    # Register cleanup trap for post-clone failures (Steps 4-5); cleared on success.
    # Use an inline trap body (not a named function) to avoid polluting the global namespace.
    # Not registered in resume mode — partial directory is user's existing work.
    trap '[ -d "'"$project_dir"'" ] && rm -rf "'"$project_dir"'"' EXIT
  fi

  # Step 4: Substitute {{PROJECT_NAME}} placeholder across all template files
  echo "Substituting project name in template files..."
  # Find all non-binary files and perform in-place substitution
  # Use grep -rl to find files containing the placeholder, then sed for replacement
  local files_with_placeholder
  files_with_placeholder="$(grep -rl '{{PROJECT_NAME}}' "$project_dir" 2>/dev/null || true)"

  if [ -n "$files_with_placeholder" ]; then
    while IFS= read -r file; do
      # Skip git internals
      [[ "$file" == *"/.git/"* ]] && continue
      # In-place substitution — macOS sed requires '' for -i
      if sed --version >/dev/null 2>&1; then
        # GNU sed
        sed -i "s/{{PROJECT_NAME}}/$sanitized_name/g" "$file"
      else
        # BSD/macOS sed
        sed -i '' "s/{{PROJECT_NAME}}/$sanitized_name/g" "$file"
      fi
    done <<< "$files_with_placeholder"
    echo "Template substitution complete."
  else
    echo "No {{PROJECT_NAME}} placeholders found (template may use a different convention)."
  fi

  # Step 5: Install npm dependencies
  echo "Installing npm dependencies..."
  local npm_output
  # Suppress stdout unless the command fails
  if ! npm_output="$(npm install --prefix "$project_dir" 2>&1)"; then
    echo "ERROR: npm install failed:" >&2
    echo "$npm_output" >&2
    exit 1
  fi

  # Step 5b: Detect DSO plugin root and write to project dso-config.conf
  detect_dso_plugin_root "$project_dir" >/dev/null

  # All steps succeeded — clear the cleanup trap before writing the sentinel
  trap - EXIT

  # Step 6: Write sentinel file only after all steps succeed
  printf '%s\n' "DSO NextJS project initialized successfully." > "$project_dir/.dso-init-complete"
  printf 'project_name=%s\n' "$sanitized_name" >> "$project_dir/.dso-init-complete"
  printf 'initialized_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$project_dir/.dso-init-complete"

  echo ""
  echo "DSO NextJS Starter installer — project '$sanitized_name' created successfully."
  echo "Launching Claude Code in $project_dir..."
  cd "$project_dir"
  exec claude
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
