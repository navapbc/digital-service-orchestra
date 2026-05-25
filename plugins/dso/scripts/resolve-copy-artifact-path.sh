#!/usr/bin/env bash
# resolve-copy-artifact-path.sh — Resolve the gov-copy-writer artifact output path.
#
# Reads copy.artifact_dir from dso-config.conf (default: "copy/") and invokes
# copy_artifact_path.py to validate and resolve the absolute artifact path for a
# given epic ID.
#
# Usage:
#   bash resolve-copy-artifact-path.sh <epic_id> [--project-root <root>]
#
# Outputs:
#   Prints the resolved absolute path to stdout on success (exit 0).
#   Prints an error message to stderr and exits non-zero on validation failure.
#
# Environment:
#   WORKFLOW_CONFIG_FILE — override config file path (used by tests for isolation)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") <epic_id> [--project-root <root>]" >&2
    exit 1
fi

EPIC_ID="$1"
shift

PROJECT_ROOT="."
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root)
            PROJECT_ROOT="${2:?'--project-root requires a value'}"
            shift 2
            ;;
        --project-root=*)
            PROJECT_ROOT="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Read copy.artifact_dir from config ───────────────────────────────────────

ARTIFACT_DIR=$(bash "$SCRIPT_DIR/read-config.sh" copy.artifact_dir 2>/dev/null || true)

# Apply default when the key is absent or empty
if [[ -z "$ARTIFACT_DIR" ]]; then
    ARTIFACT_DIR="copy/"
fi

# ── Delegate to copy_artifact_path.py for validation and resolution ──────────

python3 "$SCRIPT_DIR/copy_artifact_path.py" \
    "$ARTIFACT_DIR" \
    "$EPIC_ID" \
    --project-root "$PROJECT_ROOT"
