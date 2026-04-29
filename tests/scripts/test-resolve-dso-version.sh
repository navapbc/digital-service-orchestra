#!/usr/bin/env bash
# tests/scripts/test-resolve-dso-version.sh
# Behavioral tests for plugins/dso/scripts/resolve-dso-version.sh
#
# Tests use env-var overrides (PLUGIN_TRACKING_FILE, DSO_CONFIG_FILE,
# MARKETPLACE_JSON) documented in the script header. Each test invokes the
# script and asserts on observable outputs (stdout lines, exit codes).
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

# ── test_resolver_all_tiers_failed_names_each_tier ────────────────────────────
# When all tiers fail, stderr must name each tier's failure reason so the user
# can diagnose which tier(s) are misconfigured.
echo ""
echo "--- test_resolver_all_tiers_failed_names_each_tier ---"
_snapshot_fail

rc=0
stderr_diag=$(
    PLUGIN_TRACKING_FILE="$TMPDIR_TEST/no-such-installed-plugins.json" \
    DSO_CONFIG_FILE="$TMPDIR_TEST/no-such-dso-config.conf" \
    MARKETPLACE_JSON="$TMPDIR_TEST/no-such-marketplace.json" \
    bash "$SCRIPT" 2>&1 >/dev/null
) || rc=$?

assert_ne "test_resolver_all_tiers_failed_names_each_tier exit code" "0" "$rc"
assert_contains "test_resolver_all_tiers_failed_names_each_tier tier1 mention" \
    "Tier 1" "$stderr_diag"
assert_contains "test_resolver_all_tiers_failed_names_each_tier tier2 mention" \
    "Tier 2" "$stderr_diag"
assert_contains "test_resolver_all_tiers_failed_names_each_tier tier3 mention" \
    "Tier 3" "$stderr_diag"

assert_pass_if_clean "test_resolver_all_tiers_failed_names_each_tier"

# ── test_resolver_tier1_hit ───────────────────────────────────────────────────
# Given a minimal valid installed_plugins.json that contains a dso entry with
# a version, the script should emit RESOLVED_VERSION= from Tier 1,
# RESOLVED_TIER=1, and RESOLVED_SOURCE= on stdout and exit 0.
echo ""
echo "--- test_resolver_tier1_hit ---"
_snapshot_fail

TRACKING_FILE="$TMPDIR_TEST/installed_plugins.json"
cat > "$TRACKING_FILE" <<'JSON'
{
  "plugins": {
    "dso@digital-service-orchestra": [
      {
        "version": "v1.12.0",
        "installPath": "/mock-home/.claude/plugins/dso",
        "lastUpdated": "2026-01-15T10:00:00Z"
      }
    ]
  }
}
JSON

rc=0
stdout_t1=$(
    PLUGIN_TRACKING_FILE="$TRACKING_FILE" \
    DSO_CONFIG_FILE="$TMPDIR_TEST/no-such-dso-config.conf" \
    MARKETPLACE_JSON="$TMPDIR_TEST/no-such-marketplace.json" \
    bash "$SCRIPT" 2>/dev/null
) || rc=$?

assert_eq "test_resolver_tier1_hit exit code" "0" "$rc"
assert_contains "test_resolver_tier1_hit RESOLVED_VERSION line" \
    "RESOLVED_VERSION=v1.12.0" "$stdout_t1"
assert_contains "test_resolver_tier1_hit RESOLVED_TIER line" \
    "RESOLVED_TIER=1" "$stdout_t1"
assert_contains "test_resolver_tier1_hit RESOLVED_SOURCE line" \
    "RESOLVED_SOURCE=" "$stdout_t1"

assert_pass_if_clean "test_resolver_tier1_hit"

# ── test_resolver_tier1_miss_tier2_hit ────────────────────────────────────────
# When installed_plugins.json is absent (Tier 1 miss) and dso-config.conf
# contains ci.dso_plugin_version, the script should emit RESOLVED_TIER=2.
echo ""
echo "--- test_resolver_tier1_miss_tier2_hit ---"
_snapshot_fail

CONFIG_FILE="$TMPDIR_TEST/dso-config.conf"
cat > "$CONFIG_FILE" <<'CONF'
# DSO config file
ci.dso_plugin_version=v1.11.5
CONF

rc=0
stdout_t2=$(
    PLUGIN_TRACKING_FILE="$TMPDIR_TEST/no-such-installed-plugins.json" \
    DSO_CONFIG_FILE="$CONFIG_FILE" \
    MARKETPLACE_JSON="$TMPDIR_TEST/no-such-marketplace.json" \
    bash "$SCRIPT" 2>/dev/null
) || rc=$?

assert_eq "test_resolver_tier1_miss_tier2_hit exit code" "0" "$rc"
assert_contains "test_resolver_tier1_miss_tier2_hit RESOLVED_VERSION line" \
    "RESOLVED_VERSION=v1.11.5" "$stdout_t2"
assert_contains "test_resolver_tier1_miss_tier2_hit RESOLVED_TIER line" \
    "RESOLVED_TIER=2" "$stdout_t2"
assert_contains "test_resolver_tier1_miss_tier2_hit RESOLVED_SOURCE line" \
    "RESOLVED_SOURCE=" "$stdout_t2"

assert_pass_if_clean "test_resolver_tier1_miss_tier2_hit"

# ── test_resolver_tier1_no_dso_entry_tier2_hit ────────────────────────────────
# When installed_plugins.json exists but has no dso key (Tier 1 miss),
# Tier 2 should be used if ci.dso_plugin_version is set.
echo ""
echo "--- test_resolver_tier1_no_dso_entry_tier2_hit ---"
_snapshot_fail

TRACKING_EMPTY="$TMPDIR_TEST/installed_plugins_empty.json"
cat > "$TRACKING_EMPTY" <<'JSON'
{
  "plugins": {}
}
JSON

CONFIG_FILE2="$TMPDIR_TEST/dso-config2.conf"
cat > "$CONFIG_FILE2" <<'CONF'
ci.dso_plugin_version=v1.10.0
CONF

rc=0
stdout_t2b=$(
    PLUGIN_TRACKING_FILE="$TRACKING_EMPTY" \
    DSO_CONFIG_FILE="$CONFIG_FILE2" \
    MARKETPLACE_JSON="$TMPDIR_TEST/no-such-marketplace.json" \
    bash "$SCRIPT" 2>/dev/null
) || rc=$?

assert_eq "test_resolver_tier1_no_dso_entry_tier2_hit exit code" "0" "$rc"
assert_contains "test_resolver_tier1_no_dso_entry_tier2_hit RESOLVED_VERSION" \
    "RESOLVED_VERSION=v1.10.0" "$stdout_t2b"
assert_contains "test_resolver_tier1_no_dso_entry_tier2_hit RESOLVED_TIER=2" \
    "RESOLVED_TIER=2" "$stdout_t2b"

assert_pass_if_clean "test_resolver_tier1_no_dso_entry_tier2_hit"

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

# ── test_resolver_tier3_rejects_dso_dev_channel ───────────────────────────────
# When marketplace.json contains only the dso-dev channel (no stable dso),
# the script must exit non-zero — it must NOT use the dev channel ref.
echo ""
echo "--- test_resolver_tier3_rejects_dso_dev_channel ---"
_snapshot_fail

DEV_MARKETPLACE="$TMPDIR_TEST/dev-marketplace.json"
cat > "$DEV_MARKETPLACE" <<'JSON'
{
  "plugins": [
    {
      "name": "dso-dev",
      "source": {
        "source": "git-subdir",
        "url": "https://github.com/navapbc/digital-service-orchestra.git",
        "path": "plugins/dso",
        "ref": "main"
      }
    }
  ]
}
JSON

rc=0
stderr_dev=$(
    PLUGIN_TRACKING_FILE="$TMPDIR_TEST/no-such-installed-plugins.json" \
    DSO_CONFIG_FILE="$TMPDIR_TEST/no-such-dso-config.conf" \
    MARKETPLACE_JSON="$DEV_MARKETPLACE" \
    bash "$SCRIPT" 2>&1 >/dev/null
) || rc=$?

assert_ne "test_resolver_tier3_rejects_dso_dev_channel exit code" "0" "$rc"
# stderr should mention the failure (either missing dso channel or all-tiers error)
assert_contains "test_resolver_tier3_rejects_dso_dev_channel stderr message" \
    "failed to resolve DSO version" "$stderr_dev"

assert_pass_if_clean "test_resolver_tier3_rejects_dso_dev_channel"

# ── test_resolver_tier3_malformed_no_ref ─────────────────────────────────────
# When marketplace.json has a dso entry but source.ref is missing/empty,
# the script must exit non-zero with an explicit error.
echo ""
echo "--- test_resolver_tier3_malformed_no_ref ---"
_snapshot_fail

MALFORMED_MARKETPLACE="$TMPDIR_TEST/malformed-marketplace.json"
cat > "$MALFORMED_MARKETPLACE" <<'JSON'
{
  "plugins": [
    {
      "name": "dso",
      "source": {
        "source": "git-subdir",
        "url": "https://github.com/navapbc/digital-service-orchestra.git",
        "path": "plugins/dso"
      }
    }
  ]
}
JSON

rc=0
stderr_mal=$(
    PLUGIN_TRACKING_FILE="$TMPDIR_TEST/no-such-installed-plugins.json" \
    DSO_CONFIG_FILE="$TMPDIR_TEST/no-such-dso-config.conf" \
    MARKETPLACE_JSON="$MALFORMED_MARKETPLACE" \
    bash "$SCRIPT" 2>&1 >/dev/null
) || rc=$?

assert_ne "test_resolver_tier3_malformed_no_ref exit code" "0" "$rc"
assert_contains "test_resolver_tier3_malformed_no_ref stderr message" \
    "failed to resolve DSO version" "$stderr_mal"

assert_pass_if_clean "test_resolver_tier3_malformed_no_ref"

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

# ── test_resolver_tier1_picks_most_recent_entry ───────────────────────────────
# When installed_plugins.json has multiple entries for the dso key, the script
# should pick the one with the latest lastUpdated timestamp.
echo ""
echo "--- test_resolver_tier1_picks_most_recent_entry ---"
_snapshot_fail

TRACKING_MULTI="$TMPDIR_TEST/installed_plugins_multi.json"
cat > "$TRACKING_MULTI" <<'JSON'
{
  "plugins": {
    "dso@digital-service-orchestra": [
      {
        "version": "v1.11.0",
        "installPath": "/mock-home/.claude/plugins/dso-old",
        "lastUpdated": "2026-01-01T10:00:00Z"
      },
      {
        "version": "v1.14.0",
        "installPath": "/mock-home/.claude/plugins/dso-new",
        "lastUpdated": "2026-03-01T10:00:00Z"
      }
    ]
  }
}
JSON

rc=0
stdout_multi=$(
    PLUGIN_TRACKING_FILE="$TRACKING_MULTI" \
    DSO_CONFIG_FILE="$TMPDIR_TEST/no-such-dso-config.conf" \
    MARKETPLACE_JSON="$TMPDIR_TEST/no-such-marketplace.json" \
    bash "$SCRIPT" 2>/dev/null
) || rc=$?

assert_eq "test_resolver_tier1_picks_most_recent_entry exit code" "0" "$rc"
assert_contains "test_resolver_tier1_picks_most_recent_entry RESOLVED_VERSION" \
    "RESOLVED_VERSION=v1.14.0" "$stdout_multi"
assert_contains "test_resolver_tier1_picks_most_recent_entry RESOLVED_TIER=1" \
    "RESOLVED_TIER=1" "$stdout_multi"

assert_pass_if_clean "test_resolver_tier1_picks_most_recent_entry"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
