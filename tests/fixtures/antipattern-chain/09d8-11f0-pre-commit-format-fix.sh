#!/usr/bin/env bash
# FIXTURE: frozen root-cause excerpt for bug 09d8-11f0
# Antipattern: CLAUDE_PLUGIN_ROOT referenced under set -u WITHOUT a default guard.
# Pattern 3 chain: CLAUDE_PLUGIN_ROOT unbound -> exit 1 before logic runs.
# DO NOT FIX this antipattern — it is intentionally preserved for regression testing.
# The behavioral assertion (extracted query yields >=4 matches) is owned by task-7.
set -euo pipefail

# ANTIPATTERN: ${CLAUDE_PLUGIN_ROOT} referenced with no :- or :? guard under set -u.
# When invoked outside a Claude Code session, this triggers:
#   line N: CLAUDE_PLUGIN_ROOT: unbound variable
_CONFIG_PATHS="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"

# Load the config path resolution library (fails if CLAUDE_PLUGIN_ROOT unbound).
# shellcheck source=/dev/null
source "${_CONFIG_PATHS}"
