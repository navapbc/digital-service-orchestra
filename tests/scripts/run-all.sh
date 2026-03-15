#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/run-all.sh
# Thin wrapper: delegates to the top-level run-all.sh orchestrator.
#
# This wrapper exists so that tests/scripts/test-run-all.sh has a stable
# target to call (from the tests/scripts/ working directory), while the
# canonical orchestrator lives one level up at tests/run-all.sh.
#
# Features implemented in the parent (and exposed here):
#   - Per-suite timeout via SUITE_TIMEOUT env var or --suite-timeout flag
#   - Process group / orphan cleanup on EXIT via kill_children trap (kills
#     child processes in the process group to prevent orphaned suite runners)
#
# Usage:
#   bash lockpick-workflow/tests/scripts/run-all.sh [--suite-timeout N] \
#       [--hooks-runner PATH] [--scripts-runner PATH] [--evals-runner PATH]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_RUN_ALL="$SCRIPT_DIR/../run-all.sh"

# Forward all arguments to the parent orchestrator
exec bash "$PARENT_RUN_ALL" "$@"
