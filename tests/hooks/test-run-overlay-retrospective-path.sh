#!/usr/bin/env bash
# tests/hooks/test-run-overlay-retrospective-path.sh
# RED test: verifies run-overlay-retrospective.sh --help output does NOT advertise
# plugins/dso/ as the default output path (story c73a-1918, task 63c0-9471).
#
# The test runs the script with --help and asserts on stdout. It currently FAILS
# because the default path shown in help is plugins/dso/docs/overlay-calibration-baselines.md.
# It will PASS after the default is moved to a non-plugin directory (e.g. docs/findings/).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$REPO_ROOT/plugins/dso/scripts"

# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# ── test_default_output_not_in_plugin_dir ────────────────────────────────────
# Runs the script with --help and asserts that the documented default output
# path does NOT reside under plugins/dso/.
#
# Observable surface: stdout from --help
# RED condition: help text contains 'plugins/dso/' (current default path)
# GREEN condition: help text does not contain 'plugins/dso/' (fixed default path)
test_default_output_not_in_plugin_dir() {
    local help_output
    help_output=$(bash "$SCRIPT_DIR/run-overlay-retrospective.sh" --help 2>&1)
    local exit_code=$?

    assert_eq "help exits 0" "0" "$exit_code"

    # Assert the help text does NOT mention plugins/dso/ as the default output path.
    # We express this as: the string "plugins/dso/" should NOT appear in the help output.
    # We detect presence and assert it equals "false" (i.e. not found).
    local contains_banned
    if echo "$help_output" | grep -q "plugins/dso/"; then
        contains_banned="true"
    else
        contains_banned="false"
    fi

    assert_eq \
        "default output path shown in --help must not contain 'plugins/dso/'" \
        "false" \
        "$contains_banned"
}

test_default_output_not_in_plugin_dir

print_summary
