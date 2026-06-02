#!/usr/bin/env bash
# FIXTURE: frozen root-cause excerpt for bug 97a7-4504
# Antipattern: CLAUDE_PLUGIN_ROOT fallback lines in bash-runner.sh split variable
# assignment from ../.. expression (SC2155 workaround), severing the test's
# CLAUDE_PLUGIN_ROOT literal exclusion match. The test itself also references
# ${CLAUDE_PLUGIN_ROOT} without a default guard under set -u.
# Pattern 3 chain: split assignment + unguarded ref -> test exclusion logic broken.
# DO NOT FIX this antipattern — it is intentionally preserved for regression testing.
# The behavioral assertion (extracted query yields >=4 matches) is owned by task-7.
set -euo pipefail

# ANTIPATTERN: ${CLAUDE_PLUGIN_ROOT} used in a grep exclusion pattern without
# a :- or :? guard. When bash-runner.sh exposes CLAUDE_PLUGIN_ROOT as a split
# assignment (SC2155 workaround), the variable's value changes shape and the
# exclusion no longer matches the literal "CLAUDE_PLUGIN_ROOT" string in scripts.
_EXCLUSION_PATTERN="${CLAUDE_PLUGIN_ROOT}"

# Scan plugin scripts for relative path usage (../), excluding the canonical
# CLAUDE_PLUGIN_ROOT assignment lines themselves.
grep -r '\.\.\/' plugins/dso/scripts/ \
    | grep -v "${_EXCLUSION_PATTERN}" \
    | grep -v 'BASH_SOURCE'
