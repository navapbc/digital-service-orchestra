#!/usr/bin/env bash
# hooks/lib/enforcement-gate.sh
# Shared enforcement gate library for DSO plugin hooks.
#
# Provides:
#   _dso_enforcement_gate_check()  — read dso.workflow; emit HOOK_GATE log if ci-pr;
#                                    return 0 to short-circuit the calling hook, non-zero to proceed.
#
# Usage in a gating hook:
#   source "${_PLUGIN_ROOT}/hooks/lib/enforcement-gate.sh"
#   _dso_enforcement_gate_check && exit 0
#
# Contract: see enforcement-gate-contract.md in the same directory.
#
# Exit codes from _dso_enforcement_gate_check:
#   0  — dso.workflow is ci-pr; caller should skip hook body (exit 0)
#   1  — dso.workflow is local (or absent, defaults to local); caller should run hook body

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
# Read dso.workflow from dso-config.conf via read-config.sh.
# When dso.workflow is "ci-pr": emit HOOK_GATE log to stderr and return 0 (hook should skip).
# Otherwise: return 1 (hook should proceed).
#
# Config resolution order (mirrors read-config.sh):
#   1. WORKFLOW_CONFIG_FILE env var (test isolation)
#   2. git rev-parse --show-toplevel/.claude/dso-config.conf
_dso_enforcement_gate_check() {
    local _script_dir _wf
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _rc_script="$_script_dir/../../scripts/read-config.sh"
    if [[ -n "${WORKFLOW_CONFIG_FILE:-}" ]]; then
        _wf=$(WORKFLOW_CONFIG_FILE="${WORKFLOW_CONFIG_FILE}" bash "$_rc_script" dso.workflow 2>/dev/null || echo "local")
    elif [[ -n "${_DSO_ENFORCEMENT_GATE_CONFIG_FILE:-}" ]]; then
        _wf=$(WORKFLOW_CONFIG_FILE="${_DSO_ENFORCEMENT_GATE_CONFIG_FILE}" bash "$_rc_script" dso.workflow 2>/dev/null || echo "local")
    else
        _wf=$(bash "$_rc_script" dso.workflow 2>/dev/null || echo "local")
    fi
    if [[ "$_wf" == "ci-pr" ]]; then
        echo "HOOK_GATE: skipped reason=dso.workflow=ci-pr" >&2
        return 0
    fi
    return 1
}
