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
    export PATH="$(brew --prefix node@20)/bin:$PATH"
  fi

  # Check Claude Code
  if ! command -v claude >/dev/null 2>&1; then
    echo "Installing Claude Code via Homebrew..."
    brew install --cask claude-code || missing+=("claude-code (cask)")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo "Prerequisites not met — install the following and re-run:"
    for pkg in "${missing[@]}"; do
      echo "  Run: brew install $pkg"
    done
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

  if [ -e "$project_dir" ]; then
    echo "ERROR: Directory '$project_dir' already exists. Choose a different project name or remove the existing directory." >&2
    exit 1
  fi

  echo "Creating DSO NextJS project '$sanitized_name' in $project_dir"
  echo "Template source: $repo_url"

  # Step 3: Clone template repository (--no-single-branch fetches all branches,
  # including the tickets orphan branch used by DSO)
  echo "Cloning template repository..."
  if ! git clone --no-single-branch "$repo_url" "$project_dir"; then
    echo "ERROR: git clone failed. Verify the repository URL is accessible: $repo_url" >&2
    # Clean up partial clone if it exists
    [ -d "$project_dir" ] && rm -rf "$project_dir"
    exit 1
  fi

  # Register cleanup trap for post-clone failures (Steps 4-5); cleared on success.
  # Use an inline trap body (not a named function) to avoid polluting the global namespace.
  trap '[ -d "'"$project_dir"'" ] && rm -rf "'"$project_dir"'"' EXIT

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

  # All steps succeeded — clear the cleanup trap before writing the sentinel
  trap - EXIT

  # Step 6: Write sentinel file only after all steps succeed
  printf '%s\n' "DSO NextJS project initialized successfully." > "$project_dir/.dso-init-complete"
  printf 'project_name=%s\n' "$sanitized_name" >> "$project_dir/.dso-init-complete"
  printf 'initialized_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$project_dir/.dso-init-complete"

  echo ""
  echo "DSO NextJS Starter installer — project '$sanitized_name' created successfully."
  echo "Next steps:"
  echo "  cd $project_dir"
  echo "  claude"
}

main "$@"
