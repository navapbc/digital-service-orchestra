#!/usr/bin/env bash
# tests/scripts/test-resolve-model-id.sh
# TDD tests for plugins/dso/scripts/resolve-model-id.sh
#
# Verifies that resolve-model-id.sh reads model tier keys (model.haiku,
# model.sonnet, model.opus) from a dso-config.conf and outputs the correct
# model ID for the requested tier.
#
# Tests use temp-dir fixture configs — never reads the real dso-config.conf.
#
# Usage: bash tests/scripts/test-resolve-model-id.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# TDD status: RED — resolve-model-id.sh does not exist yet.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/resolve-model-id.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-resolve-model-id.sh ==="

# ── Setup: temp dir with fixture configs ─────────────────────────────────────
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# Full config — all three model.* keys present
FULL_CONF="$TMPDIR_FIXTURE/full.conf"
cat > "$FULL_CONF" <<'CONF'
version=1.0.0
model.haiku=claude-haiku-4-5-20251022
model.sonnet=claude-sonnet-4-6-20260320
model.opus=claude-opus-4-5-20260101
CONF

# Missing opus config
NO_OPUS_CONF="$TMPDIR_FIXTURE/no-opus.conf"
cat > "$NO_OPUS_CONF" <<'CONF'
version=1.0.0
model.haiku=claude-haiku-4-5-20251022
model.sonnet=claude-sonnet-4-6-20260320
CONF

# No model keys at all
NO_MODEL_CONF="$TMPDIR_FIXTURE/no-model.conf"
cat > "$NO_MODEL_CONF" <<'CONF'
version=1.0.0
commands.test=make test
CONF

# ─────────────────────────────────────────────────────────────────────────────
# test_all_tiers_exit_zero
# Config with all three model.* keys — each tier lookup must exit 0
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_all_tiers_exit_zero ---"
test_all_tiers_exit_zero() {
    local tier rc
    for tier in haiku sonnet opus; do
        rc=0
        bash "$SCRIPT" "$tier" "$FULL_CONF" >/dev/null 2>&1 || rc=$?
        assert_eq "test_all_tiers_exit_zero: tier=$tier exits 0" "0" "$rc"
    done
}
_snapshot_fail
test_all_tiers_exit_zero
assert_pass_if_clean "test_all_tiers_exit_zero"

# ─────────────────────────────────────────────────────────────────────────────
# test_all_tiers_correct_model_id
# Config with all three model.* keys — each tier returns the correct model ID
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_all_tiers_correct_model_id ---"
test_all_tiers_correct_model_id() {
    local output_haiku output_sonnet output_opus
    output_haiku=$(bash "$SCRIPT" haiku "$FULL_CONF" 2>/dev/null)
    assert_eq "test_all_tiers_correct_model_id: haiku ID" "claude-haiku-4-5-20251022" "$output_haiku"

    output_sonnet=$(bash "$SCRIPT" sonnet "$FULL_CONF" 2>/dev/null)
    assert_eq "test_all_tiers_correct_model_id: sonnet ID" "claude-sonnet-4-6-20260320" "$output_sonnet"

    output_opus=$(bash "$SCRIPT" opus "$FULL_CONF" 2>/dev/null)
    assert_eq "test_all_tiers_correct_model_id: opus ID" "claude-opus-4-5-20260101" "$output_opus"
}
_snapshot_fail
test_all_tiers_correct_model_id
assert_pass_if_clean "test_all_tiers_correct_model_id"

# ─────────────────────────────────────────────────────────────────────────────
# test_missing_opus_exits_nonzero
# Config missing model.opus — requesting opus tier must exit non-zero
# with an error message mentioning "model.opus"
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_missing_opus_exits_nonzero ---"
test_missing_opus_exits_nonzero() {
    local rc=0 err_output
    err_output=$(bash "$SCRIPT" opus "$NO_OPUS_CONF" 2>&1) || rc=$?
    assert_ne "test_missing_opus_exits_nonzero: exits non-zero" "0" "$rc"
    assert_contains "test_missing_opus_exits_nonzero: error mentions model.opus" "model.opus" "$err_output"
}
_snapshot_fail
test_missing_opus_exits_nonzero
assert_pass_if_clean "test_missing_opus_exits_nonzero"

# ─────────────────────────────────────────────────────────────────────────────
# test_no_model_keys_exits_nonzero
# Config with no model.* keys — any tier lookup must exit non-zero
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_no_model_keys_exits_nonzero ---"
test_no_model_keys_exits_nonzero() {
    local rc=0
    bash "$SCRIPT" haiku "$NO_MODEL_CONF" >/dev/null 2>&1 || rc=$?
    assert_ne "test_no_model_keys_exits_nonzero: exits non-zero" "0" "$rc"
}
_snapshot_fail
test_no_model_keys_exits_nonzero
assert_pass_if_clean "test_no_model_keys_exits_nonzero"

# ─────────────────────────────────────────────────────────────────────────────
# test_invalid_tier_exits_nonzero
# Unrecognized tier name — must exit non-zero
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_invalid_tier_exits_nonzero ---"
test_invalid_tier_exits_nonzero() {
    local rc=0
    bash "$SCRIPT" gpt4 "$FULL_CONF" >/dev/null 2>&1 || rc=$?
    assert_ne "test_invalid_tier_exits_nonzero: exits non-zero for unknown tier" "0" "$rc"
}
_snapshot_fail
test_invalid_tier_exits_nonzero
assert_pass_if_clean "test_invalid_tier_exits_nonzero"

# ─────────────────────────────────────────────────────────────────────────────
# test_sonnet_returns_sonnet_not_haiku
# Tier "sonnet" must return the sonnet model ID, not the haiku model ID
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_sonnet_returns_sonnet_not_haiku ---"
test_sonnet_returns_sonnet_not_haiku() {
    local output
    output=$(bash "$SCRIPT" sonnet "$FULL_CONF" 2>/dev/null)
    assert_eq "test_sonnet_returns_sonnet_not_haiku: value is sonnet ID" "claude-sonnet-4-6-20260320" "$output"
    assert_ne "test_sonnet_returns_sonnet_not_haiku: value is not haiku ID" "claude-haiku-4-5-20251022" "$output"
}
_snapshot_fail
test_sonnet_returns_sonnet_not_haiku
assert_pass_if_clean "test_sonnet_returns_sonnet_not_haiku"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
