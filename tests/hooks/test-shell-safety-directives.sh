#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-shell-safety-directives.sh
# Guard: all .sh files under lockpick-workflow/scripts/ must have a shell safety
# directive (set -euo pipefail, set -uo pipefail, or equivalent) within the
# first 10 lines.
#
# Rationale: Early safety directives catch unbound variables, pipeline errors,
# and unexpected failures rather than silently continuing.
#
# Exceptions (documented below):
#   - ensure-pre-commit.sh: Intentionally omits set -euo pipefail because it
#     may be sourced into the caller's shell; setting options would persist in
#     the caller and break scripts relying on unset variables being empty strings.
#   - lib/require-tk.sh: Sourced library file that only defines a function;
#     adding set options here would affect the sourcing caller's shell state.
#   - runners/node-runner.sh: Sourced by test-batched.sh as a runner driver;
#     adding set options would interfere with the caller's error handling.
#
# Usage: bash lockpick-workflow/tests/hooks/test-shell-safety-directives.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../../scripts"

source "$SCRIPT_DIR/../lib/assert.sh"

echo "=== Test: shell safety directives in first 10 lines ==="

# Files that are intentionally exempt from the safety directive requirement.
# These are sourced library files or scripts with documented reasons for omission.
EXCEPTIONS=(
    "ensure-pre-commit.sh"
    "lib/require-tk.sh"
    "runners/node-runner.sh"
)

is_exception() {
    local rel_path="$1"
    for exc in "${EXCEPTIONS[@]}"; do
        if [[ "$rel_path" == "$exc" ]]; then
            return 0
        fi
    done
    return 1
}

VIOLATIONS=""
VIOLATION_COUNT=0
CHECKED=0

# Use a temp file for script list (process substitution via /dev/fd unavailable in CI env)
_script_list=$(mktemp)
find "$SCRIPTS_DIR" -name "*.sh" | sort > "$_script_list"

while IFS= read -r script_file; do
    # Compute path relative to SCRIPTS_DIR for exception matching and display
    rel_path="${script_file#"$SCRIPTS_DIR/"}"

    if is_exception "$rel_path"; then
        continue
    fi

    CHECKED=$((CHECKED + 1))

    # Check if a safety directive appears within the first 10 lines.
    # Accepts: set -euo pipefail, set -uo pipefail, set -e, set -eu, set -u, set -o pipefail
    # or any combination that includes at minimum -u and -o pipefail.
    if ! head -10 "$script_file" | grep -qE '^set -[euo]|^set -o pipefail'; then
        VIOLATIONS="${VIOLATIONS}  $rel_path\n"
        VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
    fi
done < "$_script_list"
rm -f "$_script_list"

echo "Checked $CHECKED scripts (${#EXCEPTIONS[@]} exceptions skipped)."

if [ "$VIOLATION_COUNT" -eq 0 ]; then
    assert_eq "all scripts have safety directive in first 10 lines" "0" "0"
else
    printf "\nScripts missing safety directive in first 10 lines (%d):\n" "$VIOLATION_COUNT" >&2
    printf "%b" "$VIOLATIONS" >&2
    assert_eq "all scripts have safety directive in first 10 lines" "0" "$VIOLATION_COUNT"
fi

print_summary
