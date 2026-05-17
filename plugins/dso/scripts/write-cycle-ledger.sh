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
# Usage (legacy --payload interface):
#   write-cycle-ledger.sh --payload <json-string> [--artifacts-dir <path>]
#
# Usage (new interface):
#   write-cycle-ledger.sh --epic-id <id> --cycle-num <n> --findings-hash <hash>
#                         [--artifacts-dir <path>] [--reconstruct-from-pr]
#
# Required (legacy):
#   --payload <json>   JSON object to merge into cycle-ledger.json
#
# Required (new interface — all three must be provided together):
#   --epic-id <id>          The epic ID
#   --cycle-num <n>         Integer cycle number
#   --findings-hash <hash>  Hash string for this cycle's findings
#
# Optional (both interfaces):
#   --artifacts-dir <path>   Override artifacts dir (default: get_artifacts_dir())
#
# Optional (new interface only):
#   --reconstruct-from-pr    Trigger CI reconstruction mode: parse PR comments
#                            for prior DSO-Review-Cycle entries before appending
#                            the current cycle. Requires DSO_CI_REVIEW_PR env var.
#
# Output schema (cycle-ledger.json):
#   {
#     "schema_version": "1.0.0",
#     "epic_id": "<epic_id or empty>",
#     "cycles": [ <cycle_entry>, ... ],
#     "reconstruction_gaps": true   # only present when gaps detected during reconstruction
#   }
#
# Exit codes:
#   0  — success
#   1  — error: missing args, invalid JSON, lock timeout, write failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ticket-lib.sh"          # provides _flock_write_json
# Plugin-root-resolved source path (bug d150-4b26-fdec-45cf):
# check-plugin-scripts-no-relative-paths.sh forbids '$SCRIPT_DIR/..' source paths.
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${_PLUGIN_ROOT}/plugin.json" ]] && _PLUGIN_ROOT="$SCRIPT_DIR/.."
# shellcheck source=hooks/lib/deps.sh
source "${_PLUGIN_ROOT}/hooks/lib/deps.sh"   # provides get_artifacts_dir

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

payload=""
artifacts_dir_arg=""
epic_id=""
cycle_num=""
findings_hash=""
reconstruct_from_pr=0

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
        --artifacts-dir=*)
            artifacts_dir_arg="${1#--artifacts-dir=}"
            shift
            ;;
        --epic-id)
            epic_id="$2"
            shift 2
            ;;
        --epic-id=*)
            epic_id="${1#--epic-id=}"
            shift
            ;;
        --cycle-num)
            cycle_num="$2"
            shift 2
            ;;
        --cycle-num=*)
            cycle_num="${1#--cycle-num=}"
            shift
            ;;
        --findings-hash)
            findings_hash="$2"
            shift 2
            ;;
        --findings-hash=*)
            findings_hash="${1#--findings-hash=}"
            shift
            ;;
        --reconstruct-from-pr)
            reconstruct_from_pr=1
            shift
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Determine interface mode and validate arguments
# ---------------------------------------------------------------------------

use_new_interface=0

if [[ -n "$epic_id" || -n "$cycle_num" || -n "$findings_hash" ]]; then
    use_new_interface=1
fi

if [[ "$use_new_interface" -eq 1 ]]; then
    # New interface: all three required
    if [[ -z "$epic_id" || -z "$cycle_num" || -z "$findings_hash" ]]; then
        echo "error: --epic-id, --cycle-num, and --findings-hash are all required when using the new interface" >&2
        exit 1
    fi
else
    # Legacy --payload interface
    if [[ -z "$payload" ]]; then
        echo "error: --payload is required" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Validate payload is valid JSON (fail fast before acquiring lock) — legacy only
# ---------------------------------------------------------------------------

if [[ "$use_new_interface" -eq 0 ]]; then
    if ! python3 -c "import json,sys; json.loads(sys.argv[1])" "$payload" 2>/dev/null; then
        echo "error: --payload is not valid JSON" >&2
        exit 1
    fi
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

# Stage to a temp file on the same filesystem (atomic rename requires same device).
# Note: no suffix after XXXXXX — macOS mktemp only replaces trailing X-blocks; a
# suffix like ".tmp" after XXXXXX makes macOS treat the whole thing as a literal
# filename, causing mkstemp failures on concurrent calls from parallel processes.
STAGING_TEMP=$(mktemp "$ARTIFACTS_DIR/cycle-ledger-XXXXXX")
trap 'rm -f "${STAGING_TEMP:-}"' EXIT

if [[ "$use_new_interface" -eq 1 ]]; then
    # New interface: use Python fcntl.flock to hold lock across read-modify-write
    # so concurrent writes do not lose data. The lock is acquired before reading
    # the existing ledger and released after the atomic rename — ensuring each
    # process sees the latest state.
    TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    PR_NUMBER="${DSO_CI_REVIEW_PR:-}"

    python3 - \
        "$LEDGER_PATH" \
        "$LOCK_FILE" \
        "$epic_id" \
        "$cycle_num" \
        "$findings_hash" \
        "$TIMESTAMP" \
        "$reconstruct_from_pr" \
        "$PR_NUMBER" \
        "$STAGING_TEMP" <<'PYEOF'
import fcntl, json, os, re, subprocess, sys, time

ledger_path      = sys.argv[1]
lock_path        = sys.argv[2]
epic_id          = sys.argv[3]
cycle_num        = int(sys.argv[4])
findings_hash    = sys.argv[5]
timestamp_utc    = sys.argv[6]
reconstruct_flag = sys.argv[7]  # "0" or "1"
pr_number        = sys.argv[8]
staging_temp     = sys.argv[9]

do_reconstruct = (reconstruct_flag == "1")

# Acquire exclusive lock on the lock file for the full read-modify-write
lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
timeout = 30
deadline = time.monotonic() + timeout
acquired = False
while time.monotonic() < deadline:
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        acquired = True
        break
    except (OSError, IOError):
        time.sleep(0.05)

if not acquired:
    os.close(lock_fd)
    print("error: could not acquire lock within 30s", file=sys.stderr)
    sys.exit(1)

try:
    # ── CI reconstruction path ────────────────────────────────────────────────
    if do_reconstruct and not os.path.isfile(ledger_path):
        reconstruction_gaps = True  # always flag in reconstruction mode
        cycles = []

        if pr_number:
            try:
                result = subprocess.run(
                    ["gh", "pr", "view", pr_number, "--json", "comments",
                     "--jq", ".comments[].body"],
                    capture_output=True, text=True, timeout=30
                )
                lines = result.stdout.splitlines()
                pattern = re.compile(
                    r"^DSO-Review-Cycle: ([0-9]+)( findings-hash=([^ ]+))?"
                )
                parsed_entries = []
                for line in lines:
                    m = pattern.match(line)
                    if m:
                        cn = int(m.group(1))
                        fh = m.group(3) if m.group(3) else ""
                        if not fh:
                            reconstruction_gaps = True
                        parsed_entries.append({
                            "cycle_num": cn,
                            "findings_hash": fh,
                            "timestamp_utc": ""
                        })
                if not parsed_entries:
                    reconstruction_gaps = True
                else:
                    cycles = parsed_entries
            except Exception:
                reconstruction_gaps = True
        else:
            reconstruction_gaps = True

        # Append the current cycle entry
        cycles.append({
            "cycle_num": cycle_num,
            "timestamp_utc": timestamp_utc,
            "findings_hash": findings_hash
        })

        ledger = {
            "schema_version": "1.0.0",
            "epic_id": epic_id,
            "cycles": cycles,
            "reconstruction_gaps": reconstruction_gaps
        }

    else:
        # ── Normal new-interface write ─────────────────────────────────────────
        if os.path.isfile(ledger_path):
            try:
                with open(ledger_path) as f:
                    ledger = json.load(f)
                if "schema_version" not in ledger:
                    ledger["schema_version"] = "1.0.0"
                if "epic_id" not in ledger:
                    ledger["epic_id"] = epic_id
                if not isinstance(ledger.get("cycles"), list):
                    ledger["cycles"] = []
            except (json.JSONDecodeError, OSError):
                ledger = {"schema_version": "1.0.0", "epic_id": epic_id, "cycles": []}
        else:
            ledger = {"schema_version": "1.0.0", "epic_id": epic_id, "cycles": []}

        new_entry = {
            "cycle_num": cycle_num,
            "timestamp_utc": timestamp_utc,
            "findings_hash": findings_hash
        }
        ledger["cycles"].append(new_entry)

    # Write to staging temp
    with open(staging_temp, "w") as f:
        json.dump(ledger, f, ensure_ascii=False)

    # Atomic rename while still holding the lock
    os.rename(staging_temp, ledger_path)

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
PYEOF

    # Remove staging temp if still there (Python already renamed it, but trap cleanup is safe)
    rm -f "$STAGING_TEMP" 2>/dev/null || true

else
    # ---------------------------------------------------------------------------
    # Legacy --payload interface: use existing _flock_write_json pattern
    # ---------------------------------------------------------------------------
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
fi

trap - EXIT
echo "cycle-ledger.json written: $LEDGER_PATH"
exit 0
