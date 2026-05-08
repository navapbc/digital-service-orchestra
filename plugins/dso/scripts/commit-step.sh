#!/usr/bin/env bash
# commit-step.sh — run a commit workflow step and record its result as an artifact.
# Usage: commit-step.sh <step-name> <timeout-seconds> <command...>
set -uo pipefail

# ── Validate arguments ──
if [[ $# -lt 1 ]]; then
    echo "ERROR: step name is required" >&2
    echo "Usage: $(basename "$0") <step-name> <timeout-seconds> <command...>" >&2
    exit 1
fi

_step_name="$1"
shift  # skip step-name
shift  # skip timeout-seconds (recorded for future use, not enforced here)

# ── Resolve plugin root and source deps.sh ──
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DEPS_PATH="$_SCRIPT_DIR/../hooks/lib/deps.sh"
if [[ -f "$_DEPS_PATH" ]]; then
    # shellcheck source=../hooks/lib/deps.sh
    source "$_DEPS_PATH"
else
    echo "ERROR: deps.sh not found at $_DEPS_PATH" >&2
    exit 1
fi

# ── CWD safety guard — verify git repo root matches expected context ──
if [[ -z "${DSO_HARVEST_MODE:-}" ]]; then
    _cwd_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "ERROR: commit-step: CWD is not in a git repository" >&2
        exit 1
    }
fi

# ── Resolve artifacts dir ──
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

# ── Run the command, capturing stdout/stderr ──
_stdout_tmp=$(mktemp /tmp/commit-step-stdout.XXXXXX)
_stderr_tmp=$(mktemp /tmp/commit-step-stderr.XXXXXX)
# shellcheck disable=SC2064
trap "rm -f '$_stdout_tmp' '$_stderr_tmp'" EXIT

"${@}" >"$_stdout_tmp" 2>"$_stderr_tmp"
_exit=$?

_stdout=$(cat "$_stdout_tmp")
_stderr=$(cat "$_stderr_tmp")

# ── Build timestamp ──
_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Write artifact based on exit code ──
if [[ "$_exit" -eq 144 ]]; then
    # Timeout artifact
    python3 -c "
import json, sys
data = {
    'step': sys.argv[1],
    'timestamp': sys.argv[2],
    'reason': 'exit_144_timeout'
}
print(json.dumps(data, indent=2))
" "$_step_name" "$_ts" > "$ARTIFACTS_DIR/${_step_name}.timeout"
else
    # Result artifact
    # Write artifact before any stdout to ensure truncation immunity
    _harvest_flag="${DSO_HARVEST_MODE:-}"
    _artifact_tmp=$(mktemp "$ARTIFACTS_DIR/${_step_name}.result.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$_stdout_tmp' '$_stderr_tmp' '$_artifact_tmp'" EXIT
    python3 -c "
import json, sys
data = {
    'step': sys.argv[1],
    'exit_code': int(sys.argv[2]),
    'stdout': sys.argv[3],
    'stderr': sys.argv[4],
    'timestamp': sys.argv[5]
}
if sys.argv[6]:
    data['harvest_mode'] = True
print(json.dumps(data, indent=2))
" "$_step_name" "$_exit" "$_stdout" "$_stderr" "$_ts" "$_harvest_flag" > "$_artifact_tmp"
    mv "$_artifact_tmp" "$ARTIFACTS_DIR/${_step_name}.result"
fi

# ── Append breadcrumb to steps.log (JSON Lines) ──
python3 -c "
import json, sys
entry = {
    'step': sys.argv[1],
    'exit_code': int(sys.argv[2]),
    'timestamp': sys.argv[3]
}
print(json.dumps(entry))
" "$_step_name" "$_exit" "$_ts" >> "$ARTIFACTS_DIR/steps.log"

# ── Pass through original exit code ──
exit "$_exit"
