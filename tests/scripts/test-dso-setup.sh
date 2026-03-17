#!/usr/bin/env bash
# tests/scripts/test-dso-setup.sh
# TDD red-phase tests for scripts/dso-setup.sh
#
# Verifies that dso-setup.sh installs the dso shim into a host project's
# .claude/scripts/ directory and writes dso.plugin_root to workflow-config.conf.
#
# RED PHASE: All tests are expected to FAIL until scripts/dso-setup.sh is created.
#
# Usage:
#   bash tests/scripts/test-dso-setup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SCRIPT="$PLUGIN_ROOT/scripts/dso-setup.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]}"' EXIT

echo "=== test-dso-setup.sh ==="

# ── test_setup_creates_shim ───────────────────────────────────────────────────
# Running dso-setup.sh must create .claude/scripts/dso in the target directory.
test_setup_creates_shim() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    if [[ -f "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_creates_shim" "exists" "exists"
    else
        assert_eq "test_setup_creates_shim" "exists" "missing"
    fi
}

# ── test_setup_shim_executable ────────────────────────────────────────────────
# The installed shim must be executable (chmod +x).
test_setup_shim_executable() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    if [[ -x "$T/.claude/scripts/dso" ]]; then
        assert_eq "test_setup_shim_executable" "executable" "executable"
    else
        assert_eq "test_setup_shim_executable" "executable" "not-executable"
    fi
}

# ── test_setup_writes_plugin_root ─────────────────────────────────────────────
# Running dso-setup.sh must write dso.plugin_root=<path> to workflow-config.conf
# in the target directory.
test_setup_writes_plugin_root() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q "^dso.plugin_root=" "$T/workflow-config.conf" 2>/dev/null; then
        result="exists"
    fi
    assert_eq "test_setup_writes_plugin_root" "exists" "$result"
}

# ── test_setup_is_idempotent ──────────────────────────────────────────────────
# Running dso-setup.sh twice must not duplicate the dso.plugin_root entry.
# Also: running setup on a target that already has a different dso.plugin_root
# entry must update it (not add a second line).
test_setup_is_idempotent() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    # Run twice — must not duplicate the entry
    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local count=0
    count=$(grep -c "^dso.plugin_root=" "$T/workflow-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_is_idempotent" "1" "$count"

    # Also verify: pre-existing entry with different path is replaced, not duplicated
    local T2
    T2=$(mktemp -d)
    TMPDIRS+=("$T2")
    echo "dso.plugin_root=/old/path" > "$T2/workflow-config.conf"
    bash "$SETUP_SCRIPT" "$T2" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local count2=0
    count2=$(grep -c "^dso.plugin_root=" "$T2/workflow-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_is_idempotent (pre-existing entry)" "1" "$count2"
}

# ── test_setup_dso_tk_help_works ──────────────────────────────────────────────
# After setup, invoking the installed shim with 'tk --help' (without
# CLAUDE_PLUGIN_ROOT set — forcing the shim to read from workflow-config.conf)
# must exit 0.
test_setup_dso_tk_help_works() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local exit_code=0
    (
        cd "$T"
        unset CLAUDE_PLUGIN_ROOT
        "./.claude/scripts/dso" tk --help >/dev/null 2>&1
    ) || exit_code=$?
    assert_eq "test_setup_dso_tk_help_works" "0" "$exit_code"
}

# REVIEW-DEFENSE: Error-path tests (missing arguments, invalid TARGET_DIR) are out of
# scope for this RED-phase task. The RED phase covers the happy-path contract that the
# script must satisfy. Error-path and edge-case coverage belongs in the GREEN implementation
# task (dso-jl2z), where the script's full interface is defined and tested.

# ── Run all tests ─────────────────────────────────────────────────────────────
test_setup_creates_shim
test_setup_shim_executable
test_setup_writes_plugin_root
test_setup_is_idempotent
test_setup_dso_tk_help_works

print_summary
