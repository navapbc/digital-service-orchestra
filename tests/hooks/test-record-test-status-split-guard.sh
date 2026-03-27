#!/usr/bin/env bash
# tests/hooks/test-record-test-status-split-guard.sh
# Structural guard: enforces that test-record-test-status.sh is split into 4 part files
# and that no part file grows past 12 test sections (timeout regression prevention).
#
# Usage: bash tests/hooks/test-record-test-status-split-guard.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

HOOKS_DIR="$SCRIPT_DIR"
MAX_SECTIONS=12

# ============================================================================
# test_monolith_does_not_exist
# ============================================================================
echo "=== test_monolith_does_not_exist ==="
monolith="$HOOKS_DIR/test-record-test-status.sh"
monolith_exists="no"
if [[ -f "$monolith" ]]; then monolith_exists="yes"; fi
assert_eq "monolithic file must be removed" "no" "$monolith_exists"

# --- Part existence checks ---
for part_num in 1 2 3 4; do
    echo "=== test_part${part_num}_exists ==="
    part_file="$HOOKS_DIR/test-record-test-status-part${part_num}.sh"
    part_exists="no"
    if [[ -f "$part_file" ]]; then part_exists="yes"; fi
    assert_eq "part${part_num} file must exist" "yes" "$part_exists"
done

# --- Section count checks ---
for part_num in 1 2 3 4; do
    echo "=== test_part${part_num}_section_count_under_limit ==="
    part_file="$HOOKS_DIR/test-record-test-status-part${part_num}.sh"
    if [[ -f "$part_file" ]]; then
        part_count=$(grep -c '^echo "=== ' "$part_file" || true)
        within_limit="yes"
        if [[ "$part_count" -gt "$MAX_SECTIONS" ]]; then within_limit="no"; fi
        assert_eq "part${part_num} must have ${MAX_SECTIONS} or fewer test sections (got $part_count)" "yes" "$within_limit"
    else
        assert_eq "part${part_num} must exist to check section count" "yes" "no"
    fi
done

# --- Shebang checks ---
for part_num in 1 2 3 4; do
    echo "=== test_part${part_num}_has_bash_shebang ==="
    part_file="$HOOKS_DIR/test-record-test-status-part${part_num}.sh"
    if [[ -f "$part_file" ]]; then
        first_line=$(head -1 "$part_file")
        assert_eq "part${part_num} shebang" "#!/usr/bin/env bash" "$first_line"
    else
        assert_eq "part${part_num} must exist to check shebang" "yes" "no"
    fi
done

# --- Pipefail checks ---
for part_num in 1 2 3 4; do
    echo "=== test_part${part_num}_has_pipefail ==="
    part_file="$HOOKS_DIR/test-record-test-status-part${part_num}.sh"
    if [[ -f "$part_file" ]]; then
        pipefail_found=$(grep -c 'set -.*pipefail\|pipefail' "$part_file" || true)
        has_pipefail="no"
        if [[ "$pipefail_found" -gt 0 ]]; then has_pipefail="yes"; fi
        assert_eq "part${part_num} must contain pipefail" "yes" "$has_pipefail"
    else
        assert_eq "part${part_num} must exist to check pipefail" "yes" "no"
    fi
done

print_summary
