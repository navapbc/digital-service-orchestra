#!/usr/bin/env bash
set -euo pipefail
# scripts/verify-baseline-intent.sh
#
# Pre-merge check: verifies that visual baseline changes are intentional
# by confirming the presence of design manifests on the branch.
#
# Distinct from check-visual-baselines.sh (which checks completeness).
# This script checks INTENT — were baseline changes accompanied by a design?
#
# Exit codes:
#   0 = OK (no baseline changes, or changes with design manifests, or no config)
#   1 = Error (script failure)
#   2 = Unintended changes (baselines changed without design manifests)
#
# Usage: scripts/verify-baseline-intent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"

# --- Read config-driven paths ---
BASELINE_DIR=$(bash "$SCRIPT_DIR/read-config.sh" visual.baseline_directory 2>/dev/null || true)

if [ -z "$BASELINE_DIR" ]; then
    echo "INFO: visual.baseline_directory not configured -- no visual baselines to verify."
    exit 0
fi

# Read manifest patterns as array (one per line)
MANIFEST_PATTERNS=()
if manifest_raw=$(bash "$SCRIPT_DIR/read-config.sh" --list design.manifest_patterns 2>/dev/null); then
    while IFS= read -r pattern; do
        [ -n "$pattern" ] && MANIFEST_PATTERNS+=("$pattern")
    done <<< "$manifest_raw"
fi

# --- 1. Check for changed baselines originated on this branch ---
# Use merge-base against origin/main (not local main) to distinguish branch-originated
# vs main-originated changes. This script is called after the worktree has been synced
# with origin/main but before local main is fast-forwarded. Using local main as the
# reference would set the merge-base too early, incorrectly treating CI baseline update
# commits pulled in from origin/main as branch-originated changes (false positive).
MERGE_BASE=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || git rev-parse HEAD)
CHANGED_BASELINES=$(git diff --name-only "$MERGE_BASE" HEAD -- "$BASELINE_DIR" 2>/dev/null | grep '\.png$' || true)

if [ -z "$CHANGED_BASELINES" ]; then
    echo "OK: No visual baseline changes on this branch."
    exit 0
fi

# --- 2. Check for design manifests added on this branch ---
# Build the git diff arguments from the config-driven patterns array
if [ ${#MANIFEST_PATTERNS[@]} -gt 0 ]; then
    DESIGN_MANIFESTS=$(git diff "$MERGE_BASE" HEAD --name-only -- "${MANIFEST_PATTERNS[@]}" 2>/dev/null || true)
else
    DESIGN_MANIFESTS=""
fi

# --- 3. Evaluate intent ---
if [ -n "$DESIGN_MANIFESTS" ]; then
    echo "OK: Visual baseline changes accompanied by design manifests."
    echo ""
    echo "Changed baselines:"
    echo "$CHANGED_BASELINES" | while IFS= read -r f; do echo "  - $f"; done
    echo ""
    echo "Design manifests:"
    echo "$DESIGN_MANIFESTS" | while IFS= read -r f; do echo "  - $f"; done
    exit 0
fi

# --- 4. Baselines changed but no design manifests ---
echo "WARNING: Visual baseline changes detected WITHOUT design manifests."
echo ""
echo "Changed baselines:"
echo "$CHANGED_BASELINES" | while IFS= read -r f; do echo "  - $f"; done
echo ""
echo "This may indicate an unintended visual regression."
echo "See .claude/docs/VISUAL-BASELINES.md for the debug flow."
exit 2
