#!/usr/bin/env bash
# write-cycle-ledger.sh
# Atomically write cycle-ledger.json to ARTIFACTS_DIR using the cross-platform
# locking primitive from ticket-lib.sh (_flock_write_json).
#
# Compatible with macOS and Linux. Does NOT require Homebrew util-linux or the
# flock(1) binary — uses the same 3-tier locking strategy as ticket-lib.sh:
#   1. util-linux flock if available
#   2. Homebrew util-linux on macOS (mkdir-based fallback)
#   3. Python fcntl.flock (pure POSIX, no external deps, macOS-without-Homebrew safe)
#
# Usage:
#   write-cycle-ledger.sh --payload <json-string> [--artifacts-dir <path>]
#
# Required:
#   --payload <json>   JSON object to merge into cycle-ledger.json
#
# Optional:
#   --artifacts-dir <path>   Override artifacts dir (default: get_artifacts_dir())
#
# Output schema (cycle-ledger.json):
#   {
#     "schema_version": "1.0.0",
#     "epic_id": "<epic_id or empty>",
#     "cycles": [ <payload>, ... ]
#   }
#
# Exit codes:
#   0  — success
#   1  — error: missing args, invalid JSON, lock timeout, write failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ticket-lib.sh"          # provides _flock_write_json
source "$SCRIPT_DIR/../hooks/lib/deps.sh"   # provides get_artifacts_dir

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

payload=""
artifacts_dir_arg=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --payload)
            payload="$2"
            shift 2
            ;;
        --artifacts-dir)
            artifacts_dir_arg="$2"
            shift 2
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$payload" ]]; then
    echo "error: --payload is required" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate payload is valid JSON (fail fast before acquiring lock)
# ---------------------------------------------------------------------------

if ! python3 -c "import json,sys; json.loads(sys.argv[1])" "$payload" 2>/dev/null; then
    echo "error: --payload is not valid JSON" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve artifacts dir
# ---------------------------------------------------------------------------

ARTIFACTS_DIR="${artifacts_dir_arg:-$(get_artifacts_dir)}"

if ! mkdir -p "$ARTIFACTS_DIR" 2>/dev/null; then
    echo "error: cannot create artifacts directory: $ARTIFACTS_DIR" >&2
    exit 1
fi

if [[ ! -w "$ARTIFACTS_DIR" ]]; then
    echo "error: artifacts directory is not writable: $ARTIFACTS_DIR" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build / update cycle-ledger.json schema structure
# ---------------------------------------------------------------------------

LEDGER_PATH="$ARTIFACTS_DIR/cycle-ledger.json"
LOCK_FILE="$ARTIFACTS_DIR/cycle-ledger.lock"

# Stage to a temp file on the same filesystem (atomic rename requires same device)
STAGING_TEMP=$(mktemp "$ARTIFACTS_DIR/cycle-ledger-XXXXXX.tmp")
trap 'rm -f "${STAGING_TEMP:-}"' EXIT

# Build the output JSON: wrap payload into the schema envelope.
# If cycle-ledger.json already exists and is valid JSON, append to its cycles array.
python3 - "$LEDGER_PATH" "$payload" "$STAGING_TEMP" <<'PYEOF'
import json, sys, os

ledger_path = sys.argv[1]
raw_payload = sys.argv[2]
staging_temp = sys.argv[3]

new_entry = json.loads(raw_payload)

# Load existing ledger or seed a fresh one
if os.path.isfile(ledger_path):
    try:
        with open(ledger_path) as f:
            ledger = json.load(f)
        # Ensure required keys are present (defensive)
        if "schema_version" not in ledger:
            ledger["schema_version"] = "1.0.0"
        if "epic_id" not in ledger:
            ledger["epic_id"] = new_entry.get("epic_id", "")
        if not isinstance(ledger.get("cycles"), list):
            ledger["cycles"] = []
    except (json.JSONDecodeError, OSError):
        # Corrupted file — start fresh
        ledger = {"schema_version": "1.0.0", "epic_id": new_entry.get("epic_id", ""), "cycles": []}
else:
    ledger = {"schema_version": "1.0.0", "epic_id": new_entry.get("epic_id", ""), "cycles": []}

ledger["cycles"].append(new_entry)

with open(staging_temp, "w") as f:
    json.dump(ledger, f, ensure_ascii=False)

PYEOF

# ---------------------------------------------------------------------------
# Acquire lock + atomic rename via _flock_write_json
# ---------------------------------------------------------------------------

_flock_write_json "$LOCK_FILE" "$STAGING_TEMP" "$LEDGER_PATH" || exit $?

trap - EXIT
echo "cycle-ledger.json written: $LEDGER_PATH"
exit 0
