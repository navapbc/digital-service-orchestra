#!/usr/bin/env bash
# tests/scripts/test-stale-script-path-refs.sh
# Regression guard: ensures plugin skill/docs/script files do not reference
# $REPO_ROOT/scripts/ when the scripts live at $REPO_ROOT/plugins/dso/scripts/.
# After plugin extraction, all DSO script references must use the qualified path.
#
# Exclusions:
#   - check-test-isolation.sh: sets REPO_ROOT to plugins/dso (parent of script dir),
#     so $REPO_ROOT/scripts/test-isolation-rules correctly resolves to
#     plugins/dso/scripts/test-isolation-rules — this is intentional.
#   - pre-bash-functions.sh: the reference uses \$REPO_ROOT (escaped, in a user-facing
#     error message describing a command to run) — not an actual invocation.
#   - merge-to-main.sh: the reference is in an error message string, not an invocation.
#
# Usage: bash tests/scripts/test-stale-script-path-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-stale-script-path-refs (stale \$REPO_ROOT/scripts/ references) ==="

PLUGIN_DIR="$REPO_ROOT/plugins/dso"

# Files that are exempt from the check (with reason documented above):
EXEMPT_FILES=(
    "plugins/dso/scripts/check-test-isolation.sh"
    "plugins/dso/hooks/lib/pre-bash-functions.sh"
    "plugins/dso/scripts/merge-to-main.sh"
)

# Build a grep exclusion pattern for exempt files
EXCLUDE_PATTERN=$(printf '%s\n' "${EXEMPT_FILES[@]}" | sed 's|plugins/dso/||' | paste -sd'|' -)

# ── Test 1: No stale $REPO_ROOT/scripts/ references in skills ────────────────
echo "Test 1: No stale \$REPO_ROOT/scripts/ references in plugin skills"
stale_refs=()
while IFS= read -r match; do
    file="${match%%:*}"
    rel="${file#"$REPO_ROOT"/}"
    # Skip exempt files
    skip=0
    for exempt in "${EXEMPT_FILES[@]}"; do
        if [[ "$rel" == "$exempt" ]]; then
            skip=1
            break
        fi
    done
    [[ "$skip" -eq 1 ]] && continue
    stale_refs+=("$match")
done < <(grep -rn '\$REPO_ROOT/scripts/' \
    "$PLUGIN_DIR/skills/" \
    --include="*.md" --include="*.sh" 2>/dev/null || true)

if [[ ${#stale_refs[@]} -eq 0 ]]; then
    echo "  PASS: No stale \$REPO_ROOT/scripts/ references in skills"
    (( PASS++ ))
else
    echo "  FAIL: Found ${#stale_refs[@]} stale \$REPO_ROOT/scripts/ reference(s) in skills:" >&2
    for ref in "${stale_refs[@]}"; do
        echo "    - $ref" >&2
    done
    (( FAIL++ ))
fi

# ── Test 2: No stale $REPO_ROOT/scripts/ references in docs ─────────────────
echo "Test 2: No stale \$REPO_ROOT/scripts/ references in plugin docs"
stale_refs=()
while IFS= read -r match; do
    file="${match%%:*}"
    rel="${file#"$REPO_ROOT"/}"
    skip=0
    for exempt in "${EXEMPT_FILES[@]}"; do
        if [[ "$rel" == "$exempt" ]]; then
            skip=1
            break
        fi
    done
    [[ "$skip" -eq 1 ]] && continue
    stale_refs+=("$match")
done < <(grep -rn '\$REPO_ROOT/scripts/' \
    "$PLUGIN_DIR/docs/" \
    --include="*.md" --include="*.sh" 2>/dev/null || true)

if [[ ${#stale_refs[@]} -eq 0 ]]; then
    echo "  PASS: No stale \$REPO_ROOT/scripts/ references in docs"
    (( PASS++ ))
else
    echo "  FAIL: Found ${#stale_refs[@]} stale \$REPO_ROOT/scripts/ reference(s) in docs:" >&2
    for ref in "${stale_refs[@]}"; do
        echo "    - $ref" >&2
    done
    (( FAIL++ ))
fi

# ── Test 3: No stale $REPO_ROOT/scripts/ references in scripts (functional) ──
# The scripts directory itself should not functionally invoke $REPO_ROOT/scripts/
# (the install-git-aliases.sh alias string is the key functional bug to catch here)
echo "Test 3: No stale \$REPO_ROOT/scripts/ references in plugin scripts (functional invocations)"
stale_refs=()
while IFS= read -r match; do
    file="${match%%:*}"
    rel="${file#"$REPO_ROOT"/}"
    skip=0
    for exempt in "${EXEMPT_FILES[@]}"; do
        if [[ "$rel" == "$exempt" ]]; then
            skip=1
            break
        fi
    done
    [[ "$skip" -eq 1 ]] && continue
    stale_refs+=("$match")
done < <(grep -rn '\$REPO_ROOT/scripts/' \
    "$PLUGIN_DIR/scripts/" \
    --include="*.sh" 2>/dev/null || true)

if [[ ${#stale_refs[@]} -eq 0 ]]; then
    echo "  PASS: No stale \$REPO_ROOT/scripts/ references in scripts"
    (( PASS++ ))
else
    echo "  FAIL: Found ${#stale_refs[@]} stale \$REPO_ROOT/scripts/ reference(s) in scripts:" >&2
    for ref in "${stale_refs[@]}"; do
        echo "    - $ref" >&2
    done
    (( FAIL++ ))
fi

# ── Test 4: No stale $REPO_ROOT/scripts/ references in hooks ─────────────────
echo "Test 4: No stale \$REPO_ROOT/scripts/ references in plugin hooks"
stale_refs=()
while IFS= read -r match; do
    file="${match%%:*}"
    rel="${file#"$REPO_ROOT"/}"
    skip=0
    for exempt in "${EXEMPT_FILES[@]}"; do
        if [[ "$rel" == "$exempt" ]]; then
            skip=1
            break
        fi
    done
    [[ "$skip" -eq 1 ]] && continue
    stale_refs+=("$match")
done < <(grep -rn '\$REPO_ROOT/scripts/' \
    "$PLUGIN_DIR/hooks/" \
    --include="*.md" --include="*.sh" 2>/dev/null || true)

if [[ ${#stale_refs[@]} -eq 0 ]]; then
    echo "  PASS: No stale \$REPO_ROOT/scripts/ references in hooks"
    (( PASS++ ))
else
    echo "  FAIL: Found ${#stale_refs[@]} stale \$REPO_ROOT/scripts/ reference(s) in hooks:" >&2
    for ref in "${stale_refs[@]}"; do
        echo "    - $ref" >&2
    done
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
