#!/usr/bin/env bash
# FIXTURE: frozen root-cause excerpt for bug fe45-0b58
# Antipattern: CLAUDE_PLUGIN_ROOT referenced at TWO sites under set -u WITHOUT a default guard.
# Pattern 3 chain: both references unbound -> exit 1 before allowlist loading.
# DO NOT FIX this antipattern — it is intentionally preserved for regression testing.
# The behavioral assertion (extracted query yields >=4 matches) is owned by task-7.
set -euo pipefail

# ANTIPATTERN site 1: ${CLAUDE_PLUGIN_ROOT} referenced with no :- or :? guard.
# When CLAUDE_PLUGIN_ROOT is unset, bash exits with "unbound variable" here.
_CONFIG_PATHS="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"

# shellcheck source=/dev/null
source "${_CONFIG_PATHS}"

# ... (intervening logic) ...

# ANTIPATTERN site 2: second bare ${CLAUDE_PLUGIN_ROOT} reference, also unguarded.
# This was line 40 in the original skip-review-check.sh.
_ALLOWLIST_FILE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/review-gate-allowlist.conf"

if [[ -f "${_ALLOWLIST_FILE}" ]]; then
    grep -qxF "${1:-}" "${_ALLOWLIST_FILE}"
fi
