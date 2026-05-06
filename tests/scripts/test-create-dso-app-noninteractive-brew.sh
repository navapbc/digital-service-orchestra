#!/usr/bin/env bash
# tests/scripts/test-create-dso-app-noninteractive-brew.sh
#
# Regression test for bug a877-7639:
#   When the host shell sets SNOWINTERACTIVE (or DSO_REFUSE_BREW_AUTO_INSTALL=1)
#   and Homebrew is missing, check_homebrew_deps() must refuse to invoke the
#   official Homebrew installer (which requires sudo at runtime and cannot
#   prompt non-interactively) and instead emit a clear pre-flight error
#   pointing to manual install.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/create-dso-app.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-create-dso-app-noninteractive-brew.sh ==="

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Extract check_homebrew_deps into a sourceable shim
SHIM="$T/shim.sh"
awk '/^check_homebrew_deps\(\)/{found=1} found{print; if(/^\}$/){exit}}' \
    "$SCRIPT_UNDER_TEST" > "$SHIM"

# ── test_snowinteractive_blocks_brew_auto_install ────────────────────────────
# With SNOWINTERACTIVE=1 and no brew on PATH, function exits 1 with the
# pre-flight error message naming SNOWINTERACTIVE. It must NOT attempt to
# download or run the Homebrew installer.
EXIT_CODE=0
STDERR=$(SNOWINTERACTIVE=1 PATH="/usr/bin:/bin" bash -c "set -uo pipefail; source '$SHIM'; check_homebrew_deps" 2>&1 1>/dev/null) || EXIT_CODE=$?
assert_eq "test_snowinteractive_blocks_brew_auto_install: exit non-zero" "1" "$EXIT_CODE"
if echo "$STDERR" | grep -q "SNOWINTERACTIVE"; then
    (( ++PASS )); echo "test_snowinteractive_blocks_brew_auto_install: cites SNOWINTERACTIVE ... PASS"
else
    (( ++FAIL )); printf "FAIL: test_snowinteractive_blocks_brew_auto_install: SNOWINTERACTIVE not cited\n  stderr: %s\n" "$STDERR" >&2
fi

# ── test_explicit_opt_out_blocks_brew_auto_install ───────────────────────────
# DSO_REFUSE_BREW_AUTO_INSTALL=1 is the documented escape hatch.
EXIT_CODE=0
STDERR=$(DSO_REFUSE_BREW_AUTO_INSTALL=1 PATH="/usr/bin:/bin" bash -c "set -uo pipefail; source '$SHIM'; check_homebrew_deps" 2>&1 1>/dev/null) || EXIT_CODE=$?
assert_eq "test_explicit_opt_out_blocks_brew_auto_install: exit non-zero" "1" "$EXIT_CODE"
if echo "$STDERR" | grep -q "DSO_REFUSE_BREW_AUTO_INSTALL"; then
    (( ++PASS )); echo "test_explicit_opt_out_blocks_brew_auto_install: cites opt-out var ... PASS"
else
    (( ++FAIL )); printf "FAIL: test_explicit_opt_out_blocks_brew_auto_install: opt-out var not cited\n  stderr: %s\n" "$STDERR" >&2
fi

print_summary
