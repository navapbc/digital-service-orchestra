#!/usr/bin/env bash
# plugins/dso/scripts/cutover-tickets-migration.sh
# Phase-gate skeleton for the tickets migration cutover.
#
# Phases (in order): validate, snapshot, migrate, verify, finalize
#   Constant names:  PRE_FLIGHT, SNAPSHOT, MIGRATE, VERIFY, FINALIZE
#
# Usage: cutover-tickets-migration.sh [--dry-run] [--repo-root=PATH] [--help]
#
# Environment variables:
#   CUTOVER_LOG_DIR          Directory for timestamped log file (default: /tmp)
#   CUTOVER_STATE_FILE       Path for the run state file (default: /tmp/cutover-tickets-migration-state.json)
#   CUTOVER_PHASE_EXIT_OVERRIDE  "PHASE_NAME=EXIT_CODE" — inject a failure for testing
#
# Exit codes: 0=success, 1=error

set -euo pipefail

# ---------------------------------------------------------------------------
# Phase constants (ordered)
# ---------------------------------------------------------------------------
readonly PHASES=( validate snapshot migrate verify finalize )
# Canonical constant aliases (for --help display)
# PRE_FLIGHT=validate  SNAPSHOT=snapshot  MIGRATE=migrate  VERIFY=verify  FINALIZE=finalize

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
_DRY_RUN="false"
_REPO_ROOT=""

for _arg in "$@"; do
    case "$_arg" in
        --help)
            cat <<'USAGE'
Usage: cutover-tickets-migration.sh [--dry-run] [--repo-root=PATH] [--help]

  --dry-run           Execute phase stubs but skip state-file writes and
                      any git-modifying actions. Prefixes output with [DRY RUN].
  --repo-root=PATH    Override the git repo root (default: git rev-parse --show-toplevel).
  --help              Print this usage message and exit.

Phases (run in order):
  1. validate    (alias: PRE_FLIGHT)  — pre-flight checks
  2. snapshot    (alias: SNAPSHOT)    — snapshot current ticket state
  3. migrate     (alias: MIGRATE)     — migrate ticket format
  4. verify      (alias: VERIFY)      — verify migration results
  5. finalize    (alias: FINALIZE / REFERENCE_UPDATE / CLEANUP) — update references and clean up

Environment variables:
  CUTOVER_LOG_DIR          Log directory (default: /tmp)
  CUTOVER_STATE_FILE       State file path (default: /tmp/cutover-tickets-migration-state.json)
  CUTOVER_PHASE_EXIT_OVERRIDE  Inject a phase failure, e.g. "MIGRATE=1" (for testing only)

USAGE
            exit 0
            ;;
        --dry-run)
            _DRY_RUN="true"
            ;;
        --repo-root=*)
            _REPO_ROOT="${_arg#--repo-root=}"
            ;;
        *)
            echo "ERROR: Unknown argument: $_arg" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT
# ---------------------------------------------------------------------------
if [[ -z "$_REPO_ROOT" ]]; then
    if ! _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
        echo "ERROR: Not a git repository and --repo-root not supplied." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Log file setup
# ---------------------------------------------------------------------------
: "${CUTOVER_LOG_DIR:=/tmp}"
_LOG_TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)
_LOG_FILE="${CUTOVER_LOG_DIR}/cutover-${_LOG_TIMESTAMP}.log"

# Re-exec the script under tee to capture all output to the log file while
# also printing to stdout.  PIPESTATUS[0] preserves the real exit code.
# Guard with _CUTOVER_LOGGING to prevent infinite re-exec.
if [[ -z "${_CUTOVER_LOGGING:-}" ]]; then
    export _CUTOVER_LOGGING=1
    mkdir -p "$CUTOVER_LOG_DIR"
    bash "$0" "$@" 2>&1 | tee -a "$_LOG_FILE"
    exit "${PIPESTATUS[0]}"
fi

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------
: "${CUTOVER_STATE_FILE:=/tmp/cutover-tickets-migration-state.json}"

_state_append_phase() {
    local phase="$1"
    if [[ "$_DRY_RUN" == "true" ]]; then
        return 0
    fi
    # Append completed phase to state file
    if [[ ! -f "$CUTOVER_STATE_FILE" ]]; then
        printf '{"completed_phases":["%s"]}\n' "$phase" > "$CUTOVER_STATE_FILE"
    else
        # Use python3 for reliable JSON update (stdlib, no new deps)
        python3 - "$CUTOVER_STATE_FILE" "$phase" <<'PYEOF'
import sys, json
path, phase = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
data.setdefault("completed_phases", []).append(phase)
with open(path, "w") as fh:
    json.dump(data, fh)
    fh.write("\n")
PYEOF
    fi
}

# ---------------------------------------------------------------------------
# Test injection hook: CUTOVER_PHASE_EXIT_OVERRIDE
# Format: "PHASE_NAME=EXIT_CODE", e.g., "MIGRATE=1" or "PRE_FLIGHT=1"
# ---------------------------------------------------------------------------
_check_override() {
    local phase_lower="$1"
    local phase_upper
    phase_upper=$(echo "$phase_lower" | tr '[:lower:]' '[:upper:]')
    if [[ -n "${CUTOVER_PHASE_EXIT_OVERRIDE:-}" ]]; then
        local override_phase override_code resolved_upper
        override_phase="${CUTOVER_PHASE_EXIT_OVERRIDE%%=*}"
        override_code="${CUTOVER_PHASE_EXIT_OVERRIDE##*=}"
        # Resolve constant aliases to their canonical uppercase phase name
        case "$override_phase" in
            PRE_FLIGHT)      resolved_upper="VALIDATE"  ;;
            SNAPSHOT)        resolved_upper="SNAPSHOT"  ;;
            MIGRATE)         resolved_upper="MIGRATE"   ;;
            VERIFY)          resolved_upper="VERIFY"    ;;
            FINALIZE|REFERENCE_UPDATE|CLEANUP) resolved_upper="FINALIZE" ;;
            *)               resolved_upper="$override_phase" ;;
        esac
        if [[ "$resolved_upper" == "$phase_upper" ]]; then
            return "$override_code"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Phase handler stubs
# (Actual migration logic added by sibling stories w21-7mlx, w21-wbqz, w21-25mq)
# ---------------------------------------------------------------------------

_phase_validate() {
    echo "Running phase: validate"
    _check_override "validate"
}

_phase_snapshot() {
    echo "Running phase: snapshot"
    _check_override "snapshot"
}

_phase_migrate() {
    echo "Running phase: migrate"
    _check_override "migrate"
}

_phase_verify() {
    echo "Running phase: verify"
    _check_override "verify"
}

_phase_finalize() {
    echo "Running phase: finalize"
    _check_override "finalize"
}

# ---------------------------------------------------------------------------
# Dry-run wrapper: prefix every line of a phase's output with [DRY RUN]
# ---------------------------------------------------------------------------
_run_phase_dry() {
    local phase="$1"
    local phase_fn="_phase_${phase}"
    # Run in subshell, capture output, prefix each line
    local _out
    _out=$("$phase_fn" 2>&1) || return $?
    while IFS= read -r _line; do
        echo "[DRY RUN] $_line"
    done <<< "$_out"
}

# ---------------------------------------------------------------------------
# Phase gate loop
# ---------------------------------------------------------------------------
echo "cutover-tickets-migration: starting (dry_run=${_DRY_RUN})"

for _phase in "${PHASES[@]}"; do
    if [[ "$_DRY_RUN" == "true" ]]; then
        "_run_phase_dry" "$_phase" || { _rc=$?; echo "[DRY RUN] ERROR: phase ${_phase} failed (exit ${_rc}) — see ${_LOG_FILE}" >&2; exit "$_rc"; }
    else
        "_phase_${_phase}" || { _rc=$?; echo "ERROR: phase ${_phase} failed — see ${_LOG_FILE}" >&2; exit "$_rc"; }
        _state_append_phase "$_phase"
    fi
done

echo "cutover-tickets-migration: all phases complete"
