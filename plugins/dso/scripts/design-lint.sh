#!/usr/bin/env bash
# scripts/design-lint.sh
# Audit command wrapper for @google/design.md CLI.
#
# Runs full-file lint on the project's DESIGN.md (not diff-only).
# Companion to design-md-lint.sh (which is diff-scoped for pre-commit hooks).
#
# Pinned version: 0.2.0 (see ${CLAUDE_PLUGIN_ROOT}/docs/DESIGN-MD-REFERENCE.md)
#
# CRITICAL: @google/design.md lint exits 0 regardless of findings.
# Parse JSON output summary.errors/warnings/infos for violation counts.
#
# Fail-open conditions (exit 0, skip lint):
#   - npx not available
#   - DESIGN.md not present at the configured path
#
# Usage:
#   dso design-lint [--report] [--help]
#   dso design-lint [--report] [--help]
#
# Flags:
#   --report    Parse linter JSON output and emit per-violation-class count to stdout
#   --help      Print usage and exit 0
#
# Environment overrides (for testing):
#   DSO_CONFIG_PATH        — path to dso-config.conf
#   DESIGN_MD_VERSION      — override pinned @google/design.md version
#   DESIGN_MD_NOTES_PATH   — override design.design_notes_path config key

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"

# ── --help flag ───────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat << 'USAGE'
Usage: dso design-lint [--report] [--help]

Runs @google/design.md lint against the full DESIGN.md file.

Flags:
  --report    Parse JSON output and emit per-violation-class counts to stdout.
              Outputs lines like:
                errors: N
                warnings: N
                infos: N
              Always exits 0 when lint runs successfully. Exits 0 (fail-open)
              when DESIGN.md is absent or npx is unavailable.

  --help      Print this usage and exit 0.

Without flags: passes through to the underlying @google/design.md lint CLI,
outputting raw JSON from the linter to stdout.

Configuration:
  design.design_notes_path — path to DESIGN.md (default: DESIGN.md)
  DESIGN_MD_NOTES_PATH     — env override for the design file path
  DESIGN_MD_VERSION        — env override for the @google/design.md version (default: 0.2.0)

See DESIGN-MD-REFERENCE.md in the DSO plugin docs directory for full documentation.
USAGE
    exit 0
fi

# ── Parse flags ───────────────────────────────────────────────────────────────
REPORT_MODE=0
PASSTHROUGH_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --report)
            REPORT_MODE=1
            ;;
        *)
            PASSTHROUGH_ARGS+=("$arg")
            ;;
    esac
done

# ── Fail-open: npx not available ─────────────────────────────────────────────
if ! command -v npx >/dev/null 2>&1; then
    echo "INFO: npx not available — skipping design-lint (fail-open)." >&2
    exit 0
fi

# ── Config resolution ─────────────────────────────────────────────────────────
CONFIG_FILE="${DSO_CONFIG_PATH:-${REPO_ROOT:+$REPO_ROOT/.claude/dso-config.conf}}"

# ── Resolve DESIGN.md path ────────────────────────────────────────────────────
if [[ -n "${DESIGN_MD_NOTES_PATH:-}" ]]; then
    DESIGN_NOTES_PATH="$DESIGN_MD_NOTES_PATH"
elif [[ -n "${CONFIG_FILE:-}" && -f "${CONFIG_FILE:-}" ]]; then
    _cfg_path=$(bash "$SCRIPT_DIR/read-config.sh" design.design_notes_path "$CONFIG_FILE" 2>/dev/null || true)
    DESIGN_NOTES_PATH="${_cfg_path:-DESIGN.md}"
else
    DESIGN_NOTES_PATH="DESIGN.md"
fi

# Resolve to absolute path (relative to repo root)
if [[ "$DESIGN_NOTES_PATH" != /* ]]; then
    if [[ -n "${REPO_ROOT:-}" ]]; then
        DESIGN_NOTES_PATH="$REPO_ROOT/$DESIGN_NOTES_PATH"
    else
        DESIGN_NOTES_PATH="$(pwd)/$DESIGN_NOTES_PATH"
    fi
fi

# ── Fail-open: DESIGN.md not present ─────────────────────────────────────────
if [[ ! -f "$DESIGN_NOTES_PATH" ]]; then
    echo "INFO: Design notes file not found at '$DESIGN_NOTES_PATH' — skipping design-lint (fail-open)." >&2
    exit 0
fi

# ── Resolve pinned version ────────────────────────────────────────────────────
DESIGN_MD_VERSION="${DESIGN_MD_VERSION:-0.2.0}"

# ── Run @google/design.md lint ────────────────────────────────────────────────
# @google/design.md lint exits 0 regardless of findings — parse JSON for counts.
lint_output=""
lint_exit=0
lint_output=$(
    npx --yes "@google/design.md@${DESIGN_MD_VERSION}" lint \
        --format json \
        "$DESIGN_NOTES_PATH" 2>/dev/null
) || lint_exit=$?

if [[ $lint_exit -ne 0 ]]; then
    echo "ERROR: @google/design.md lint invocation failed (exit $lint_exit) for '$DESIGN_NOTES_PATH'" >&2
    # Fail-open: do not block caller on npx failure
    exit 0
fi

# ── --report mode: emit per-violation-class counts ───────────────────────────
if [[ "$REPORT_MODE" -eq 1 ]]; then
    if [[ -z "$lint_output" ]]; then
        echo "errors: 0"
        echo "warnings: 0"
        echo "infos: 0"
        exit 0
    fi

    # Extract counts from JSON summary field.
    # Expected shape: {"findings":[...],"summary":{"errors":N,"warnings":N,"infos":N}}
    # Use grep+sed as a lightweight parser (no jq dependency required).
    _errors=0
    _warnings=0
    _infos=0

    if echo "$lint_output" | grep -q '"summary"'; then
        _raw_errors=$(echo "$lint_output" | grep -o '"errors"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$' | head -1)
        _raw_warnings=$(echo "$lint_output" | grep -o '"warnings"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$' | head -1)
        _raw_infos=$(echo "$lint_output" | grep -o '"infos"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$' | head -1)
        _errors="${_raw_errors:-0}"
        _warnings="${_raw_warnings:-0}"
        _infos="${_raw_infos:-0}"
    fi

    echo "errors: $_errors"
    echo "warnings: $_warnings"
    echo "infos: $_infos"
    exit 0
fi

# ── Passthrough mode: output raw linter JSON ──────────────────────────────────
printf '%s\n' "$lint_output"
exit 0
