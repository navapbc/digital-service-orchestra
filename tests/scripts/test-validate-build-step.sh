#!/usr/bin/env bash
# tests/scripts/test-validate-build-step.sh
# Behavioral TDD tests verifying that validate.sh supports an optional commands.build step.
#
# Tests:
#   test_validate_config_accepts_commands_build — validate-config.sh accepts commands.build as a known key
#   test_build_marker_created_when_configured  — validate.sh invokes the build command when commands.build is set
#   test_build_skipped_when_not_configured     — validate.sh does NOT invoke build when commands.build is absent
#   test_dso_config_documents_commands_build   — dso-config.conf documents the commands.build key
#
# Usage: bash tests/scripts/test-validate-build-step.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATE_SH="$REPO_ROOT/plugins/dso/scripts/validate.sh"
VALIDATE_CONFIG_SH="$REPO_ROOT/plugins/dso/scripts/validate-config.sh"
DSO_CONFIG="$REPO_ROOT/.claude/dso-config.conf"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-validate-build-step.sh ==="

# Shared stub setup
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

STUB_BIN="$TMPDIR_TEST/stub_bin"
mkdir -p "$STUB_BIN"

# Stub: make always passes — prevents real make calls from failing in this repo
cat > "$STUB_BIN/make" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_BIN/make"

# Stub test-batched.sh: exits 0 immediately (stub unit tests)
STUB_TEST_BATCHED="$TMPDIR_TEST/test-batched.sh"
cat > "$STUB_TEST_BATCHED" << 'TBSTUB'
#!/usr/bin/env bash
exit 0
TBSTUB
chmod +x "$STUB_TEST_BATCHED"

# ── test_validate_config_accepts_commands_build ───────────────────────────────
# validate-config.sh must accept commands.build as a known key (exit 0, no error).
_snapshot_fail
FIXTURE_CONFIG="$TMPDIR_TEST/fixture.conf"
cat > "$FIXTURE_CONFIG" << 'CONF'
version=1.0.0
commands.build=npm run build
CONF
config_rc=0
config_stderr=$(bash "$VALIDATE_CONFIG_SH" "$FIXTURE_CONFIG" 2>&1 >/dev/null) || config_rc=$?
assert_eq "test_validate_config_accepts_commands_build" "0" "$config_rc"
assert_pass_if_clean "test_validate_config_accepts_commands_build"

# ── test_build_marker_created_when_configured ─────────────────────────────────
# When commands.build is set in config, validate.sh must invoke the build command.
_snapshot_fail
BUILD_MARKER="$TMPDIR_TEST/build-was-called"
BUILD_STUB="$TMPDIR_TEST/stub_build.sh"
cat > "$BUILD_STUB" << BSTUB
#!/usr/bin/env bash
# Marker: records that the build command was invoked by validate.sh
touch "$BUILD_MARKER"
exit 0
BSTUB
chmod +x "$BUILD_STUB"

# Config with commands.build pointing to the stub script
CONFIG_WITH_BUILD="$TMPDIR_TEST/config-with-build.conf"
cat > "$CONFIG_WITH_BUILD" << CONF
version=1.0.0
commands.build=$BUILD_STUB
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
commands.test_unit=true
CONF

run_rc=0
PATH="$STUB_BIN:$PATH" \
    WORKFLOW_CONFIG_FILE="$CONFIG_WITH_BUILD" \
    VALIDATE_CMD_TEST="true" \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_TEST_BATCHED" \
    bash "$VALIDATE_SH" 2>/dev/null || run_rc=$?

marker_created=0
[ -f "$BUILD_MARKER" ] && marker_created=1
assert_eq "test_build_marker_created_when_configured" "1" "$marker_created"
assert_pass_if_clean "test_build_marker_created_when_configured"

# ── test_build_skipped_when_not_configured ────────────────────────────────────
# When commands.build is absent from config, validate.sh must NOT invoke any build command.
_snapshot_fail
NO_BUILD_MARKER="$TMPDIR_TEST/no-build-marker"
NO_BUILD_STUB="$TMPDIR_TEST/stub_no_build.sh"
cat > "$NO_BUILD_STUB" << NBSTUB
#!/usr/bin/env bash
# If this is called, build ran when it should not have
touch "$NO_BUILD_MARKER"
exit 0
NBSTUB
chmod +x "$NO_BUILD_STUB"

# Config WITHOUT commands.build (verify build step is skipped)
CONFIG_NO_BUILD="$TMPDIR_TEST/config-no-build.conf"
cat > "$CONFIG_NO_BUILD" << CONF
version=1.0.0
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
commands.test_unit=true
CONF

run_rc2=0
PATH="$STUB_BIN:$PATH" \
    WORKFLOW_CONFIG_FILE="$CONFIG_NO_BUILD" \
    VALIDATE_CMD_TEST="true" \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_TEST_BATCHED" \
    bash "$VALIDATE_SH" 2>/dev/null || run_rc2=$?

no_build_marker_created=0
[ -f "$NO_BUILD_MARKER" ] && no_build_marker_created=1
assert_eq "test_build_skipped_when_not_configured" "0" "$no_build_marker_created"
assert_pass_if_clean "test_build_skipped_when_not_configured"

# ── test_dso_config_documents_commands_build ──────────────────────────────────
# dso-config.conf must document the commands.build key so host projects can discover it.
_snapshot_fail
config_build_doc=$(grep -c 'commands.build' "$DSO_CONFIG" || true)
assert_ne "test_dso_config_documents_commands_build" "0" "$config_build_doc"
assert_pass_if_clean "test_dso_config_documents_commands_build"

print_summary
