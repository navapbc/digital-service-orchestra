#!/usr/bin/env bash
# precondition-gate.sh — mode-gated precondition exit handler.
#
# Shared by the backstop review-gate
# workflows (review-coverage-invariant, dangling-references, ruleset-invariants).
#
# The wrapped check scripts exit 78 (EX_CONFIG / PRECONDITION_NOT_MET) when they
# cannot run — no token, unresolvable repo, gh missing. Pre-Option-A the
# workflows mapped 78 -> 0 UNCONDITIONALLY, so after the enforce-flip a
# token-scope regression or a transient API blip would silently green-stamp an
# un-reviewed candidate (the silent-pass class Option A pivoted away from MQ to
# avoid). This helper centralizes the fail-closed-under-enforce decision so it is
# identical across all three carriers AND testable behaviorally (execute it with
# a given rc+mode and assert the exit code) rather than by inspecting YAML text.
#
# Usage: precondition-gate.sh <rc> <mode> <label>
#   rc == 78 (precondition not met):
#       mode=enforce -> ::error  + exit 78  (fail-closed; block the candidate)
#       mode=warn    -> ::warning + exit 0   (advisory pass during rollout)
#   any other rc:
#       passthrough  -> exit rc  (a real violation, rc=1, blocks; rc=0 passes)
#
# Default mode is warn so live CI behavior is unchanged until the go-live flip.
set -uo pipefail

rc="${1:?usage: precondition-gate.sh <rc> <mode> <label>}"
mode="${2:-warn}"
label="${3:-review-gate}"

if [ "$rc" -eq 78 ]; then
    if [ "$mode" = "enforce" ]; then
        echo "::error::${label} precondition not met — fail-closed (enforce mode)"
        exit 78
    fi
    echo "::warning::${label} precondition not met — not enforced this run (warn mode)"
    exit 0
fi

exit "$rc"
