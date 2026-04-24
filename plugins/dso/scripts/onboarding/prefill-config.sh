#!/usr/bin/env bash
set -uo pipefail
# scripts/prefill-config.sh
# Stack-aware config pre-fill for dso-config.conf.
#
# Reads the project stack via detect-stack.sh and writes per-stack defaults for
# the four commands.* keys into the active dso-config.conf (or WORKFLOW_CONFIG_FILE).
# Keys that already have a non-empty value are skipped with an informational message.
# Stacks without defined defaults (Rust, Go, convention-based, unknown) write
# empty values with an inline comment.
#
# Usage: prefill-config.sh [--project-dir <dir>]
#   --project-dir <dir>  Directory to scan for stack markers (default: $PWD)
#
# Config file resolved via:
#   1. $WORKFLOW_CONFIG_FILE (test isolation)
#   2. $(git rev-parse --show-toplevel)/.claude/dso-config.conf
#
# Exit codes:
#   0 — success (all keys written or skipped)
#   1 — usage error

# ── Resolve plugin root (no hardcoded plugin path) ───────────────────────────
_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_SCRIPTS="$_PLUGIN_ROOT/scripts"

# ── Argument parsing ──────────────────────────────────────────────────────────
PROJECT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="${2:-}"
            shift 2
            ;;
        --project-dir=*)
            PROJECT_DIR="${1#--project-dir=}"
            shift
            ;;
        -h|--help)
            echo "Usage: prefill-config.sh [--project-dir <dir>]"
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(pwd)"
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: not a directory: $PROJECT_DIR" >&2
    exit 1
fi

# ── Resolve config file ───────────────────────────────────────────────────────
if [[ -n "${WORKFLOW_CONFIG_FILE:-}" ]]; then
    CONFIG_FILE="$WORKFLOW_CONFIG_FILE"
else
    _git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$_git_root" && -f "$_git_root/.claude/dso-config.conf" ]]; then
        CONFIG_FILE="$_git_root/.claude/dso-config.conf"
    else
        echo "[DSO ERROR] Could not resolve dso-config.conf — set WORKFLOW_CONFIG_FILE or run from a git repo" >&2
        exit 1
    fi
fi

# Ensure config file exists (create empty if needed)
if [[ ! -f "$CONFIG_FILE" ]]; then
    touch "$CONFIG_FILE"
fi

# ── Detect stack ──────────────────────────────────────────────────────────────
DETECT_SCRIPT="$PLUGIN_SCRIPTS/detect-stack.sh"

if [[ ! -x "$DETECT_SCRIPT" ]]; then
    echo "[DSO ERROR] detect-stack.sh not found or not executable: $DETECT_SCRIPT" >&2
    exit 1
fi

STACK=$(bash "$DETECT_SCRIPT" "$PROJECT_DIR")

# ── Per-stack defaults ────────────────────────────────────────────────────────
# Associative arrays: key → default value for each stack
declare -A DEFAULTS_TEST_RUNNER
declare -A DEFAULTS_LINT
declare -A DEFAULTS_FORMAT
declare -A DEFAULTS_FORMAT_CHECK

DEFAULTS_TEST_RUNNER["python-poetry"]="pytest"
DEFAULTS_LINT["python-poetry"]="ruff check ."
DEFAULTS_FORMAT["python-poetry"]="ruff format ."
DEFAULTS_FORMAT_CHECK["python-poetry"]="ruff format --check ."

DEFAULTS_TEST_RUNNER["node-npm"]="npx jest"
DEFAULTS_LINT["node-npm"]="npx eslint ."
DEFAULTS_FORMAT["node-npm"]="npx prettier --write ."
DEFAULTS_FORMAT_CHECK["node-npm"]="npx prettier --check ."

DEFAULTS_TEST_RUNNER["ruby-rails"]="bundle exec rspec"
DEFAULTS_LINT["ruby-rails"]="bundle exec rubocop"
DEFAULTS_FORMAT["ruby-rails"]="bundle exec rubocop -A"
DEFAULTS_FORMAT_CHECK["ruby-rails"]="bundle exec rubocop --format simple"

DEFAULTS_TEST_RUNNER["ruby-jekyll"]="bundle exec rspec"
DEFAULTS_LINT["ruby-jekyll"]="bundle exec rubocop"
DEFAULTS_FORMAT["ruby-jekyll"]="bundle exec rubocop -A"
DEFAULTS_FORMAT_CHECK["ruby-jekyll"]="bundle exec rubocop --format simple"

# Keys without defaults get empty string (rust-cargo, golang, convention-based, unknown)

# ── Helper: read existing value for a key ─────────────────────────────────────
_read_existing() {
    local key="$1"
    grep -m1 "^${key}=" "$CONFIG_FILE" | cut -d= -f2- 2>/dev/null || true
}

# ── Helper: write or skip a single config key ─────────────────────────────────
_write_key() {
    local key="$1"
    local default_val="$2"
    local existing
    existing="$(_read_existing "$key")"

    if [[ -n "$existing" ]]; then
        echo "[DSO INFO] commands.${key#commands.} already set — skipping"
        return
    fi

    if [[ -z "$default_val" ]]; then
        # No default for this stack — write comment followed by empty value
        printf '# no default defined for %s\n%s=\n' "$STACK" "$key" >> "$CONFIG_FILE"
    else
        echo "${key}=${default_val}" >> "$CONFIG_FILE"
    fi
}

# ── Resolve defaults for detected stack ──────────────────────────────────────
VAL_TEST_RUNNER="${DEFAULTS_TEST_RUNNER[$STACK]:-}"
VAL_LINT="${DEFAULTS_LINT[$STACK]:-}"
VAL_FORMAT="${DEFAULTS_FORMAT[$STACK]:-}"
VAL_FORMAT_CHECK="${DEFAULTS_FORMAT_CHECK[$STACK]:-}"

# ── Write each key ────────────────────────────────────────────────────────────
_write_key "commands.test_runner"  "$VAL_TEST_RUNNER"
_write_key "commands.lint"         "$VAL_LINT"
_write_key "commands.format"       "$VAL_FORMAT"
_write_key "commands.format_check" "$VAL_FORMAT_CHECK"

echo "[DSO INFO] prefill-config: stack=${STACK}, config=${CONFIG_FILE}"
