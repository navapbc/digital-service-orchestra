#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# build-review-agents.sh — wrapper around build-composed-agents.sh for the "reviewer" namespace.
#
# Builds TWO variants per agent (bug 4a30-2937-b404-4a8e):
#   - orchestrator variant → ${_PLUGIN_ROOT}/agents/code-reviewer-<tier>.md
#       (used by Claude Code Agent-tool dispatch; instructs Bash/Read/Grep/write-reviewer-findings.sh)
#   - CI variant            → ${_PLUGIN_ROOT}/agents/ci/code-reviewer-<tier>.md
#       (used by dso_ci_review/dispatch.py; instructs direct JSON response + context-request protocol)
#
# Variant selection driven by DISPATCH_VARIANT env var (consumed by reviewer-meta.sh).
# Backward-compatible: existing CLI flags (--base, --deltas, --output, --expect-count) still
# work; when --output is passed explicitly, only one invocation runs (legacy single-output mode).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect whether caller passed --output explicitly (legacy single-output mode) — if so,
# honor it and skip the dual-output pipeline. Tests and callers that want the dual outputs
# should NOT pass --output.
_legacy_output=""
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--output" ]]; then
        _legacy_output="passed"
        break
    fi
done

if [[ -n "$_legacy_output" ]]; then
    # Legacy single-output mode: pass through verbatim.
    exec bash "$SCRIPT_DIR/build-composed-agents.sh" \
        --namespace reviewer \
        --generator-name "build-review-agents.sh" \
        "$@"
fi

# Dual-output mode: invoke build-composed-agents.sh twice, once per variant.
# Resolution order matches build-composed-agents.sh:_DEFAULT_AGENTS_DIR
# (DSO_PLUGIN_DIR > CLAUDE_PLUGIN_ROOT > _PLUGIN_ROOT). Keeping this in lockstep
# with the composer ensures tests, dispatchers, and the build all read/write
# to the same agents/ tree even when one is overridden.
_PLUGIN_DIR="${DSO_PLUGIN_DIR:-${CLAUDE_PLUGIN_ROOT:-$_PLUGIN_ROOT}}"

# set -e is already in effect (line 8) — if the orchestrator build fails the
# script exits before reaching the CI build, so the agents/ tree is never
# left in a half-orchestrator / half-CI state on error.
DISPATCH_VARIANT=orchestrator bash "$SCRIPT_DIR/build-composed-agents.sh" \
    --namespace reviewer \
    --generator-name "build-review-agents.sh" \
    --output "$_PLUGIN_DIR/agents" \
    "$@"

DISPATCH_VARIANT=ci bash "$SCRIPT_DIR/build-composed-agents.sh" \
    --namespace reviewer \
    --generator-name "build-review-agents.sh" \
    --output "$_PLUGIN_DIR/agents/ci" \
    "$@"
