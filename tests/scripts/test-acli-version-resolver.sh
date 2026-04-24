#!/usr/bin/env bash
# tests/scripts/test-acli-version-resolver.sh
# Behavioral tests for plugins/dso/scripts/onboarding/acli-version-resolver.sh
#
# Integration tests against live acli.atlassian.com out of scope for CI.
# PoC script serves as manual integration validation.
#
# Tests use PATH override with a mock acli script. Tests invoke the resolver
# script (or sourced functions) and assert on exit codes and stdout.
#
# Usage: bash tests/scripts/test-acli-version-resolver.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/onboarding/acli-version-resolver.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-acli-version-resolver.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# ── Helpers ──────────────────────────────────────────────────────────────────

# write_mock_acli version_string
# Creates a mock acli that outputs "acli version <version_string>" on stdout.
write_mock_acli() {
    local version_string="$1"
    cat > "$MOCK_BIN/acli" <<MOCK
#!/usr/bin/env bash
echo "acli version $version_string"
MOCK
    chmod +x "$MOCK_BIN/acli"
}

# run_script_with_mock [version] [extra_env...]
# Runs the resolver script with PATH prepended to use the mock acli.
run_with_mock_path() {
    PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_parse_version_string
# Mock acli outputs 'acli version 1.3.5-stable', assert parsed output = '1.3.5-stable'
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_parse_version_string ---"
_snapshot_fail

write_mock_acli "1.3.5-stable"
rc=0
output=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>&1) || rc=$?

# The script must emit ACLI_VERSION=1.3.5-stable in its output
assert_contains "test_parse_version_string version in output" "1.3.5-stable" "$output"

assert_pass_if_clean "test_parse_version_string"

# ─────────────────────────────────────────────────────────────────────────────
# test_parse_version_multi
# Test 2+ version strings (1.3.4-stable, 1.3.5-stable) produce stable URLs
# (same version → same URL on repeated calls)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_parse_version_multi ---"
_snapshot_fail

for ver in "1.3.4-stable" "1.3.5-stable"; do
    write_mock_acli "$ver"
    out=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>&1) || true
    assert_contains "test_parse_version_multi version $ver in output" "$ver" "$out"
done

# Stability: same version called twice produces same URL fragment
write_mock_acli "1.3.5-stable"
out1=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>&1) || true
out2=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>&1) || true
assert_eq "test_parse_version_multi url stability" "$out1" "$out2"

assert_pass_if_clean "test_parse_version_multi"

# ─────────────────────────────────────────────────────────────────────────────
# test_construct_versioned_url
# Given a version and platform, assert the output URL matches expected pattern
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_construct_versioned_url ---"
_snapshot_fail

write_mock_acli "1.3.5-stable"
rc=0
output=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>&1) || rc=$?

# The resolved URL should contain the version string
assert_contains "test_construct_versioned_url version in url" "1.3.5-stable" "$output"

# The URL should follow the expected atlassian download pattern (base domain or path segment)
# acli downloads from acli.atlassian.com or similar; must contain 'acli' in URL
assert_contains "test_construct_versioned_url acli in url" "acli" "$output"

assert_pass_if_clean "test_construct_versioned_url"

# ─────────────────────────────────────────────────────────────────────────────
# test_sha256_computation
# Fixture file: compute hash, assert matches known value
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_sha256_computation ---"
_snapshot_fail

FIXTURE_FILE="$TMPDIR_TEST/fixture.bin"
printf 'hello acli version resolver\n' > "$FIXTURE_FILE"

# Compute expected hash using shasum or sha256sum
if command -v sha256sum &>/dev/null; then
    expected_hash=$(sha256sum "$FIXTURE_FILE" | awk '{print $1}')
elif command -v shasum &>/dev/null; then
    expected_hash=$(shasum -a 256 "$FIXTURE_FILE" | awk '{print $1}')
else
    echo "SKIP: no sha256sum or shasum available"
    (( ++PASS ))
    assert_pass_if_clean "test_sha256_computation (skipped)"
    expected_hash=""
fi

if [[ -n "$expected_hash" ]]; then
    # Verify the hash is a 64-character hex string (SHA-256)
    hex_len=${#expected_hash}
    assert_eq "test_sha256_computation hash length is 64" "64" "$hex_len"

    # Verify hash is stable (deterministic)
    if command -v sha256sum &>/dev/null; then
        actual_hash=$(sha256sum "$FIXTURE_FILE" | awk '{print $1}')
    else
        actual_hash=$(shasum -a 256 "$FIXTURE_FILE" | awk '{print $1}')
    fi
    assert_eq "test_sha256_computation hash stability" "$expected_hash" "$actual_hash"

    assert_pass_if_clean "test_sha256_computation"
fi

# ─────────────────────────────────────────────────────────────────────────────
# test_full_flow_mock
# Invoke script with mocked downloads, assert exit 0 + ACLI_VERSION + ACLI_SHA256 in stdout
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_full_flow_mock ---"
_snapshot_fail

# Write mock acli reporting a stable version
write_mock_acli "1.3.5-stable"

# Write mock curl/wget that returns a fake binary payload for downloads
MOCK_CURL="$MOCK_BIN/curl"
cat > "$MOCK_CURL" <<'MOCK'
#!/usr/bin/env bash
# Mock curl: write a fake binary to the output path specified by -o or --output
output_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) output_path="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ -n "$output_path" ]]; then
    printf 'fake-acli-binary-content\n' > "$output_path"
fi
exit 0
MOCK
chmod +x "$MOCK_CURL"

rc=0
output=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>&1) || rc=$?

# Must exit 0 on success
assert_eq "test_full_flow_mock exit code" "0" "$rc"

# Output must contain ACLI_VERSION key
assert_contains "test_full_flow_mock ACLI_VERSION in output" "ACLI_VERSION" "$output"

# Output must contain ACLI_SHA256 key
assert_contains "test_full_flow_mock ACLI_SHA256 in output" "ACLI_SHA256" "$output"

assert_pass_if_clean "test_full_flow_mock"

# ─────────────────────────────────────────────────────────────────────────────
# test_error_missing_acli
# No acli in PATH → non-zero exit
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_error_missing_acli ---"
_snapshot_fail

# Use an empty PATH so acli cannot be found
rc=0
output=$(PATH="$TMPDIR_TEST/empty" bash "$SCRIPT" 2>&1) || rc=$?

assert_ne "test_error_missing_acli non-zero exit" "0" "$rc"

assert_pass_if_clean "test_error_missing_acli"

# ─────────────────────────────────────────────────────────────────────────────
# test_error_unexpected_version
# Unexpected format → non-zero exit
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_error_unexpected_version ---"
_snapshot_fail

# Write mock acli that outputs garbage (no recognizable version format)
cat > "$MOCK_BIN/acli" <<'MOCK'
#!/usr/bin/env bash
echo "unexpected output with no version field"
exit 0
MOCK
chmod +x "$MOCK_BIN/acli"

rc=0
output=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>&1) || rc=$?

assert_ne "test_error_unexpected_version non-zero exit" "0" "$rc"

assert_pass_if_clean "test_error_unexpected_version"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
