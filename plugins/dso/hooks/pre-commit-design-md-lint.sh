#!/usr/bin/env bash
# hook-boundary: enforcement
# DSO-GATE-TIER: B
# Tier B (developer-experience): this design-system lint blocks on actual
# DESIGN.md violations but FAILS OPEN on infrastructure failure (timeout — see
# LOGIC step 1 below), so per the gate-tier doctrine (keyed on infra-failure
# behavior) it is Tier B, not A. The enforcement-boundary-annotation vs.
# fail-open-on-timeout tension is left for the owner — bug 7757-1428-7fb0-4f5d.
# hooks/pre-commit-design-md-lint.sh
# git pre-commit hook: thin wrapper that delegates to design-md-lint.sh.
#
# DESIGN:
#   This hook runs at git pre-commit time. It resolves the plugin root and
#   delegates entirely to scripts/design-md-lint.sh, propagating
#   the exit code so that non-zero exits block the commit.
#
# LOGIC:
#   1. Fail-open on timeout (SIGTERM/SIGURG).
#   2. Resolve PLUGIN_ROOT (via CLAUDE_PLUGIN_ROOT env var or relative to this file).
#   3. Locate design-md-lint.sh at $PLUGIN_ROOT/scripts/design-md-lint.sh.
#   4. If the script is missing, warn and exit 0 (fail-open; script created by
#      a dependency task; missing during partial deploy is non-fatal).
#   5. Delegate to design-md-lint.sh and propagate its exit code.
#
# INSTALL:
#   Registered in .pre-commit-config.yaml as a local hook (pre-commit stage)
#   using the pre-commit-wrapper.sh delegation pattern.
#
# ENVIRONMENT:
#   CLAUDE_PLUGIN_ROOT — optional; used to locate design-md-lint.sh

set -uo pipefail

# ── Fail-open on timeout ─────────────────────────────────────────────────────
# pre-commit sends SIGTERM after the configured timeout.
# Claude Code's tool timeout sends SIGURG (exit 144).
# A gate timeout is an infrastructure failure, not a lint failure — fail open.
# shellcheck disable=SC2329  # function invoked indirectly via trap
_fail_open_on_timeout() {
    echo "pre-commit-design-md-lint: WARNING: timed out — failing open (commit allowed)" >&2
    exit 0
}
trap _fail_open_on_timeout TERM URG

# ── Locate hook and plugin directories ──────────────────────────────────────
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$HOOK_DIR/.." && pwd)}"

# ── Enforcement strategy gate ────────────────────────────────────────────────
# Short-circuit when ci-pr mode (enforcement deferred to CI).
# shellcheck disable=SC1091
source "$HOOK_DIR/lib/enforcement-gate.sh"
_dso_enforcement_gate_check && exit 0

# ── Locate and delegate to design-md-lint.sh ────────────────────────────────
_LINT_SCRIPT="$PLUGIN_ROOT/scripts/design-md-lint.sh"

if [[ ! -f "$_LINT_SCRIPT" ]]; then
    echo "pre-commit-design-md-lint: WARNING: design-md-lint.sh not found at $_LINT_SCRIPT — failing open (commit allowed)" >&2
    exit 0
fi

exec bash "$_LINT_SCRIPT"
