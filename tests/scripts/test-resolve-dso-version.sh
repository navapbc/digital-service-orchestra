#!/usr/bin/env bash
# tests/scripts/test-resolve-dso-version.sh
# Behavioral tests for plugins/dso/scripts/resolve-dso-version.sh
#
# Tests use env-var overrides (PLUGIN_TRACKING_FILE, DSO_CONFIG_FILE,
# MARKETPLACE_JSON) documented in the script header. Each test invokes the
# script and asserts on observable outputs (stdout lines, exit codes).
#
# RED marker: test_resolve_tier1_placeholder
# The comprehensive test suite covering all Tier 1/2/3 paths, URL security
# rejection, and all-tiers-failed diagnostics is tracked in task 58ca-0786.
# Tests at and after test_resolve_tier1_placeholder are tolerated as failing
# until 58ca-0786 is implemented.
#
# Usage: bash tests/scripts/test-resolve-dso-version.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/resolve-dso-version.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-resolve-dso-version.sh ==="

# ── Setup ─────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── test_resolver_exits_nonzero_when_no_sources ───────────────────────────────
# Call the script with all tier sources pointing to nonexistent files.
# Expected: exits non-zero and emits an error diagnostic to stderr.
echo ""
echo "--- test_resolver_exits_nonzero_when_no_sources ---"
_snapshot_fail

rc=0
stderr_out=$(
    PLUGIN_TRACKING_FILE="$TMPDIR_TEST/no-such-installed-plugins.json" \
    DSO_CONFIG_FILE="$TMPDIR_TEST/no-such-dso-config.conf" \
    MARKETPLACE_JSON="$TMPDIR_TEST/no-such-marketplace.json" \
    bash "$SCRIPT" 2>&1 >/dev/null
) || rc=$?

assert_ne "test_resolver_exits_nonzero_when_no_sources exit code" "0" "$rc"
assert_contains "test_resolver_exits_nonzero_when_no_sources stderr diagnostic" \
    "failed to resolve DSO version" "$stderr_out"

assert_pass_if_clean "test_resolver_exits_nonzero_when_no_sources"

# ── test_resolver_tier3_resolves_version_from_marketplace_json ────────────────
# Given a minimal valid marketplace.json with a dso channel pointing to a
# canonical URL, the script should emit RESOLVED_VERSION=, RESOLVED_TIER=3,
# and RESOLVED_SOURCE= on stdout and exit 0.
echo ""
echo "--- test_resolver_tier3_resolves_version_from_marketplace_json ---"
_snapshot_fail

MARKETPLACE_FILE="$TMPDIR_TEST/marketplace.json"
cat > "$MARKETPLACE_FILE" <<'JSON'
{
  "plugins": [
    {
      "name": "dso",
      "source": {
        "source": "git-subdir",
        "url": "https://github.com/navapbc/digital-service-orchestra.git",
        "path": "plugins/dso",
        "ref": "v1.13.0"
      }
    }
  ]
}
JSON

rc=0
stdout_out=$(
    PLUGIN_TRACKING_FILE="$TMPDIR_TEST/no-such-installed-plugins.json" \
    DSO_CONFIG_FILE="$TMPDIR_TEST/no-such-dso-config.conf" \
    MARKETPLACE_JSON="$MARKETPLACE_FILE" \
    bash "$SCRIPT" 2>/dev/null
) || rc=$?

assert_eq "test_resolver_tier3_resolves_version exit code" "0" "$rc"
assert_contains "test_resolver_tier3_resolves_version RESOLVED_VERSION line" \
    "RESOLVED_VERSION=v1.13.0" "$stdout_out"
assert_contains "test_resolver_tier3_resolves_version RESOLVED_TIER line" \
    "RESOLVED_TIER=3" "$stdout_out"
assert_contains "test_resolver_tier3_resolves_version RESOLVED_SOURCE line" \
    "RESOLVED_SOURCE=" "$stdout_out"

assert_pass_if_clean "test_resolver_tier3_resolves_version_from_marketplace_json"

# ── test_resolver_rejects_invalid_url_security ────────────────────────────────
# Given a marketplace.json with a non-canonical URL (e.g., attacker-controlled
# mirror), the script must exit non-zero and emit a SECURITY message to stderr.
echo ""
echo "--- test_resolver_rejects_invalid_url_security ---"
_snapshot_fail

BAD_MARKETPLACE_FILE="$TMPDIR_TEST/bad-marketplace.json"
cat > "$BAD_MARKETPLACE_FILE" <<'JSON'
{
  "plugins": [
    {
      "name": "dso",
      "source": {
        "source": "git-subdir",
        "url": "https://github.com/attacker/malicious-fork.git",
        "path": "plugins/dso",
        "ref": "v1.13.0"
      }
    }
  ]
}
JSON

rc=0
stderr_sec=$(
    PLUGIN_TRACKING_FILE="$TMPDIR_TEST/no-such-installed-plugins.json" \
    DSO_CONFIG_FILE="$TMPDIR_TEST/no-such-dso-config.conf" \
    MARKETPLACE_JSON="$BAD_MARKETPLACE_FILE" \
    bash "$SCRIPT" 2>&1 >/dev/null
) || rc=$?

assert_ne "test_resolver_rejects_invalid_url_security exit code" "0" "$rc"
assert_contains "test_resolver_rejects_invalid_url_security SECURITY message" \
    "SECURITY" "$stderr_sec"

assert_pass_if_clean "test_resolver_rejects_invalid_url_security"

# ── test_resolve_tier1_placeholder ───────────────────────────────────────────
# RED: Comprehensive tier 1/2 installed_plugins.json parsing tests are pending
# task 58ca-0786. This placeholder marks the RED boundary so the test gate
# tolerates all tests at or after this function as failing until that task lands.
echo ""
echo "--- test_resolve_tier1_placeholder ---"
_snapshot_fail
# RED: Tier 1 installed_plugins.json parsing tests pending task 58ca-0786
echo "RED: test_resolve_tier1_placeholder — comprehensive tier tests pending task 58ca-0786" >&2
assert_eq "test_resolve_tier1_placeholder: RED placeholder — tier 1/2 tests pending task 58ca-0786" \
    "implemented" "pending"
assert_pass_if_clean "test_resolve_tier1_placeholder"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
