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
#                         [--commit-sha <sha>] [--findings <json>]
#                         [--artifacts-dir <path>] [--reconstruct-from-pr]
#
# Usage (pure-reconstruction interface — no new cycle appended):
#   write-cycle-ledger.sh --reconstruct-from-pr <PR_NUM> <REPO>
#                         [--artifacts-dir <path>]
#   Writes the ledger reconstructed from PR comments only. Delegates parsing
#   to `python3 -m dso_ci_review.cycle_ledger reconstruct-from-pr` so the
#   shell does not maintain a second marker grammar (task b1df-18c6).
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
# Optional (new interface only — v1.1.0 fields, see contract for full spec):
#   --commit-sha <sha>       40-char commit SHA at cycle close time. Default:
#                            git rev-parse HEAD (empty string when not in a
#                            git repo or git is unavailable).
#   --findings <json>        JSON array of [file, line_range, category] tuples.
#                            Default: [] (empty array). Used by Jaccard stability
#                            computation across cycles.
#   --reconstruct-from-pr    Trigger CI reconstruction mode: parse PR comments
#                            for prior DSO-Review-Cycle entries before appending
#                            the current cycle. Requires DSO_CI_REVIEW_PR env var.
#                            Parsing is delegated to the Python CLI (no shell-side
#                            regex) so local and CI reconstruction paths produce
#                            identical ledgers (Step 4.75 parity).
#
# Output schema (cycle-ledger.json) — see the cycle-ledger.md contract
# (${CLAUDE_PLUGIN_ROOT}/docs/contracts/cycle-ledger.md) for the full v1.1.0 spec:
#   {
#     "schema_version": "1.1.0",
#     "epic_id": "<epic_id or empty>",
#     "cycles": [ <cycle_entry>, ... ],
#     "reconstruction_gaps": true   # only present when gaps detected during reconstruction
#   }
# Each cycle entry carries: cycle_num, timestamp_utc, findings_hash, plus the
# v1.1.0 fields commit_sha (string) and findings (array of [file, line_range,
# category] string tuples).
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
commit_sha_arg=""
commit_sha_explicit=0
findings_arg=""
findings_explicit=0
reconstruct_from_pr=0
# Pure-reconstruction (positional) mode: set when `--reconstruct-from-pr <PR> <REPO>`
# is invoked with two trailing positional arguments. Delegates fully to the
# Python CLI; no new cycle is appended.
pure_recon_pr=""
pure_recon_repo=""

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
        --commit-sha)
            commit_sha_arg="$2"
            commit_sha_explicit=1
            shift 2
            ;;
        --commit-sha=*)
            commit_sha_arg="${1#--commit-sha=}"
            commit_sha_explicit=1
            shift
            ;;
        --findings)
            findings_arg="$2"
            findings_explicit=1
            shift 2
            ;;
        --findings=*)
            findings_arg="${1#--findings=}"
            findings_explicit=1
            shift
            ;;
        --reconstruct-from-pr)
            reconstruct_from_pr=1
            # Detect positional form: --reconstruct-from-pr <PR_NUM> <REPO>
            # Heuristic: next two args exist and don't start with `-`.
            if [[ $# -ge 3 && "${2:0:1}" != "-" && "${3:0:1}" != "-" ]]; then
                pure_recon_pr="$2"
                pure_recon_repo="$3"
                shift 3
            else
                shift
            fi
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
pure_recon_mode=0

if [[ -n "$pure_recon_pr" && -n "$pure_recon_repo" ]]; then
    pure_recon_mode=1
elif [[ -n "$epic_id" || -n "$cycle_num" || -n "$findings_hash" ]]; then
    use_new_interface=1
fi

if [[ "$pure_recon_mode" -eq 1 ]]; then
    # Pure-reconstruction mode delegates to the Python CLI; no additional
    # argument validation needed here. The Python CLI validates <pr-number>.
    :
elif [[ "$use_new_interface" -eq 1 ]]; then
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

if [[ "$use_new_interface" -eq 0 && "$pure_recon_mode" -eq 0 ]]; then
    if ! python3 -c "import json,sys; json.loads(sys.argv[1])" "$payload" 2>/dev/null; then
        echo "error: --payload is not valid JSON" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# v1.1.0 field defaults (new interface only) — applied before the locked section
# ---------------------------------------------------------------------------
# commit_sha: when --commit-sha is not explicitly passed, default to git HEAD.
#             If git is unavailable or not in a repo, fall back to empty string
#             per the contract (writers SHOULD populate; readers tolerate "").
# findings:   when --findings is not explicitly passed, default to "[]". When
#             passed, the JSON must parse (validated below) — fail fast before
#             acquiring the lock.

if [[ "$use_new_interface" -eq 1 ]]; then
    if [[ "$commit_sha_explicit" -eq 0 ]]; then
        # Try git rev-parse HEAD; fall back to empty string on any failure.
        commit_sha_arg="$(git rev-parse HEAD 2>/dev/null || echo "")"
    fi

    if [[ "$findings_explicit" -eq 0 ]]; then
        findings_arg="[]"
    fi

    # Validate findings is valid JSON before acquiring the lock.
    if ! python3 -c "import json,sys; json.loads(sys.argv[1])" "$findings_arg" 2>/dev/null; then
        echo "error: --findings is not valid JSON" >&2
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

# ---------------------------------------------------------------------------
# Pure-reconstruction mode (positional `--reconstruct-from-pr <PR> <REPO>`):
# delegate to the Python CLI so a single grammar source parses PR comments
# in both local and CI paths. No new cycle is appended.
# ---------------------------------------------------------------------------

if [[ "$pure_recon_mode" -eq 1 ]]; then
    # Resolve PYTHONPATH so `python3 -m dso_ci_review.cycle_ledger` resolves
    # without requiring the package to be installed.
    SCRIPTS_PY_DIR="$SCRIPT_DIR"
    if [[ -n "${PYTHONPATH:-}" ]]; then
        export PYTHONPATH="$SCRIPTS_PY_DIR:$PYTHONPATH"
    else
        export PYTHONPATH="$SCRIPTS_PY_DIR"
    fi

    # Write Python stdout to a temp file, then rename to LEDGER_PATH atomically.
    STAGING_TEMP=$(mktemp "$ARTIFACTS_DIR/cycle-ledger-XXXXXX")
    trap 'rm -f "${STAGING_TEMP:-}"' EXIT
    if ! python3 -m dso_ci_review.cycle_ledger \
            reconstruct-from-pr "$pure_recon_pr" "$pure_recon_repo" \
            > "$STAGING_TEMP"; then
        rm -f "$STAGING_TEMP"
        echo "error: python reconstruction failed" >&2
        exit 1
    fi
    mv -f "$STAGING_TEMP" "$LEDGER_PATH"
    trap - EXIT
    echo "cycle-ledger.json written: $LEDGER_PATH"
    exit 0
fi

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

    # Ensure the Python module is importable for the reconstruction path.
    # SCRIPT_DIR points to this script's directory where dso_ci_review/ lives.
    if [[ -n "${PYTHONPATH:-}" ]]; then
        export PYTHONPATH="$SCRIPT_DIR:$PYTHONPATH"
    else
        export PYTHONPATH="$SCRIPT_DIR"
    fi

    python3 - \
        "$LEDGER_PATH" \
        "$LOCK_FILE" \
        "$epic_id" \
        "$cycle_num" \
        "$findings_hash" \
        "$TIMESTAMP" \
        "$reconstruct_from_pr" \
        "$PR_NUMBER" \
        "$STAGING_TEMP" \
        "$commit_sha_arg" \
        "$findings_arg" <<'PYEOF'
import fcntl, json, os, sys, time

ledger_path      = sys.argv[1]
lock_path        = sys.argv[2]
epic_id          = sys.argv[3]
cycle_num        = int(sys.argv[4])
findings_hash    = sys.argv[5]
timestamp_utc    = sys.argv[6]
reconstruct_flag = sys.argv[7]  # "0" or "1"
pr_number        = sys.argv[8]
staging_temp     = sys.argv[9]
commit_sha       = sys.argv[10]
findings_raw     = sys.argv[11]

# v1.1.0 schema constants — keep in sync with cycle-ledger.md contract
SCHEMA_VERSION = "1.1.0"

# findings is validated as JSON in the bash wrapper before we reach this point,
# so json.loads() is safe here. Always normalize to a list.
findings_value = json.loads(findings_raw)
if not isinstance(findings_value, list):
    print("error: --findings must be a JSON array", file=sys.stderr)
    sys.exit(1)

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


def parse_review_cycle_line(line):
    """
    Parse a single DSO-Review-Cycle: marker line. Returns (cycle_dict, gap_bool)
    where gap_bool is True if any v1.1.0 fields were missing or unparseable.

    Recognizes both formats:
      v1.1.0: DSO-Review-Cycle: <n> commit_sha=<sha> findings_hash=<h> tuples=<json>
      v1.0.0: DSO-Review-Cycle: <n> findings-hash=<h>
              DSO-Review-Cycle: <n>                              # cycle_num only
    """
    m = re.match(r"^DSO-Review-Cycle:\s+(\d+)\b(.*)$", line)
    if not m:
        return None, True
    cn = int(m.group(1))
    rest = m.group(2) or ""

    # v1.1.0: findings_hash= (underscore form, alongside commit_sha=)
    sha_m = re.search(r"\bcommit_sha=([0-9a-fA-F]+)\b", rest)
    # accept both `findings_hash=` (v1.1.0) and `findings-hash=` (v1.0.0)
    fh_m = re.search(r"\bfindings[_-]hash=([^\s]+)", rest)
    # tuples=<json-array>; greedy to end-of-string so embedded brackets are kept.
    tuples_m = re.search(r"\btuples=(\[.*\])\s*$", rest)

    commit_sha = sha_m.group(1) if sha_m else ""
    fh = fh_m.group(1) if fh_m else ""
    findings_parsed = []
    tuples_ok = True
    if tuples_m:
        try:
            findings_parsed = json.loads(tuples_m.group(1))
            if not isinstance(findings_parsed, list):
                findings_parsed = []
                tuples_ok = False
        except (ValueError, json.JSONDecodeError):
            findings_parsed = []
            tuples_ok = False

    # Gap detection: any v1.0.0 record (no commit_sha/no tuples) or any
    # unparseable v1.1.0 field counts as a gap so the reader knows the data
    # is incomplete relative to the v1.1.0 contract.
    gap = (
        not fh
        or not sha_m
        or not tuples_m
        or not tuples_ok
    )

    return {
        "cycle_num": cn,
        "timestamp_utc": "",
        "findings_hash": fh,
        "commit_sha": commit_sha,
        "findings": findings_parsed,
    }, gap


try:
    # ── CI reconstruction path ────────────────────────────────────────────────
    #
    # Reconstruction parsing is delegated to dso_ci_review.cycle_ledger so the
    # shell does not maintain a second marker grammar. Step 4.75 parity
    # requires byte-identical reconstruction across local and CI paths.
    if do_reconstruct and not os.path.isfile(ledger_path):
        reconstruction_gaps = True  # always flag in reconstruction mode
        cycles = []

        if pr_number:
            try:
                from dso_ci_review.cycle_ledger import (
                    reconstruct_from_pr_comments,
                )
                # Repo is taken from GITHUB_REPOSITORY (CI standard) or
                # DSO_CI_REVIEW_REPO when set explicitly. Empty string is
                # passed through; gh CLI will fail and we mark gaps.
                repo = os.environ.get("DSO_CI_REVIEW_REPO") \
                    or os.environ.get("GITHUB_REPOSITORY", "")
                rec_ledger = reconstruct_from_pr_comments(
                    int(pr_number), repo
                )
                # Map the unified ledger's cycle entries to this script's
                # surface shape (cycle_num/findings_hash/timestamp_utc).
                # The unified parser handles BOTH legacy and v1.1.0 markers
                # and sets reconstruction_gaps on its own when entries are
                # malformed; we OR that into our gap flag.
                if rec_ledger.get("reconstruction_gaps"):
                    reconstruction_gaps = True
                parsed_entries = []
                for entry in rec_ledger.get("cycles", []):
                    fh = entry.get("findings_hash", "") or ""
                    if not fh:
                        reconstruction_gaps = True
                    parsed_entries.append({
                        "cycle_num": entry["cycle_num"],
                        "findings_hash": fh,
                        "timestamp_utc": "",
                    })
                if not parsed_entries:
                    reconstruction_gaps = True
                else:
                    cycles = parsed_entries
            except Exception:
                reconstruction_gaps = True
        else:
            reconstruction_gaps = True

        # Append the current cycle entry (v1.1.0 fields populated from args)
        cycles.append({
            "cycle_num": cycle_num,
            "timestamp_utc": timestamp_utc,
            "findings_hash": findings_hash,
            "commit_sha": commit_sha,
            "findings": findings_value,
        })

        ledger = {
            "schema_version": SCHEMA_VERSION,
            "epic_id": epic_id,
            "cycles": cycles,
            "reconstruction_gaps": reconstruction_gaps,
        }

    else:
        # ── Normal new-interface write ─────────────────────────────────────────
        if os.path.isfile(ledger_path):
            try:
                with open(ledger_path) as f:
                    ledger = json.load(f)
                # Upgrade older ledgers in-place to v1.1.0 (additive only)
                ledger["schema_version"] = SCHEMA_VERSION
                if "epic_id" not in ledger:
                    ledger["epic_id"] = epic_id
                if not isinstance(ledger.get("cycles"), list):
                    ledger["cycles"] = []
            except (json.JSONDecodeError, OSError):
                ledger = {"schema_version": SCHEMA_VERSION, "epic_id": epic_id, "cycles": []}
        else:
            ledger = {"schema_version": SCHEMA_VERSION, "epic_id": epic_id, "cycles": []}

        new_entry = {
            "cycle_num": cycle_num,
            "timestamp_utc": timestamp_utc,
            "findings_hash": findings_hash,
            "commit_sha": commit_sha,
            "findings": findings_value,
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
    # Legacy --payload interface: use existing _flock_write_json pattern.
    # Bumped to v1.1.0 to match the contract — the legacy interface does not
    # populate commit_sha/findings on new entries unless the caller embedded
    # them in the payload, but the seeded ledger still claims v1.1.0 so
    # downstream readers do not have to special-case the legacy writer.
    # ---------------------------------------------------------------------------
    python3 - "$LEDGER_PATH" "$payload" "$STAGING_TEMP" <<'PYEOF'
import json, sys, os

ledger_path = sys.argv[1]
raw_payload = sys.argv[2]
staging_temp = sys.argv[3]

SCHEMA_VERSION = "1.1.0"

new_entry = json.loads(raw_payload)

# Load existing ledger or seed a fresh one
if os.path.isfile(ledger_path):
    try:
        with open(ledger_path) as f:
            ledger = json.load(f)
        # Ensure required keys are present and bump schema (additive change)
        ledger["schema_version"] = SCHEMA_VERSION
        if "epic_id" not in ledger:
            ledger["epic_id"] = new_entry.get("epic_id", "")
        if not isinstance(ledger.get("cycles"), list):
            ledger["cycles"] = []
    except (json.JSONDecodeError, OSError):
        # Corrupted file — start fresh
        ledger = {"schema_version": SCHEMA_VERSION, "epic_id": new_entry.get("epic_id", ""), "cycles": []}
else:
    ledger = {"schema_version": SCHEMA_VERSION, "epic_id": new_entry.get("epic_id", ""), "cycles": []}

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
