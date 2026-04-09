#!/usr/bin/env bash
# tests/skills/run-python-tests.sh
# Runs all Python test files under tests/skills/ and tests/docs/ using pytest.
#
# RED-phase tests (classes/functions listed in .test-index with [Marker] suffixes)
# are excluded via -k so they do not block CI while their implementation is pending.
#
# Pre-existing failures tracked in .test-index are also excluded until they have
# dedicated fix stories. They are listed in the KNOWN_FAILING array below and
# excluded by name to avoid masking new regressions.
#
# Usage: bash tests/skills/run-python-tests.sh
# Returns: exit 0 if all non-RED / non-known-failing tests pass, exit 1 otherwise

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
DOCS_DIR="$REPO_ROOT/tests/docs"
TEST_INDEX="$REPO_ROOT/.test-index"

echo "=== Python Skill/Doc Tests ==="
echo ""

# --- Pre-existing failures not yet in RED phase ---
# These tests fail due to unimplemented features in other stories; they are
# excluded to prevent noise until their owning story marks them RED.
# Format: pytest node-id fragment matched with -k "not (<fragments joined by or>)"
KNOWN_FAILING=(
)

# --- Collect RED-phase markers from .test-index ---
# Lines of form:  source/path: tests/skills/foo.py [MarkerName]
red_markers=()
if [ -f "$TEST_INDEX" ]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ tests/(skills|docs)/[^[:space:]]+\.py[[:space:]]*\[([^]]+)\] ]]; then
            red_markers+=("${BASH_REMATCH[2]}")
        fi
    done < "$TEST_INDEX"
fi

# Build combined exclusion list
all_excluded=("${red_markers[@]}" "${KNOWN_FAILING[@]}")

DESELECT_EXPR=""
if [ ${#all_excluded[@]} -gt 0 ]; then
    # Join items with " or " for pytest -k expression
    joined=""
    for item in "${all_excluded[@]}"; do
        if [ -z "$joined" ]; then
            joined="$item"
        else
            joined="$joined or $item"
        fi
    done
    DESELECT_EXPR="not ($joined)"
fi

# Determine test directories
test_dirs=("$SCRIPT_DIR" "$DOCS_DIR")
existing_dirs=()
for d in "${test_dirs[@]}"; do
    [ -d "$d" ] && existing_dirs+=("$d")
done

if [ ${#existing_dirs[@]} -eq 0 ]; then
    echo "No Python test directories found."
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found." >&2
    exit 1
fi

pytest_args=("${existing_dirs[@]}" "--tb=short" "-q")
if [ -n "$DESELECT_EXPR" ]; then
    pytest_args+=("-k" "$DESELECT_EXPR")
fi

echo "Excluding RED-phase markers: ${red_markers[*]:-none}"
echo "Excluding known-failing:     ${KNOWN_FAILING[*]:-none}"
echo ""

python3 -m pytest "${pytest_args[@]}"
exit_code=$?

echo ""
if [ "$exit_code" -eq 0 ]; then
    echo "Python Skill/Doc Tests: PASS"
else
    echo "Python Skill/Doc Tests: FAIL"
fi

exit "$exit_code"
