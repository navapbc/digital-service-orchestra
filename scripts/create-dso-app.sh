#!/usr/bin/env bash
set -euo pipefail
# create-dso-app.sh — DSO NextJS Starter one-command bootstrap installer
#
# Clones the live template repo at:
#   https://github.com/navapbc/digital-service-orchestra-nextjs-template
# (public, Apache-2.0 — derived from navapbc/template-application-nextjs;
#  upstream attribution preserved in the template's NOTICE file).
#
# Interface contract: docs/designs/create-dso-app-template-contract.md
# Real-URL e2e test:  tests/scripts/test-create-dso-app-real-url.sh
#                     (opt-in via RUN_REAL_URL_E2E=1; CI-scheduled daily)
#
# Partial-download protection: all logic inside main(), invoked at end of file.

# Self-detect plugin root via BASH_SOURCE (never hardcode paths)
# bash <(curl ...) sets BASH_SOURCE[0] to /dev/stdin or /dev/fd/N (process
# substitution) — both are non-filesystem paths so _PLUGIN_ROOT derivation
# would yield /dev or /dev/fd, which is always wrong.  Guard against both
# forms: require the path to exist as a regular file on disk before accepting.
_BASH_SOURCE_0="${BASH_SOURCE[0]:-}"
if [ -n "$_BASH_SOURCE_0" ] && [ -f "$_BASH_SOURCE_0" ]; then
  _SCRIPT_DIR="$(cd "$(dirname "$_BASH_SOURCE_0")" && pwd)"
  # _PLUGIN_ROOT is parent of scripts/
  _PLUGIN_ROOT="$(dirname "$_SCRIPT_DIR")"
else
  # Invoked via curl pipe or process substitution — no BASH_SOURCE filesystem path
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
#   2. Marketplace-internal checkout: <base>/digital-service-orchestra/plugins/*/
#      (MARKETPLACE_BASE overrides <base> for test isolation)
#   2b. Channel cache: ~/.claude/plugins/cache/digital-service-orchestra/
#       (prefers `dso` stable channel; first version found within each channel)
#   3. Dev env: _PLUGIN_ROOT (resolved from BASH_SOURCE as a real filesystem file)
#   4. Auto-install via `claude plugin marketplace add` + `claude plugin install dso`
#      then re-probe priorities 2 and 2b
#   5. Fatal error — prints actionable message and exits 1
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

  # 2. Marketplace path — Claude Code lays out installed plugins under:
  #    <base>/digital-service-orchestra/plugins/<name>/.claude-plugin/plugin.json
  if [ -z "$plugin_root" ]; then
    local _marketplace_base="${_effective_marketplace_base:-$HOME/.claude/plugins/marketplaces}"
    local _mp_dir="$_marketplace_base/digital-service-orchestra/plugins"
    # Iterate every plugin sub-directory and accept the first with plugin.json
    if [ -d "$_mp_dir" ]; then
      local _candidate
      for _candidate in "$_mp_dir"/*/; do
        if [ -f "$_candidate.claude-plugin/plugin.json" ]; then
          plugin_root="${_candidate%/}"
          break
        fi
      done
    fi
  fi

  # 2b. Channel cache path — active installed channel under:
  #    ~/.claude/plugins/cache/digital-service-orchestra/<channel>/<version>/
  #    Prefer the stable `dso` channel; within each channel accept the first version
  #    returned by glob (lexicographic — works for zero-padded semver directories).
  if [ -z "$plugin_root" ]; then
    local _cache_base="$HOME/.claude/plugins/cache/digital-service-orchestra"
    local _best="" _best_channel_rank=99
    for _channel_dir in "$_cache_base"/*/; do
      [ -d "$_channel_dir" ] || continue
      local _channel
      _channel="$(basename "$_channel_dir")"
      local _rank=1
      [ "$_channel" = "dso" ] && _rank=0  # prefer stable
      for _ver_dir in "$_channel_dir"*/; do
        [ -f "$_ver_dir.claude-plugin/plugin.json" ] || continue
        # Accept this candidate if it's a better channel or first found
        if [ -z "$_best" ] || [ "$_rank" -lt "$_best_channel_rank" ]; then
          _best="${_ver_dir%/}"
          _best_channel_rank="$_rank"
        fi
      done
    done
    [ -n "$_best" ] && plugin_root="$_best"
  fi

  # 3. Dev env: _PLUGIN_ROOT resolved at script load time via BASH_SOURCE
  if [ -z "$plugin_root" ]; then
    if [ -n "${_PLUGIN_ROOT:-}" ] && \
       [ -f "$_PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
      plugin_root="$_PLUGIN_ROOT"
    fi
  fi

  # 4. Auto-install: plugin not found via any static path — invoke Claude Code
  #    plugin installer, then re-run detection (probes 2 and 2b only).
  #    Install format: `dso@<marketplace>` per `claude plugin install --help`
  #    ("use plugin@marketplace for specific marketplace").
  local _auto_install_attempted=false
  if [ -z "$plugin_root" ] && command -v claude >/dev/null 2>&1; then
    _auto_install_attempted=true
    echo "DSO plugin not found locally — installing via Claude Code marketplace..." >&2
    local _mp_name="digital-service-orchestra"
    local _mp_url="https://github.com/navapbc/digital-service-orchestra"
    # Add marketplace (idempotent — exits 0 if already present)
    claude plugin marketplace add "$_mp_url" 2>/dev/null || true
    # Install the stable dso plugin at user scope
    if claude plugin install "dso@${_mp_name}" --scope user 2>/dev/null; then
      # Re-probe marketplace-internal layout (probe 2)
      local _mp_dir2
      local _mp_base2="${_effective_marketplace_base:-$HOME/.claude/plugins/marketplaces}"
      _mp_dir2="$_mp_base2/${_mp_name}/plugins"
      if [ -d "$_mp_dir2" ]; then
        for _candidate in "$_mp_dir2"/*/; do
          if [ -f "$_candidate.claude-plugin/plugin.json" ]; then
            plugin_root="${_candidate%/}"
            break
          fi
        done
      fi
      # Re-probe cache (probe 2b) if marketplace layout not found
      if [ -z "$plugin_root" ]; then
        local _cache_base2="$HOME/.claude/plugins/cache/${_mp_name}"
        local _best2="" _best_rank2=99
        for _ch in "$_cache_base2"/*/; do
          [ -d "$_ch" ] || continue
          local _r=1; [ "$(basename "$_ch")" = "dso" ] && _r=0
          for _v in "$_ch"*/; do
            [ -f "$_v.claude-plugin/plugin.json" ] || continue
            if [ -z "$_best2" ] || [ "$_r" -lt "$_best_rank2" ]; then
              _best2="${_v%/}"; _best_rank2="$_r"
            fi
          done
        done
        [ -n "$_best2" ] && plugin_root="$_best2"
      fi
    fi
  fi

  # 5. Fatal error — static probes and auto-install both failed
  if [ -z "$plugin_root" ]; then
    if $_auto_install_attempted; then
      echo "Error: DSO plugin not found. Auto-install was attempted but failed." >&2
      echo "To install manually: claude plugin marketplace add https://github.com/navapbc/digital-service-orchestra && claude plugin install dso@digital-service-orchestra --scope user" >&2
    else
      echo "Error: DSO plugin not found. Install via Claude Code marketplace or set CLAUDE_PLUGIN_ROOT." >&2
    fi
    exit 1
  fi

  # 6. Register + enable the plugin for THIS project.
  # Filesystem presence (probes 1-3) is insufficient — Claude Code loads plugins
  # based on installed_plugins.json registry membership. Run `claude plugin install
  # --scope project` from the project dir so the fresh project gets its own enabled
  # registration. Idempotent: the CLI no-ops if already registered at project scope.
  if [ -n "$project_dir" ] && command -v claude >/dev/null 2>&1; then
    local _mp_name="digital-service-orchestra"
    local _mp_url="https://github.com/navapbc/digital-service-orchestra"
    # Ensure marketplace is known before installing (idempotent).
    claude plugin marketplace add "$_mp_url" >/dev/null 2>&1 || true
    (cd "$project_dir" && claude plugin install "dso@${_mp_name}" --scope project >/dev/null 2>&1) || true
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

  eval "$(brew shellenv)" 2>/dev/null || true

  local missing=()

  # Check bash 4+
  local bash_ver
  bash_ver=$(bash --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0")
  local bash_major="${bash_ver%%.*}"
  if [ "${bash_major:-0}" -lt 4 ]; then
    echo "Installing bash via Homebrew..."
    brew install bash || missing+=("bash")
  fi

  # Inject Homebrew bash PATH so subsequent `bash "$_setup_script"` calls
  # resolve to bash>=4, not macOS /bin/bash 3.2 (mirrors node@20 pattern).
  if brew list bash >/dev/null 2>&1; then
    local bash_prefix
    bash_prefix="$(brew --prefix bash)"
    export PATH="$bash_prefix/bin:$PATH"
  fi

  # Check git
  if ! command -v git >/dev/null 2>&1; then
    echo "Installing git via Homebrew..."
    brew install git || missing+=("git")
  fi

  # Check GNU coreutils (greadlink as proxy)
  if ! command -v greadlink >/dev/null 2>&1; then
    echo "Installing coreutils via Homebrew..."
    brew install coreutils || missing+=("coreutils")
  fi

  # Check pre-commit
  if ! command -v pre-commit >/dev/null 2>&1; then
    echo "Installing pre-commit via Homebrew..."
    brew install pre-commit || missing+=("pre-commit")
  fi

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

  # Check Python 3
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Installing python3 via Homebrew..."
    brew install python3 || missing+=("python3")
  fi

  # Check Claude Code
  if ! command -v claude >/dev/null 2>&1; then
    echo "Installing Claude Code via Homebrew..."
    brew install --cask claude-code || missing+=("claude-code (cask)")
  fi

  # Check uv (Python package manager — required by nava-platform)
  if ! command -v uv >/dev/null 2>&1; then
    echo "Installing uv via Homebrew..."
    brew install uv || missing+=("uv")
  fi

  # Check ast-grep (structural code search — used by test quality gate and CLAUDE.md search)
  if ! command -v sg >/dev/null 2>&1; then
    echo "Installing ast-grep via Homebrew..."
    brew install ast-grep || missing+=("ast-grep")
  fi

  # Check semgrep (SAST — used by test quality gate when test_quality.tool=semgrep)
  if ! command -v semgrep >/dev/null 2>&1; then
    echo "Installing semgrep via Homebrew..."
    brew install semgrep || missing+=("semgrep")
  fi

  # Check container runtime (Docker or Colima) — required for template projects
  if ! command -v docker >/dev/null 2>&1; then
    if ! command -v colima >/dev/null 2>&1; then
      echo "Installing Colima (container runtime) via Homebrew..."
      brew install colima || missing+=("colima")
    fi
    if command -v colima >/dev/null 2>&1; then
      if ! colima status 2>/dev/null | grep -q "Running"; then
        echo "Starting Colima..."
        colima start --cpu 4 --memory 8 || \
          echo "WARNING: Colima installed but could not be started automatically — run 'colima start' manually if container features are needed." >&2
      fi
    fi
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

  # No project name supplied: try to prompt interactively when a terminal is
  # available (covers `bash <(curl ...)` invocations where the script body is
  # on stdin but /dev/tty is reachable). Fall back to dep-check-only exit 0
  # with a usage hint for non-interactive / CI invocations.
  if [ -z "$project_name" ]; then
    # Reattach stdin to /dev/tty when we're not already on one — needed for
    # curl|bash pipe invocations where stdin is the script body.
    if [ ! -t 0 ] && [ -e /dev/tty ]; then
      exec < /dev/tty 2>/dev/null || true
    fi

    if [ -t 0 ]; then
      # Interactive: prompt for a project name
      printf 'Project name: ' >&2
      if ! read -r project_name; then
        echo "" >&2
        echo "No project name provided. Exiting." >&2
        exit 1
      fi
      if [ -z "$project_name" ]; then
        echo "No project name provided. Exiting." >&2
        exit 1
      fi
    else
      # Non-interactive (CI / no tty): print usage hint and exit 0 for
      # backward-compatible dep-check-only behavior.
      echo "" >&2
      echo "No project name supplied — dep-check-only mode." >&2
      echo "To scaffold a project, re-run with a <project-name> argument, e.g.:" >&2
      echo "  bash <(curl -fsSL https://raw.githubusercontent.com/navapbc/digital-service-orchestra/HEAD/scripts/create-dso-app.sh) my-project" >&2
      exit 0
    fi
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
  local resolved_plugin_root
  resolved_plugin_root=$(detect_dso_plugin_root "$project_dir")

  # Step 5b.5: Run project detection so dso-setup can analyze CI guard coverage
  # against the freshly cloned template (populates DSO_DETECT_OUTPUT contract).
  # Uses a path under project_dir rather than mktemp so it works under restricted
  # PATH environments (e.g., test stubs) that may not have /usr/bin/mktemp.
  local _detect_output=""
  local _detect_script="$resolved_plugin_root/scripts/project-detect.sh"
  if [[ -x "$_detect_script" ]] && [[ -d "$project_dir" ]]; then
    _detect_output="$project_dir/.dso-detect-output.tmp"
    "$_detect_script" "$project_dir" > "$_detect_output" 2>/dev/null || : > "$_detect_output"
    export DSO_DETECT_OUTPUT="$_detect_output"
  fi

  # Step 5c: Configure project with DSO defaults (shim, CLAUDE.md, hooks)
  local _setup_script="$resolved_plugin_root/scripts/dso-setup.sh"
  if [[ -f "$_setup_script" ]]; then
    echo "Configuring project with DSO defaults..."
    bash "$_setup_script" "$project_dir" "$resolved_plugin_root" \
      || echo "WARNING: DSO project setup encountered issues — run '.claude/scripts/dso validate.sh' manually if needed." >&2
  fi

  # Step 5c.5: Shim fallback — if dso-setup.sh failed or was absent, install the
  # shim directly so .claude/scripts/dso is always present after install.
  # (Bug 14f9-060b: a failing dso-setup.sh left the shim missing even though
  # create-dso-app.sh reported success and wrote the sentinel.)
  if [[ ! -f "$project_dir/.claude/scripts/dso" ]]; then
    local _shim_template="$resolved_plugin_root/templates/host-project/dso"
    if [[ -f "$_shim_template" ]]; then
      mkdir -p "$project_dir/.claude/scripts"
      cp "$_shim_template" "$project_dir/.claude/scripts/dso"
      chmod +x "$project_dir/.claude/scripts/dso"
      echo "Installed DSO shim directly from plugin template."
    else
      echo "WARNING: DSO shim template not found at $resolved_plugin_root/templates/host-project/dso — .claude/scripts/dso not installed." >&2
    fi
  fi

  # Clean up detection output after dso-setup consumed it
  [[ -n "$_detect_output" && -f "$_detect_output" ]] && rm -f "$_detect_output"

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
