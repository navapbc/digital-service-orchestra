#!/usr/bin/env bash
# tests/scripts/test-create-dso-app-homebrew-auto-install.sh
# RED test for bug a4c7-32ff: check_homebrew_deps should auto-install Homebrew
# via the official installer when `brew` is not found on PATH, instead of
# immediately exiting with "Homebrew is required but not installed."
#
# This test will FAIL before the fix (current code hard-exits) and PASS after
# (code invokes the official installer, discovers brew, and continues).
#
# Technique: PATH-stubbing (same pattern as test-create-dso-app.sh).
# - stub_bin has NO brew initially
# - curl stub writes a brew stub into stub_bin (simulates installer)
# - /bin/bash -c "$(curl ...)" runs and brew becomes available
# - brew stub handles shellenv + all dependency queries

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/create-dso-app.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]}"' EXIT

echo "=== test-create-dso-app-homebrew-auto-install.sh ==="

# Helper: write a stub command to a dir
_write_stub() {
    local dir="$1" name="$2" body="$3"
    printf '#!/bin/sh\n%s\n' "$body" > "$dir/$name"
    chmod +x "$dir/$name"
}

# ── test_homebrew_auto_install_when_missing ──────────────────────────────────
# When brew is absent from PATH, the fixed script should:
#   (a) print a message indicating it is installing Homebrew (not hard-exit)
#   (b) NOT print "Homebrew is required but not installed."
#   (c) proceed past check_homebrew_deps (prints "All dependencies satisfied")
#
# Before the fix: script hard-exits with "Homebrew is required but not
# installed." — assertion (a) fails because the installing message is never
# printed, and assertion (c) fails because the script exits early.
test_homebrew_auto_install_when_missing() {
    local stub_bin
    stub_bin=$(mktemp -d)
    TMPDIRS+=("$stub_bin")

    # curl stub: prints a shell script that writes a brew stub into stub_bin.
    # The script runs this output via `/bin/bash -c "$(curl ...)"` — so our
    # curl stub output is the install.sh body that creates brew on disk.
    #
    # We expose STUB_BIN as an env var so the curl output can reference it.
    # The script itself sets PATH="$stub_bin:..." so after the curl-install
    # body runs and writes brew, `command -v brew` will find it.
    cat > "$stub_bin/curl" <<'CURLEOF'
#!/bin/sh
# Ignore all flags/args; emit a mini installer script that writes a brew stub.
# The variable STUB_BIN is set by the test harness and inherited by the
# subshell that runs: /bin/bash -c "$(curl ...)"
cat <<'INSTALLER'
#!/bin/sh
# Homebrew installer stub — writes brew into STUB_BIN
if [ -n "${STUB_BIN:-}" ]; then
  cat > "$STUB_BIN/brew" <<'BREWSCRIPT'
#!/bin/sh
case "$*" in
  shellenv)           echo 'true' ;;
  "list bash")        exit 0 ;;
  "list node@20")     exit 0 ;;
  "--prefix bash")    echo "/usr/local" ;;
  "--prefix node@20") echo "/usr/local" ;;
  "--version"|"-v")   echo "Homebrew 4.0.0" ;;
  *)                  ;;
esac
exit 0
BREWSCRIPT
  chmod +x "$STUB_BIN/brew"
fi
INSTALLER
CURLEOF
    chmod +x "$stub_bin/curl"

    # /bin/bash stub: used to run `bash --version` AND to execute the installer.
    # Must handle both modes:
    #   1. `bash --version`  → print a version string (used inside check_homebrew_deps)
    #   2. `bash -c "<installer script body>"` → eval the installer content
    # We proxy the -c case to /bin/bash directly so the curl-emitted installer runs.
    cat > "$stub_bin/bash" <<'BASHEOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    echo "GNU bash, version 5.2.15(1)-release (x86_64-apple-darwin)"
    exit 0
fi
# For -c / other invocations: delegate to real bash
exec /bin/bash "$@"
BASHEOF
    chmod +x "$stub_bin/bash"

    # Stubs for all deps checked AFTER check_homebrew_deps passes.
    # brew stub: check_homebrew_deps calls brew for shellenv + dep checks.
    # This copy is created BEFORE the test runs — but the REAL test verifies
    # that the script creates brew via the installer, not that this pre-exists.
    # NOTE: We intentionally do NOT pre-create brew here; it must be created
    # by the curl installer stub during the run. The curl stub writes it.

    # Proxy stubs for system commands used by the script
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "grep"    '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"    '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "tr"      '/usr/bin/tr "$@"'

    # All other dep stubs (git, greadlink, pre-commit, node, python3, claude,
    # uv, sg, semgrep, docker) are not needed because check_homebrew_deps will
    # call `brew install <dep>` for each missing one — and our brew stub just
    # exits 0 for those. However, we need them present so `command -v <dep>`
    # returns true (avoiding brew install attempts that could obscure output).
    _write_stub "$stub_bin" "git"       "exit 0"
    _write_stub "$stub_bin" "greadlink" "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "node"      'echo "v20.11.0"; exit 0'
    _write_stub "$stub_bin" "python3"   "exit 0"
    _write_stub "$stub_bin" "claude"    "exit 0"
    _write_stub "$stub_bin" "uv"        "exit 0"
    _write_stub "$stub_bin" "sg"        "exit 0"
    _write_stub "$stub_bin" "semgrep"   "exit 0"
    _write_stub "$stub_bin" "docker"    "exit 0"

    # Run the script with STUB_BIN exported so the curl stub's installer output
    # can reference it. PATH contains ONLY stub_bin (plus /bin for /bin/bash).
    local output exit_code
    output=$(STUB_BIN="$stub_bin" PATH="$stub_bin:/bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) \
        && exit_code=0 || exit_code=$?

    # Assertion 1: the auto-install path prints something about installing Homebrew.
    # Before the fix, the script hard-exits without printing any installing message.
    local install_msg_found="no"
    if echo "$output" | grep -qi "installing"; then
        install_msg_found="yes"
    fi
    assert_eq "brew absent: prints installing message (not hard-exit)" "yes" "$install_msg_found"

    # Assertion 2: the old hard-exit message must NOT appear.
    # Before the fix, this is the first (and only) output.
    local old_exit_msg_found="no"
    if echo "$output" | grep -q "Homebrew is required but not installed"; then
        old_exit_msg_found="yes"
    fi
    assert_eq "brew absent: does NOT print old hard-exit message" "no" "$old_exit_msg_found"

    # Assertion 3: the script proceeds past check_homebrew_deps and prints the
    # "All dependencies satisfied" completion message.
    # Before the fix, the script exits before reaching this line.
    local completed="no"
    if echo "$output" | grep -q "All dependencies satisfied"; then
        completed="yes"
    fi
    assert_eq "brew absent: proceeds past check_homebrew_deps after auto-install" "yes" "$completed"
}

# ── test_curl_download_fails_exits_with_error ────────────────────────────────
# When brew is missing AND curl exists but fails (non-zero exit during fetch),
# the script must exit non-zero with "Failed to download Homebrew installer".
test_curl_download_fails_exits_with_error() {
    local stub_bin
    stub_bin=$(mktemp -d)
    TMPDIRS+=("$stub_bin")

    # No brew. curl exists but fails.
    _write_stub "$stub_bin" "curl"    'exit 22'
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'

    local output exit_code
    output=$(PATH="$stub_bin:/bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) \
        && exit_code=0 || exit_code=$?

    assert_ne "curl fails: exits non-zero" "0" "$exit_code"

    local msg_found="no"
    if echo "$output" | grep -q "Failed to download Homebrew installer"; then
        msg_found="yes"
    fi
    assert_eq "curl fails: prints download-failed message" "yes" "$msg_found"
}

# ── test_installer_invocation_fails_exits_with_error ─────────────────────────
# When brew is missing, curl succeeds, but the installer script itself fails,
# the script must exit non-zero with "Homebrew install failed".
test_installer_invocation_fails_exits_with_error() {
    local stub_bin
    stub_bin=$(mktemp -d)
    TMPDIRS+=("$stub_bin")

    # No brew. curl outputs an installer script that exits non-zero.
    _write_stub "$stub_bin" "curl"    'echo "exit 1"'
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'

    local output exit_code
    output=$(PATH="$stub_bin:/bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) \
        && exit_code=0 || exit_code=$?

    assert_ne "installer fails: exits non-zero" "0" "$exit_code"

    local msg_found="no"
    if echo "$output" | grep -q "Homebrew install failed"; then
        msg_found="yes"
    fi
    assert_eq "installer fails: prints install-failed message" "yes" "$msg_found"
}

test_homebrew_auto_install_when_missing
test_curl_download_fails_exits_with_error
test_installer_invocation_fails_exits_with_error

print_summary
