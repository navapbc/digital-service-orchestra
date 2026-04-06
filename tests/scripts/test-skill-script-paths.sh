#!/usr/bin/env bash
# tests/scripts/test-skill-script-paths.sh
# Validates that skill files reference plugin scripts via the DSO shim
# (.claude/scripts/dso <script>) rather than hardcoded paths that break
# in consuming projects.
#
# Bad patterns (will fail in consuming projects):
#   $(git rev-parse --show-toplevel)/scripts/<script>    — scripts/ doesn't exist at repo root
#   $REPO_ROOT/plugins/dso/scripts/<script>              — only works inside the plugin repo itself
#   "$REPO_ROOT/plugins/dso/scripts/<script>"            — same, with quotes
#
# Good pattern:
#   .claude/scripts/dso <script>                          — portable DSO shim
#   $PLUGIN_SCRIPTS/<script>                              — resolved at skill activation
#
# Usage: bash tests/scripts/test-skill-script-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-skill-script-paths.sh ==="

# ── Scope: files that Claude reads as instructions ──────────────────────────
# These are the files that contain Bash invocation patterns Claude follows.
# skills/, agents/, docs/, prompts/ — all .md files under the plugin directory.
SCAN_DIRS=(
    "$DSO_PLUGIN_DIR/skills"
    "$DSO_PLUGIN_DIR/docs"
    "$DSO_PLUGIN_DIR/agents"
)
# Exclude known installation/migration docs and developer reference docs where
# hardcoded paths are intentional (commands meant to be run from the plugin repo root).
EXCLUDE_PATTERNS="MIGRATION-TO-PLUGIN.md|INSTALL.md|SKILL-EVALS-GUIDE.md|overlay-calibration-baselines.md"

# ── Helper: scan dirs for a grep pattern, excluding known exceptions ─────────
_scan_for_bad_pattern() {
    local pattern="$1"
    local results=""
    for dir in "${SCAN_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            local matches
            matches=$(grep -rn "$pattern" "$dir" --include='*.md' 2>/dev/null | grep -vE "$EXCLUDE_PATTERNS" || true)
            if [ -n "$matches" ]; then
                results="${results}${matches}"$'\n'
            fi
        fi
    done
    echo "$results"
}

# ── Pattern 1: $(git rev-parse --show-toplevel)/scripts/ ────────────────────
# This path doesn't exist. There is no scripts/ directory at the repo root.
# The actual scripts are inside the plugin at plugins/dso/scripts/.
echo "Test 1: No \$(git rev-parse --show-toplevel)/scripts/ references"
bad_git_rev_parse=$(_scan_for_bad_pattern 'git rev-parse --show-toplevel)/scripts/')

if [ -z "$bad_git_rev_parse" ]; then
    echo "  PASS: no \$(git rev-parse)/scripts/ references found"
    (( PASS++ ))
else
    count=$(echo "$bad_git_rev_parse" | grep -c '.' || true)
    echo "  FAIL: found $count references to non-existent \$(git rev-parse)/scripts/ path:" >&2
    echo "$bad_git_rev_parse" | head -10 >&2
    (( FAIL++ ))
fi

# ── Pattern 2: $REPO_ROOT/plugins/dso/scripts/ ─────────────────────────────
# This only works inside the plugin repo itself. In consuming projects,
# the plugin is installed at ~/.claude/plugins/marketplaces/<name>/ and
# $REPO_ROOT/plugins/dso/ doesn't exist.
echo "Test 2: No \$REPO_ROOT/plugins/dso/scripts/ references"
bad_repo_root=$(_scan_for_bad_pattern '\$REPO_ROOT/plugins/dso/scripts/')

if [ -z "$bad_repo_root" ]; then
    echo "  PASS: no \$REPO_ROOT/plugins/dso/scripts/ references found"
    (( PASS++ ))
else
    count=$(echo "$bad_repo_root" | grep -c '.' || true)
    echo "  FAIL: found $count references to non-portable \$REPO_ROOT/plugins/dso/scripts/ path:" >&2
    echo "$bad_repo_root" | head -10 >&2
    (( FAIL++ ))
fi

# ── Pattern 3: $(git rev-parse --show-toplevel)/plugins/dso/scripts/ ────────
# Variant of pattern 2 using git rev-parse instead of $REPO_ROOT.
echo "Test 3: No \$(git rev-parse)/plugins/dso/scripts/ references"
bad_git_plugin=$(_scan_for_bad_pattern 'git rev-parse --show-toplevel)/plugins/dso/scripts/')

if [ -z "$bad_git_plugin" ]; then
    echo "  PASS: no \$(git rev-parse)/plugins/dso/scripts/ references found"
    (( PASS++ ))
else
    count=$(echo "$bad_git_plugin" | grep -c '.' || true)
    echo "  FAIL: found $count references to non-portable \$(git rev-parse)/plugins/dso/scripts/ path:" >&2
    echo "$bad_git_plugin" | head -10 >&2
    (( FAIL++ ))
fi

# ── Pattern 4: bash plugins/dso/scripts/ (relative hardcoded path) ──────────
# Only works when CWD is the plugin repo root. Fails in consuming projects.
echo "Test 4: No relative 'bash plugins/dso/scripts/' references"
bad_relative=$(_scan_for_bad_pattern 'bash plugins/dso/scripts/')

if [ -z "$bad_relative" ]; then
    echo "  PASS: no relative bash plugins/dso/scripts/ references found"
    (( PASS++ ))
else
    count=$(echo "$bad_relative" | grep -c '.' || true)
    echo "  FAIL: found $count relative bash plugins/dso/scripts/ references:" >&2
    echo "$bad_relative" | head -10 >&2
    (( FAIL++ ))
fi

# ── Pattern 5: Verify that .claude/scripts/dso shim or $PLUGIN_SCRIPTS is used ─
# At least one reference to the correct invocation pattern should exist in
# the sprint skill (the primary orchestrator).
echo "Test 5: Sprint skill uses .claude/scripts/dso shim or \$PLUGIN_SCRIPTS for script invocation"
sprint_skill="$DSO_PLUGIN_DIR/skills/sprint/SKILL.md"
if [ ! -f "$sprint_skill" ]; then
    echo "  FAIL: sprint SKILL.md not found at $sprint_skill" >&2
    (( FAIL++ ))
else
    good_shim=$(grep -c '\.claude/scripts/dso ' "$sprint_skill" 2>/dev/null || echo "0")
    good_plugin=$(grep -c '\$PLUGIN_SCRIPTS/' "$sprint_skill" 2>/dev/null || echo "0")
    total_good=$(( good_shim + good_plugin ))
    if [ "$total_good" -gt 5 ]; then
        echo "  PASS: sprint skill has $total_good references to portable script paths"
        (( PASS++ ))
    else
        echo "  FAIL: sprint skill has only $total_good portable script references (expected >5)" >&2
        (( FAIL++ ))
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
