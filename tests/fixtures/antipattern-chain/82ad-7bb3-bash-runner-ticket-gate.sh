#!/usr/bin/env bash
# FIXTURE: frozen root-cause excerpt for bug 82ad-7bb3
# Antipattern: bash-runner.sh does not export CLAUDE_PLUGIN_ROOT; test scripts that
# invoke the dso shim reference ${CLAUDE_PLUGIN_ROOT} under set -u without a default guard.
# Pattern 3 chain: CLAUDE_PLUGIN_ROOT unbound in test subprocess -> hook resolution fails.
# DO NOT FIX this antipattern — it is intentionally preserved for regression testing.
# The behavioral assertion (extracted query yields >=4 matches) is owned by task-7.
set -euo pipefail

# Simulate: bash-runner.sh invokes tests that expect CLAUDE_PLUGIN_ROOT to be set.
# ANTIPATTERN: ${CLAUDE_PLUGIN_ROOT} used directly, no :- or :? fallback guard.
# When bash-runner.sh (unlike run-hook-tests.sh) does not export CLAUDE_PLUGIN_ROOT,
# any test that does this fails with "unbound variable".
_PLUGIN_HOOKS_DIR="${CLAUDE_PLUGIN_ROOT}/hooks"

# Pre-commit ticket gate uses plugin hooks to resolve ticket ID patterns.
_TICKET_GATE_HOOK="${CLAUDE_PLUGIN_ROOT}/hooks/pre-commit-ticket-gate.sh"

if [[ -x "${_TICKET_GATE_HOOK}" ]]; then
    "${_TICKET_GATE_HOOK}" "$@"
fi
