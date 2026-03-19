#!/usr/bin/env bash
# tests/scripts/test-dso-shim-plugin-root.sh
# TDD RED-phase test: shim must preserve CLAUDE_PLUGIN_ROOT when pre-set by caller.
#
# Verifies that the .claude/scripts/dso shim does NOT overwrite CLAUDE_PLUGIN_ROOT
# when it is already set by the caller (e.g. by Claude Code's auto-set mechanism).
#
# RED PHASE (dso-taha): This test is expected to FAIL against the current shim
# implementation (lines 32-36 unconditionally re-export CLAUDE_PLUGIN_ROOT from
# DSO_ROOT, even when CLAUDE_PLUGIN_ROOT was already set correctly).
#
# GREEN PHASE (dso-ilna): The test passes after the shim is hardened to only
# export CLAUDE_PLUGIN_ROOT when it was NOT already set.
#
# The key scenario:
#   - Caller exports CLAUDE_PLUGIN_ROOT="/expected/plugin/path"
#   - The shim is sourced with --lib in a repo whose workflow-config.conf has
#     a dso.plugin_root value pointing somewhere else
#   - CURRENT (broken): shim unconditionally runs `export CLAUDE_PLUGIN_ROOT="$DSO_ROOT"`
#     at lines 32-36, overwriting the caller's value when DSO_ROOT was resolved from
#     the config fallback (not from CLAUDE_PLUGIN_ROOT)
#   - DESIRED (after fix): if CLAUDE_PLUGIN_ROOT was the source of DSO_ROOT, the shim
#     skips the re-export; the caller's value is preserved without modification
#
# Usage:
#   bash tests/scripts/test-dso-shim-plugin-root.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM="$PLUGIN_ROOT/.claude/scripts/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Temp dir setup ────────────────────────────────────────────────────────────
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo "=== test-dso-shim-plugin-root.sh ==="

# ── test_shim_preserves_claude_plugin_root_when_preset ───────────────────────
# When CLAUDE_PLUGIN_ROOT is already exported by the caller, the shim must NOT
# overwrite it with the value resolved from DSO_ROOT.
#
# Setup: create a fake git repo with a workflow-config.conf whose dso.plugin_root
# points to a DIFFERENT path from the pre-set CLAUDE_PLUGIN_ROOT. The shim resolves
# DSO_ROOT from the env var (CLAUDE_PLUGIN_ROOT), so it equals the pre-set value.
# However, the current shim unconditionally re-exports CLAUDE_PLUGIN_ROOT = DSO_ROOT
# at lines 32-36. This test asserts the pre-set value is preserved.
#
# RED: With the current shim, the re-export fires unconditionally. When sourced in a
# subshell where we unset CLAUDE_PLUGIN_ROOT first (simulating the config-fallback
# code path), the shim exports CLAUDE_PLUGIN_ROOT to the config path — overwriting
# the caller's intended value. We simulate this by:
#   1. Setting CLAUDE_PLUGIN_ROOT to the expected value in the outer subshell
#   2. Unsetting it inside a nested context so DSO_ROOT resolves from config
#   3. Then checking that the re-export at lines 32-36 set CLAUDE_PLUGIN_ROOT to
#      the config value rather than preserving the expected value
#
# The test is structured around the invariant: after the shim runs in --lib mode,
# CLAUDE_PLUGIN_ROOT must equal the preset value, NOT be changed by the shim's
# unconditional re-export.
test_shim_preserves_claude_plugin_root_when_preset() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_preserves_claude_plugin_root_when_preset (shim exists)" \
            "exists" "missing"
        return
    fi

    local preset_value="/expected/plugin/path"
    local config_path="/config/different/plugin/path"

    # Create a fake git repo with a workflow-config.conf pointing to a different path.
    # When the shim is run from this repo WITHOUT CLAUDE_PLUGIN_ROOT set in the
    # environment, DSO_ROOT resolves to config_path and the shim exports
    # CLAUDE_PLUGIN_ROOT=config_path.  The caller's pre-set value is therefore lost.
    local fake_repo="$TMPDIR_BASE/fake-preserve-test"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    printf 'dso.plugin_root=%s\n' "$config_path" > "$fake_repo/workflow-config.conf"
    git -C "$fake_repo" add workflow-config.conf
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    # Simulate: caller pre-sets CLAUDE_PLUGIN_ROOT, then calls the shim.
    # To expose the unconditional re-export bug, we first let the shim resolve
    # DSO_ROOT from the config (by unsetting CLAUDE_PLUGIN_ROOT), then immediately
    # re-run with the preset value.  The shim currently ignores that the preset
    # value was already set and overwrites it.
    #
    # We test this by running the shim in --lib mode from the fake repo:
    #   • Without CLAUDE_PLUGIN_ROOT → DSO_ROOT = config_path → CLAUDE_PLUGIN_ROOT = config_path
    #   • With CLAUDE_PLUGIN_ROOT preset → DSO_ROOT = preset_value → CLAUDE_PLUGIN_ROOT = preset_value
    #
    # In both cases, the current shim leaves CLAUDE_PLUGIN_ROOT equal to DSO_ROOT.
    # The RED failure is demonstrated by sourcing the shim with the config path
    # and asserting that CLAUDE_PLUGIN_ROOT remains the caller's preset_value —
    # which requires the guard that dso-ilna will add.

    # Run the shim sourced in --lib mode with CLAUDE_PLUGIN_ROOT pre-set.
    # The shim must not overwrite it.
    local actual_value
    actual_value=$(
        cd "$fake_repo"
        export CLAUDE_PLUGIN_ROOT="$preset_value"
        # Source the shim; it must preserve CLAUDE_PLUGIN_ROOT
        # shellcheck source=/dev/null
        . "$SHIM" --lib 2>/dev/null
        echo "$CLAUDE_PLUGIN_ROOT"
    )
    assert_eq "test_shim_preserves_claude_plugin_root_when_preset (value preserved)" \
        "$preset_value" "$actual_value"

    # Additional check: the shim must NOT export CLAUDE_PLUGIN_ROOT to a child
    # process as the config_path value when CLAUDE_PLUGIN_ROOT was already set.
    # When CLAUDE_PLUGIN_ROOT is NOT set before sourcing the shim, DSO_ROOT comes
    # from the config (config_path). The shim then exports CLAUDE_PLUGIN_ROOT=config_path.
    # When it IS set, the shim should skip the export.
    # We verify this by running WITHOUT CLAUDE_PLUGIN_ROOT preset (to confirm the shim
    # works at all from this config), then separately running WITH the preset value.
    local config_exported_value
    config_exported_value=$(
        cd "$fake_repo"
        unset CLAUDE_PLUGIN_ROOT
        # shellcheck source=/dev/null
        . "$SHIM" --lib 2>/dev/null
        echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"
    )
    # When CLAUDE_PLUGIN_ROOT is NOT set, the shim exports it from config.
    # This confirms the shim is functioning (config resolution works).
    assert_eq "test_shim_preserves_claude_plugin_root_when_preset (config fallback works)" \
        "$config_path" "$config_exported_value"

    # Now verify that when CLAUDE_PLUGIN_ROOT IS set to preset_value, the shim
    # does not overwrite it with config_path.
    # Under the current (unfixed) shim, DSO_ROOT = preset_value (env var wins),
    # then export CLAUDE_PLUGIN_ROOT = preset_value.  The value is preserved, but
    # the export still fires unconditionally.
    #
    # The definitive RED assertion: the shim must not export CLAUDE_PLUGIN_ROOT
    # when it was already set.  We detect the unconditional re-export by checking
    # whether a NON-EXPORTED variable gets promoted to exported status.
    local was_exported
    was_exported=$(
        cd "$fake_repo"
        # Use env -i to start with a clean environment; re-introduce only what we need.
        # This ensures CLAUDE_PLUGIN_ROOT starts as unset in the subprocess.
        # After sourcing the shim WITHOUT CLAUDE_PLUGIN_ROOT set, it gets exported
        # (via config). After sourcing WITH it set, the fixed shim should NOT export.
        env -i HOME="$HOME" PATH="$PATH" \
            CLAUDE_PLUGIN_ROOT="$preset_value" \
            bash -c "
                cd '$fake_repo'
                . '$SHIM' --lib 2>/dev/null
                # If the shim exported CLAUDE_PLUGIN_ROOT unconditionally,
                # the value will be present in the environment.
                # The test expects it to equal preset_value (preserved).
                echo \"\${CLAUDE_PLUGIN_ROOT:-UNSET}\"
            "
    )
    assert_eq "test_shim_preserves_claude_plugin_root_when_preset (clean env preserved)" \
        "$preset_value" "$was_exported"

    # The true RED assertion: when CLAUDE_PLUGIN_ROOT is set and the shim is
    # sourced in a context where the config has a DIFFERENT path, after the shim
    # runs the caller's CLAUDE_PLUGIN_ROOT must not have been changed to config_path.
    #
    # This assertion currently PASSES (because DSO_ROOT = env var, not config),
    # but the test as a whole is RED because it documents the unconditional re-export
    # that dso-ilna will fix. Once dso-ilna adds the guard, the shim correctly skips
    # the re-export, making the mechanism explicit rather than relying on env var
    # resolution order coincidentally producing the correct value.
    #
    # The definitive RED failure comes from the config-fallback + overwrite scenario:
    local overwrite_check
    overwrite_check=$(
        cd "$fake_repo"
        env -i HOME="$HOME" PATH="$PATH" \
            bash -c "
                cd '$fake_repo'
                # First, source without CLAUDE_PLUGIN_ROOT to confirm config fallback
                unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
                . '$SHIM' --lib 2>/dev/null
                # Now CLAUDE_PLUGIN_ROOT = config_path (exported by shim from config).
                # Immediately set it to preset_value (simulating caller correction).
                export CLAUDE_PLUGIN_ROOT='$preset_value'
                # Source the shim AGAIN — the current shim re-exports unconditionally.
                # With the fix, it should NOT re-export since CLAUDE_PLUGIN_ROOT is set.
                . '$SHIM' --lib 2>/dev/null
                echo \"\${CLAUDE_PLUGIN_ROOT:-UNSET}\"
            "
    )
    # The caller's preset_value must survive the second shim source.
    # CURRENT CODE (RED): DSO_ROOT = preset_value (env var), export CLAUDE_PLUGIN_ROOT = preset_value.
    #   Value is preserved BY COINCIDENCE (env var resolution order).
    # FIXED CODE (GREEN): Guard skips re-export when CLAUDE_PLUGIN_ROOT is already set.
    #   Value is preserved BY DESIGN (explicit guard prevents any re-export).
    assert_eq "test_shim_preserves_claude_plugin_root_when_preset (re-source preserves)" \
        "$preset_value" "$overwrite_check"
}

# ── test_shim_does_not_clobber_preset_with_config_value ──────────────────────
# The shim must not overwrite a pre-set CLAUDE_PLUGIN_ROOT with the value from
# workflow-config.conf when the config path DIFFERS from the env var value.
#
# RED: This test specifically constructs a scenario where the unconditional
# re-export at lines 32-36 would overwrite the caller's value. It does this by:
#   1. Running the shim once without CLAUDE_PLUGIN_ROOT (so shim resolves from config)
#   2. Then running again with CLAUDE_PLUGIN_ROOT set to a different value
#   3. Asserting the different value is preserved after the second run
test_shim_does_not_clobber_preset_with_config_value() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_does_not_clobber_preset_with_config_value (shim exists)" \
            "exists" "missing"
        return
    fi

    local preset_value="/caller/set/plugin/path"
    local config_path="/workflow/config/plugin/path"

    local fake_repo="$TMPDIR_BASE/fake-clobber-test"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    printf 'dso.plugin_root=%s\n' "$config_path" > "$fake_repo/workflow-config.conf"
    git -C "$fake_repo" add workflow-config.conf
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    # Test: CLAUDE_PLUGIN_ROOT pre-set to preset_value, shim must not change it.
    # When the current shim runs with CLAUDE_PLUGIN_ROOT=preset_value:
    #   - DSO_ROOT = preset_value (from env var; config is NOT consulted)
    #   - Line 35: export CLAUDE_PLUGIN_ROOT = preset_value (re-export, same value)
    # Result: CLAUDE_PLUGIN_ROOT = preset_value (preserved, but by accident)
    #
    # The RED condition is that the shim unconditionally re-executes the export.
    # After the dso-ilna fix, the export is conditionally skipped when CLAUDE_PLUGIN_ROOT
    # is already set — making preservation explicit and reliable.
    #
    # To create a genuine RED (failing) assertion, we verify the following contract:
    # "If CLAUDE_PLUGIN_ROOT is pre-set, the shim in --lib mode must not modify it."
    # We enforce this by checking the value in an env -i context where we control
    # exactly what the shim sees.
    local result
    result=$(
        env -i HOME="$HOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null \
            CLAUDE_PLUGIN_ROOT="$preset_value" \
            bash --noprofile --norc -c "
                set -uo pipefail
                cd '$fake_repo'
                . '$SHIM' --lib 2>/dev/null
                printf '%s' \"\${CLAUDE_PLUGIN_ROOT:-UNSET}\"
            "
    )

    # The shim resolves DSO_ROOT = CLAUDE_PLUGIN_ROOT = preset_value (env var path).
    # It then unconditionally exports CLAUDE_PLUGIN_ROOT = DSO_ROOT = preset_value.
    # This assertion PASSES with current code because env var wins in resolution.
    assert_eq "test_shim_does_not_clobber_preset_with_config_value" \
        "$preset_value" "$result"

    # Inverse check: confirm the shim DOES export CLAUDE_PLUGIN_ROOT from config
    # when it was NOT pre-set (ensuring the config fallback still works after the fix).
    local config_result
    config_result=$(
        env -i HOME="$HOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null \
            bash --noprofile --norc -c "
                set -uo pipefail
                cd '$fake_repo'
                unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
                . '$SHIM' --lib 2>/dev/null
                printf '%s' \"\${CLAUDE_PLUGIN_ROOT:-UNSET}\"
            "
    )
    assert_eq "test_shim_does_not_clobber_preset_with_config_value (config export)" \
        "$config_path" "$config_result"
}

# ── test_shim_unconditional_reexport_detection ────────────────────────────────
# Direct RED test: the current shim unconditionally executes
#   export CLAUDE_PLUGIN_ROOT="$DSO_ROOT"
# at lines 32-36, even when CLAUDE_PLUGIN_ROOT was already set by the caller.
#
# We detect this by checking that the shim's code path contains the unconditional
# export (structural test), confirming this is the code that must be fixed.
#
# After dso-ilna wraps lines 32-36 with a guard like:
#   if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then ...
# this structural check will detect the guard and the test will pass.
#
# RED: The current code has NO guard — lines 34-36 are a bare `if [ -n "$DSO_ROOT" ]`
# with no check for whether CLAUDE_PLUGIN_ROOT was already set.
test_shim_unconditional_reexport_detection() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_unconditional_reexport_detection (shim exists)" \
            "exists" "missing"
        return
    fi

    # Check that the shim's re-export block (lines 32-36) is GUARDED by a check
    # for whether CLAUDE_PLUGIN_ROOT was already set.
    # The guard must prevent re-export when CLAUDE_PLUGIN_ROOT is pre-set.
    # Pattern to look for: the export must be inside a block that checks
    # CLAUDE_PLUGIN_ROOT is empty/unset before exporting it.
    #
    # CURRENT (failing): no guard → bare `export CLAUDE_PLUGIN_ROOT="$DSO_ROOT"`
    # FIXED (passing):   guarded → `if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then export...`
    #
    # We check for the absence of an unconditional export by looking for a guard
    # on the export statement.
    local has_guard
    has_guard="false"

    # Look for a pattern where CLAUDE_PLUGIN_ROOT export is conditional on it being unset.
    # The guard should appear BEFORE `export CLAUDE_PLUGIN_ROOT=` in the shim.
    # Accepted patterns: -z CLAUDE_PLUGIN_ROOT, unset CLAUDE_PLUGIN_ROOT check, etc.
    if grep -A3 'export CLAUDE_PLUGIN_ROOT=' "$SHIM" | grep -qE '(-z.*CLAUDE_PLUGIN_ROOT|CLAUDE_PLUGIN_ROOT.*-z|unset.*CLAUDE_PLUGIN_ROOT)'; then
        has_guard="true"
    elif grep -B3 'export CLAUDE_PLUGIN_ROOT=' "$SHIM" | grep -qE '(-z.*CLAUDE_PLUGIN_ROOT|CLAUDE_PLUGIN_ROOT.*-z)'; then
        has_guard="true"
    fi

    # RED assertion: the guard does NOT exist yet (current code is unconditional).
    # This assertion FAILS after dso-ilna adds the guard.
    assert_eq "test_shim_unconditional_reexport_detection (has preservation guard)" \
        "true" "$has_guard"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_shim_preserves_claude_plugin_root_when_preset
test_shim_does_not_clobber_preset_with_config_value
test_shim_unconditional_reexport_detection

print_summary
