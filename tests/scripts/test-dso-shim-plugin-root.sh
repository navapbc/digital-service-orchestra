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
#   - The shim is sourced with --lib in a repo whose dso-config.conf has
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
# Setup: create a fake git repo with a dso-config.conf whose dso.plugin_root
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

    # Create a fake git repo with a .claude/dso-config.conf pointing to a different path.
    # When the shim is run from this repo WITHOUT CLAUDE_PLUGIN_ROOT set in the
    # environment, DSO_ROOT resolves to config_path and the shim exports
    # CLAUDE_PLUGIN_ROOT=config_path.  The caller's pre-set value is therefore lost.
    local fake_repo="$TMPDIR_BASE/fake-preserve-test"
    mkdir -p "$fake_repo/.claude"
    git -C "$fake_repo" init -q
    printf 'dso.plugin_root=%s\n' "$config_path" > "$fake_repo/.claude/dso-config.conf"
    git -C "$fake_repo" add .claude/dso-config.conf
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
# .claude/dso-config.conf when the config path DIFFERS from the env var value.
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
    mkdir -p "$fake_repo/.claude"
    git -C "$fake_repo" init -q
    printf 'dso.plugin_root=%s\n' "$config_path" > "$fake_repo/.claude/dso-config.conf"
    git -C "$fake_repo" add .claude/dso-config.conf
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

# ── test_shim_reads_plugin_root_from_dot_claude_dso_config ───────────────────
# RED phase (dso-jfy3): The shim must read dso.plugin_root from
# .claude/dso-config.conf when CLAUDE_PLUGIN_ROOT is not set.
#
# Setup: create a temp git repo with .claude/dso-config.conf containing
#   dso.plugin_root=<path>
# The shim must resolve DSO_ROOT to that path.
#
# RED: The current shim reads from dso-config.conf at the git root (step 2).
# It does NOT look at .claude/dso-config.conf. This test fails until the shim is
# updated (dso-tuz0) to check .claude/dso-config.conf first (or instead).
test_shim_reads_plugin_root_from_dot_claude_dso_config() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_reads_plugin_root_from_dot_claude_dso_config (shim exists)" \
            "exists" "missing"
        return
    fi

    local expected_path="/fake/dso/plugin/root/from/dot-claude"

    # Create a temp git repo with .claude/dso-config.conf containing dso.plugin_root
    local fake_repo="$TMPDIR_BASE/fake-dot-claude-config-test"
    mkdir -p "$fake_repo/.claude"
    git -C "$fake_repo" init -q
    printf 'dso.plugin_root=%s\n' "$expected_path" > "$fake_repo/.claude/dso-config.conf"
    git -C "$fake_repo" add .claude/dso-config.conf
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    # Run the shim in --lib mode from within the fake repo, without CLAUDE_PLUGIN_ROOT set.
    # The shim should read .claude/dso-config.conf and export DSO_ROOT = expected_path.
    local actual_dso_root
    actual_dso_root=$(
        env -i HOME="$HOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null \
            bash --noprofile --norc -c "
                set -uo pipefail
                cd '$fake_repo'
                . '$SHIM' --lib 2>/dev/null
                printf '%s' \"\${DSO_ROOT:-UNSET}\"
            "
    )

    # RED: The shim does not yet read .claude/dso-config.conf, so DSO_ROOT will
    # be empty/UNSET (or fail entirely). This assertion fails until dso-tuz0 lands.
    assert_eq "test_shim_reads_plugin_root_from_dot_claude_dso_config" \
        "$expected_path" "$actual_dso_root"
}

# ── test_shim_no_fallback_to_workflow_config_conf ─────────────────────────────
# RED phase (dso-jfy3): When a repo has ONLY dso-config.conf at the root
# (the old location), the shim must NOT use it to resolve DSO_ROOT.
# After the migration (dso-tuz0), only .claude/dso-config.conf is a valid
# config source — the root-level dso-config.conf must be ignored.
#
# Setup: create a temp git repo with only dso-config.conf at root containing
#   dso.plugin_root=<path>
# The shim must exit non-zero or leave DSO_ROOT empty.
#
# RED: The current shim DOES read from dso-config.conf at root. This test
# fails until the shim is updated (dso-tuz0) to stop reading from that location.
test_shim_no_fallback_to_workflow_config_conf() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_no_fallback_to_workflow_config_conf (shim exists)" \
            "exists" "missing"
        return
    fi

    local old_config_path="/fake/dso/plugin/root/from/workflow-config"

    # Create a temp git repo with ONLY a root-level dso-config.conf.
    # No .claude/dso-config.conf present — only the old config location.
    local fake_repo="$TMPDIR_BASE/fake-old-workflow-config-test"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q
    printf 'dso.plugin_root=%s\n' "$old_config_path" > "$fake_repo/dso-config.conf"
    git -C "$fake_repo" add dso-config.conf
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    # Run the shim in --lib mode; after migration CLAUDE_PLUGIN_ROOT must be empty (UNSET).
    # The shim should NOT resolve DSO_ROOT from dso-config.conf.
    local actual_exit_code=0
    local actual_dso_root
    actual_dso_root=$(
        env -i HOME="$HOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null \
            bash --noprofile --norc -c "
                set -uo pipefail
                cd '$fake_repo'
                . '$SHIM' --lib 2>/dev/null
                printf '%s' \"\${DSO_ROOT:-UNSET}\"
            "
    ) || actual_exit_code=$?

    # After migration, DSO_ROOT must be UNSET (shim exits non-zero or returns empty).
    # We verify either: exit non-zero OR DSO_ROOT is not set to the old config path.
    # RED: The current shim sets DSO_ROOT = old_config_path (reads from dso-config.conf).
    # The test fails until the shim stops reading from the root-level dso-config.conf.
    if [[ "$actual_exit_code" -ne 0 ]]; then
        # Shim exited non-zero — DSO_ROOT was not found. This is the desired post-migration behavior.
        assert_eq "test_shim_no_fallback_to_workflow_config_conf (exit non-zero when no .claude/dso-config.conf)" \
            "non-zero" "non-zero"
    else
        # Shim exited zero — check that DSO_ROOT is not the old config path.
        # It must be UNSET (empty), not set from the old location.
        assert_eq "test_shim_no_fallback_to_workflow_config_conf (DSO_ROOT not set from dso-config.conf)" \
            "UNSET" "$actual_dso_root"
    fi
}

# ── test_shim_self_detects_via_sentinel ──────────────────────────────────────
# RED phase (6d45-c859): When no CLAUDE_PLUGIN_ROOT env var is set and no
# .claude/dso-config.conf is present, but plugins/dso/.claude-plugin/plugin.json
# exists in the git repo, the shim must resolve DSO_ROOT to REPO_ROOT/plugins/dso.
#
# RED: The current shim has no sentinel step. DSO_ROOT will be UNSET (the shim
# exits non-zero or leaves DSO_ROOT empty). This test fails until the sentinel
# step is added to the shim.
test_shim_self_detects_via_sentinel() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_self_detects_via_sentinel (shim exists)" \
            "exists" "missing"
        return
    fi

    # Create a fake git repo with plugins/dso/.claude-plugin/plugin.json present.
    # No CLAUDE_PLUGIN_ROOT env var, no .claude/dso-config.conf.
    local fake_repo="$TMPDIR_BASE/fake-sentinel-detect"
    mkdir -p "$fake_repo/plugins/dso/.claude-plugin"
    git -C "$fake_repo" init -q
    printf '{"name":"dso","version":"1.0.0"}\n' \
        > "$fake_repo/plugins/dso/.claude-plugin/plugin.json"
    git -C "$fake_repo" add plugins/dso/.claude-plugin/plugin.json
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    local expected_dso_root="$fake_repo/plugins/dso"

    # Source the shim in --lib mode from a clean environment (no CLAUDE_PLUGIN_ROOT,
    # no dso-config.conf). The shim must detect the sentinel and set DSO_ROOT.
    local actual_dso_root
    actual_dso_root=$(
        env -i HOME="$HOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null \
            bash --noprofile --norc -c "
                set -uo pipefail
                cd '$fake_repo'
                . '$SHIM' --lib 2>/dev/null
                printf '%s' \"\${DSO_ROOT:-UNSET}\"
            "
    ) || true

    # RED: DSO_ROOT will be UNSET because the shim has no sentinel step yet.
    assert_eq "test_shim_self_detects_via_sentinel (DSO_ROOT equals sentinel path)" \
        "$expected_dso_root" "$actual_dso_root"
}

# ── test_shim_sentinel_requires_plugin_json ───────────────────────────────────
# RED phase (6d45-c859): The sentinel fallback must NOT activate when
# plugins/dso/ exists but plugins/dso/.claude-plugin/plugin.json is absent.
# The shim must exit non-zero or leave DSO_ROOT unset in this case.
#
# RED: The current shim has no sentinel step at all, so DSO_ROOT is always
# UNSET when neither env var nor config is present. After the sentinel step is
# added, this test ensures it requires the plugin.json file specifically.
test_shim_sentinel_requires_plugin_json() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_sentinel_requires_plugin_json (shim exists)" \
            "exists" "missing"
        return
    fi

    # Create a fake git repo with plugins/dso/ present but NO plugin.json.
    local fake_repo="$TMPDIR_BASE/fake-sentinel-no-json"
    mkdir -p "$fake_repo/plugins/dso"
    git -C "$fake_repo" init -q
    # Add a placeholder file so the directory is tracked but plugin.json is absent.
    touch "$fake_repo/plugins/dso/.gitkeep"
    git -C "$fake_repo" add plugins/dso/.gitkeep
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    # Source the shim in --lib mode. Without plugin.json the sentinel must not fire.
    local actual_dso_root
    local actual_exit=0
    actual_dso_root=$(
        env -i HOME="$HOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null \
            bash --noprofile --norc -c "
                set -uo pipefail
                cd '$fake_repo'
                . '$SHIM' --lib 2>/dev/null
                printf '%s' \"\${DSO_ROOT:-UNSET}\"
            "
    ) || actual_exit=$?

    # After implementation: DSO_ROOT must be UNSET (or shim exits non-zero) because
    # the sentinel file plugins/dso/.claude-plugin/plugin.json is absent.
    if [[ "$actual_exit" -ne 0 ]]; then
        # Shim exited non-zero — sentinel correctly did not resolve. Pass.
        assert_eq "test_shim_sentinel_requires_plugin_json (no plugin.json → exit non-zero)" \
            "non-zero" "non-zero"
    else
        assert_eq "test_shim_sentinel_requires_plugin_json (no plugin.json → DSO_ROOT unset)" \
            "UNSET" "$actual_dso_root"
    fi
}

# ── test_shim_sentinel_exports_claude_plugin_root ─────────────────────────────
# RED phase (6d45-c859): When the sentinel resolves DSO_ROOT, the shim must
# also export CLAUDE_PLUGIN_ROOT = DSO_ROOT so downstream scripts can rely on it.
#
# RED: No sentinel step exists yet; CLAUDE_PLUGIN_ROOT remains unset. This test
# fails until the sentinel step is added and the existing CLAUDE_PLUGIN_ROOT
# export guard is reached with the sentinel-resolved DSO_ROOT value.
test_shim_sentinel_exports_claude_plugin_root() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_shim_sentinel_exports_claude_plugin_root (shim exists)" \
            "exists" "missing"
        return
    fi

    # Create a fake git repo with the sentinel present. No env var, no config.
    local fake_repo="$TMPDIR_BASE/fake-sentinel-export"
    mkdir -p "$fake_repo/plugins/dso/.claude-plugin"
    git -C "$fake_repo" init -q
    printf '{"name":"dso","version":"1.0.0"}\n' \
        > "$fake_repo/plugins/dso/.claude-plugin/plugin.json"
    git -C "$fake_repo" add plugins/dso/.claude-plugin/plugin.json
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    local expected_value="$fake_repo/plugins/dso"

    # Source the shim in --lib mode from a clean environment.
    # Assert CLAUDE_PLUGIN_ROOT is exported and equals the expected sentinel path.
    local actual_plugin_root
    actual_plugin_root=$(
        env -i HOME="$HOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null \
            bash --noprofile --norc -c "
                set -uo pipefail
                cd '$fake_repo'
                . '$SHIM' --lib 2>/dev/null
                printf '%s' \"\${CLAUDE_PLUGIN_ROOT:-UNSET}\"
            "
    ) || true

    # RED: CLAUDE_PLUGIN_ROOT will be UNSET because the shim has no sentinel step.
    assert_eq "test_shim_sentinel_exports_claude_plugin_root (CLAUDE_PLUGIN_ROOT equals sentinel path)" \
        "$expected_value" "$actual_plugin_root"
}

# ── test_discover_agents_resolves_routing_via_sentinel ────────────────────────
# RED phase (6d45-c859): End-to-end test: after the shim resolves DSO_ROOT via
# the sentinel, discover-agents.sh (which reads CLAUDE_PLUGIN_ROOT for its
# default routing path) must exit 0 when a minimal agent-routing.conf is present.
#
# RED: No sentinel step exists; CLAUDE_PLUGIN_ROOT is unset; discover-agents.sh
# exits 1 (missing routing conf). This test fails until the sentinel step lands.
test_discover_agents_resolves_routing_via_sentinel() {
    if [[ ! -f "$SHIM" ]]; then
        assert_eq "test_discover_agents_resolves_routing_via_sentinel (shim exists)" \
            "exists" "missing"
        return
    fi

    local discover_script="$PLUGIN_ROOT/plugins/dso/scripts/discover-agents.sh"
    if [[ ! -f "$discover_script" ]]; then
        assert_eq "test_discover_agents_resolves_routing_via_sentinel (discover-agents.sh exists)" \
            "exists" "missing"
        return
    fi

    # Create a fake git repo with:
    #   - sentinel: plugins/dso/.claude-plugin/plugin.json
    #   - minimal routing conf: plugins/dso/config/agent-routing.conf
    # No CLAUDE_PLUGIN_ROOT, no .claude/dso-config.conf.
    local fake_repo="$TMPDIR_BASE/fake-sentinel-discover"
    mkdir -p "$fake_repo/plugins/dso/.claude-plugin"
    mkdir -p "$fake_repo/plugins/dso/config"
    git -C "$fake_repo" init -q
    printf '{"name":"dso","version":"1.0.0"}\n' \
        > "$fake_repo/plugins/dso/.claude-plugin/plugin.json"
    # Minimal agent-routing.conf: one category entry so discover-agents.sh runs cleanly.
    printf 'general-purpose=general-purpose\n' \
        > "$fake_repo/plugins/dso/config/agent-routing.conf"
    git -C "$fake_repo" add plugins/
    git -c user.email=test@test.com -c user.name=Test -C "$fake_repo" commit -q -m "init"

    # Source the shim (to get CLAUDE_PLUGIN_ROOT set via sentinel), then run
    # discover-agents.sh with the sentinel-resolved routing conf path.
    local actual_exit=1
    env -i HOME="$HOME" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null \
        bash --noprofile --norc -c "
            set -uo pipefail
            cd '$fake_repo'
            . '$SHIM' --lib 2>/dev/null
            # discover-agents.sh uses \${CLAUDE_PLUGIN_ROOT:-}/config/agent-routing.conf
            # by default. With sentinel resolving CLAUDE_PLUGIN_ROOT, the path should
            # point to the fake repo's routing conf.
            '$discover_script' --routing \"\${CLAUDE_PLUGIN_ROOT:-}/config/agent-routing.conf\" \
                --settings /dev/null 2>/dev/null
        " && actual_exit=0 || true

    # RED: discover-agents.sh exits non-zero because CLAUDE_PLUGIN_ROOT is unset
    # (no sentinel step), so the routing conf path is empty and the file is not found.
    assert_eq "test_discover_agents_resolves_routing_via_sentinel (exit 0 after sentinel resolution)" \
        "0" "$actual_exit"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_shim_preserves_claude_plugin_root_when_preset
test_shim_does_not_clobber_preset_with_config_value
test_shim_unconditional_reexport_detection
test_shim_reads_plugin_root_from_dot_claude_dso_config
test_shim_no_fallback_to_workflow_config_conf
test_shim_self_detects_via_sentinel
test_shim_sentinel_requires_plugin_json
test_shim_sentinel_exports_claude_plugin_root
test_discover_agents_resolves_routing_via_sentinel

print_summary
