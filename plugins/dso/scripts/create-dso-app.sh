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

main() {
  check_homebrew_deps
  echo "DSO NextJS Starter installer — dependencies checked successfully."
}

main "$@"
