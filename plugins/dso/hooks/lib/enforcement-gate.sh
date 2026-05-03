#!/usr/bin/env bash
# hooks/lib/enforcement-gate.sh
# Shared enforcement gate library for DSO plugin hooks.
#
# Provides:
#   _dso_enforcement_gate_check()  — read enforcement.strategy; emit HOOK_GATE log if ci;
#                                    return 0 to short-circuit the calling hook, non-zero to proceed.
#
# Usage in a gating hook:
#   source "${_PLUGIN_ROOT}/hooks/lib/enforcement-gate.sh"
#   _dso_enforcement_gate_check && exit 0
#
# Contract: see enforcement-gate-contract.md in the same directory.
#
# Exit codes from _dso_enforcement_gate_check:
#   0  — strategy is ci; caller should skip hook body (exit 0)
#   1  — strategy is local or both (or absent, defaults to local); caller should run hook body

# Guard: only load once
[[ "${_DSO_ENFORCEMENT_GATE_LOADED:-}" == "1" ]] && return 0
_DSO_ENFORCEMENT_GATE_LOADED=1

# Capture WORKFLOW_CONFIG_FILE at source time (before any subshell/command loses it).
# VAR=val source file makes VAR visible during source but not afterwards; capturing
# here preserves it for _dso_enforcement_gate_check invocations in the same shell.
if [[ -n "${WORKFLOW_CONFIG_FILE:-}" ]]; then
    _DSO_ENFORCEMENT_GATE_CONFIG_FILE="${WORKFLOW_CONFIG_FILE}"
fi

# _dso_enforcement_gate_check
# Read enforcement.strategy from dso-config.conf.
# When strategy is "ci": emit HOOK_GATE log to stderr and return 0 (hook should skip).
# Otherwise: return 1 (hook should proceed).
#
# Config resolution order (mirrors read-config.sh):
#   1. WORKFLOW_CONFIG_FILE env var (test isolation)
#   2. git rev-parse --show-toplevel/.claude/dso-config.conf
_dso_enforcement_gate_check() {
    local _config_file _strategy

    # Resolve config file — check captured source-time var or live WORKFLOW_CONFIG_FILE
    if [[ -n "${_DSO_ENFORCEMENT_GATE_CONFIG_FILE:-}" && -f "${_DSO_ENFORCEMENT_GATE_CONFIG_FILE}" ]]; then
        _config_file="${_DSO_ENFORCEMENT_GATE_CONFIG_FILE}"
    elif [[ -n "${WORKFLOW_CONFIG_FILE:-}" && -f "${WORKFLOW_CONFIG_FILE}" ]]; then
        _config_file="${WORKFLOW_CONFIG_FILE}"
    else
        local _git_root
        _git_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
        if [[ -n "$_git_root" && -f "$_git_root/.claude/dso-config.conf" ]]; then
            _config_file="$_git_root/.claude/dso-config.conf"
        fi
    fi

    # Read enforcement.strategy; default to "local" when absent or config missing.
    if [[ -n "${_config_file:-}" ]]; then
        _strategy="$(grep -m1 '^enforcement\.strategy=' "$_config_file" | cut -d= -f2-)"
    fi
    _strategy="${_strategy:-local}"

    if [[ "$_strategy" == "ci" ]]; then
        echo "HOOK_GATE: skipped reason=enforcement.strategy=ci" >&2
        return 0
    fi

    if [[ "$_strategy" == "both" ]]; then
        # Emit HOOK_GATE:run marker so observers can confirm the gating hook
        # ran exactly once under strategy=both (caller still proceeds).
        echo "HOOK_GATE: run reason=enforcement.strategy=both" >&2
    fi

    return 1
}
