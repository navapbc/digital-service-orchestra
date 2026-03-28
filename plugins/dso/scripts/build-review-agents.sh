#!/usr/bin/env bash
# plugins/dso/scripts/build-review-agents.sh
#
# Composes reviewer-base.md + per-agent delta files into generated code-reviewer
# agent definitions in plugins/dso/agents/.
#
# Usage:
#   bash build-review-agents.sh [--base PATH] [--deltas DIR] [--output DIR] [--expect-count N]
#
# Options:
#   --base PATH         Path to reviewer-base.md (default: auto-detected from plugin dir)
#   --deltas DIR        Directory containing reviewer-delta-*.md files (default: auto-detected)
#   --output DIR        Output directory for generated agent files (default: plugins/dso/agents/)
#   --expect-count N    Expected number of delta files; exit non-zero if mismatch (optional)
#
# HASH_ALGORITHM: sha256 of (base_content + "\n" + delta_content)
#   Concatenation order: base file content first, then a newline separator, then delta file content.
#   This allows the staleness check (T7) to reproduce the hash exactly.
#   On macOS: uses shasum -a 256; on Linux: uses sha256sum.
#
# Atomic write: all agent files are generated in a temp directory first. Only on full success
# are the files moved to the output directory. On any failure, no output files are modified.

set -euo pipefail

# ── Portable sha256 wrapper ──────────────────────────────────────────────────
_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 | awk '{print $1}'
    else
        echo "ERROR: no sha256sum or shasum available" >&2
        return 1
    fi
}

# ── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"

BASE_FILE=""
DELTAS_DIR=""
OUTPUT_DIR=""
EXPECT_COUNT=""

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)
            BASE_FILE="$2"
            shift 2
            ;;
        --deltas)
            DELTAS_DIR="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --expect-count)
            EXPECT_COUNT="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Apply defaults
: "${BASE_FILE:=$DSO_PLUGIN_DIR/docs/workflows/prompts/reviewer-base.md}"
: "${DELTAS_DIR:=$DSO_PLUGIN_DIR/docs/workflows/prompts}"
: "${OUTPUT_DIR:=$DSO_PLUGIN_DIR/agents}"

# ── Validate inputs ─────────────────────────────────────────────────────────
if [[ ! -f "$BASE_FILE" ]]; then
    echo "ERROR: base file not found: $BASE_FILE" >&2
    exit 1
fi

# Discover delta files
mapfile -t DELTA_FILES < <(find "$DELTAS_DIR" -maxdepth 1 -name 'reviewer-delta-*.md' -type f | sort)

if [[ ${#DELTA_FILES[@]} -eq 0 ]]; then
    echo "ERROR: no reviewer-delta-*.md files found in: $DELTAS_DIR" >&2
    exit 1
fi

# Check expected count if provided
if [[ -n "$EXPECT_COUNT" && "${#DELTA_FILES[@]}" -ne "$EXPECT_COUNT" ]]; then
    echo "ERROR: expected $EXPECT_COUNT delta files, found ${#DELTA_FILES[@]}" >&2
    exit 1
fi

# ── Model mapping ───────────────────────────────────────────────────────────
_model_for_tier() {
    case "$1" in
        light)              echo "haiku" ;;
        standard)           echo "sonnet" ;;
        deep-correctness)   echo "sonnet" ;;
        deep-verification)  echo "sonnet" ;;
        deep-hygiene)       echo "sonnet" ;;
        deep-arch)          echo "opus" ;;
        security-red-team)  echo "opus" ;;
        security-blue-team) echo "opus" ;;
        performance)        echo "opus" ;;
        *)
            echo "ERROR: unknown tier: $1" >&2
            return 1
            ;;
    esac
}

_description_for_tier() {
    case "$1" in
        light)              echo "Light-tier code reviewer: single-pass, highest-signal checklist for fast feedback on low-to-medium-risk changes." ;;
        standard)           echo "Standard-tier code reviewer: comprehensive review across all five scoring dimensions for moderate-to-high-risk changes." ;;
        deep-correctness)   echo "Deep-tier correctness specialist (Sonnet A): focused exclusively on correctness — edge cases, error handling, security, efficiency." ;;
        deep-verification)  echo "Deep-tier verification specialist (Sonnet B): focused exclusively on verification — test presence, quality, edge case coverage, mock correctness." ;;
        deep-hygiene)       echo "Deep-tier hygiene/design specialist (Sonnet C): focused on hygiene, design, and maintainability." ;;
        deep-arch)          echo "Deep-tier architectural reviewer (Opus): synthesizes specialist findings, assesses systemic risk, produces unified verdict across all dimensions." ;;
        security-red-team)  echo "Security red team reviewer (Opus): aggressive security detection without ticket context for AI-advantaged security concerns." ;;
        security-blue-team) echo "Security blue team reviewer (Opus): context-aware triage of red team findings with dismiss/downgrade/sustain authority." ;;
        performance)        echo "Performance reviewer (Opus): calibrated performance analysis with bright-line severity rules for scaling failures and resource exhaustion." ;;
        *)
            echo "ERROR: unknown tier: $1" >&2
            return 1
            ;;
    esac
}

# ── Read base content once ───────────────────────────────────────────────────
BASE_CONTENT="$(cat "$BASE_FILE")"

# ── Atomic write: generate all files in temp dir ─────────────────────────────
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

for delta_file in "${DELTA_FILES[@]}"; do
    # Extract tier name from filename: reviewer-delta-<tier>.md
    basename_f="$(basename "$delta_file")"
    tier="${basename_f#reviewer-delta-}"
    tier="${tier%.md}"

    # Get model and description
    model="$(_model_for_tier "$tier")" || exit 1
    description="$(_description_for_tier "$tier")" || exit 1

    # Read delta content
    delta_content="$(cat "$delta_file")"

    # Compute content hash: sha256(base_content + "\n" + delta_content)
    # content-hash: concatenation order is base content + newline + delta content
    content_hash=$(printf '%s\n%s' "$BASE_CONTENT" "$delta_content" | _sha256)

    # Agent output filename
    agent_filename="code-reviewer-${tier}.md"

    # Compose the agent file
    cat > "$TEMP_DIR/$agent_filename" <<AGENT
---
name: code-reviewer-${tier}
model: ${model}
description: ${description}
---
<!-- content-hash: ${content_hash} -->
<!-- generated by build-review-agents.sh — do not edit manually -->

${BASE_CONTENT}

${delta_content}
AGENT
done

# ── Verify all files were generated ──────────────────────────────────────────
generated_count=$(find "$TEMP_DIR" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
if [[ "$generated_count" -ne "${#DELTA_FILES[@]}" ]]; then
    echo "ERROR: expected ${#DELTA_FILES[@]} generated files, got $generated_count" >&2
    exit 1
fi

# ── Move generated files to output dir (atomic swap) ─────────────────────────
mkdir -p "$OUTPUT_DIR"
for file in "$TEMP_DIR"/*.md; do
    cp "$file" "$OUTPUT_DIR/$(basename "$file")"
done

echo "Generated $generated_count agent files in $OUTPUT_DIR"
