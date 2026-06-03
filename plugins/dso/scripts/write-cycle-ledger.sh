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
#   --pr-number <int>        PR number for v1.2.0 contract. When set, the
#                            emitted cycle entry includes a pr_number field.
#                            Also used as the PR for --reconstruct-from-pr.
#                            Falls back to DSO_CI_REVIEW_PR env var when absent.
#   --reconstruct-from-pr    Trigger CI reconstruction mode: parse PR comments
#                            for prior DSO-Review-Cycle entries before appending
#                            the current cycle. Requires --pr-number or
#                            DSO_CI_REVIEW_PR env var. Parser recognizes v1.2.0
#                            (pr_number=, commit_sha=, findings_hash=, tuples=),
#                            v1.1.0 (no pr_number=), and legacy v1.0.0
#                            (findings-hash= only) markers.
#
# Output schema (cycle-ledger.json) — see the cycle-ledger.md contract
# (${CLAUDE_PLUGIN_ROOT}/docs/contracts/cycle-ledger.md) for the full v1.2.0 spec:
#   {
#     "schema_version": "1.2.0",
#     "epic_id": "<epic_id or empty>",
#     "cycles": [ <cycle_entry>, ... ],
#     "reconstruction_gaps": true   # only present when gaps detected during reconstruction
#   }
# Each cycle entry carries: cycle_num, timestamp_utc, findings_hash, plus the
# v1.1.0 fields commit_sha (string) and findings (array of [file, line_range,
# category] string tuples), plus the v1.2.0 pr_number field (when > 0).
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
pr_number_arg=""

# Top-level positional handler for the parity test form:
#   bash write-cycle-ledger.sh --reconstruct-from-pr <pr-number> <repo>
# Delegates to the Python CLI (cycle_ledger._cli_main) which uses the
# shared cycle_marker_format grammar — eliminating the shell-embedded
# parser drift class (bug 9788).
#
# Uses the same _PLUGIN_ROOT resolution pattern as the deps.sh source
# above (CLAUDE_PLUGIN_ROOT env first, SCRIPT_DIR/.. fallback) to avoid
# introducing a relative path that check-plugin-scripts-no-relative-paths
# would flag.
if [[ "${1:-}" == "--reconstruct-from-pr" && $# -ge 3 && "${2:-}" =~ ^[0-9]+$ ]]; then
    _pos_pr="$2"
    _pos_repo="$3"
    _out_dir="${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-$(get_artifacts_dir)}"
    if [[ -z "$_out_dir" ]]; then
        echo "error: cannot resolve artifacts dir (set WORKFLOW_PLUGIN_ARTIFACTS_DIR)" >&2
        exit 1
    fi
    mkdir -p "$_out_dir"
    PYTHONPATH="${_PLUGIN_ROOT}/scripts${PYTHONPATH:+:$PYTHONPATH}" \
        python3 -m dso_ci_review.cycle_ledger reconstruct-from-pr "$_pos_pr" "$_pos_repo" \
        > "$_out_dir/cycle-ledger.json"
    exit $?
fi

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
            shift
            ;;
        --pr-number)
            pr_number_arg="$2"
            shift 2
            ;;
        --pr-number=*)
            pr_number_arg="${1#--pr-number=}"
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

    # Input validation (bug 7fe1-c997): reject path-traversal and non-integer
    # inputs early — these guards were lost in the schema-v1.1.0 refactor and
    # are required by test-write-cycle-ledger.sh.
    if [[ "$findings_hash" == *..* || "$findings_hash" == */* ]]; then
        echo "error: --findings-hash must not contain path-traversal characters ('..' or '/')" >&2
        exit 1
    fi

    if [[ "$epic_id" == *..* || "$epic_id" == */* ]]; then
        echo "error: --epic-id must not contain path-traversal characters ('..' or '/')" >&2
        exit 1
    fi

    if ! [[ "$cycle_num" =~ ^[0-9]+$ ]]; then
        echo "error: --cycle-num must be a non-negative integer" >&2
        exit 1
    fi

    if [[ -n "$pr_number_arg" ]] && ! [[ "$pr_number_arg" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: --pr-number must be a positive integer (PR numbers start at 1); got '$pr_number_arg'" >&2
        exit 1
    fi

    if [[ "$reconstruct_from_pr" -eq 1 ]]; then
        # PR number resolution: --pr-number CLI flag wins; fall back to env var.
        # Matches the resolution order at line 321 (PR_NUMBER assignment).
        _pr_resolved="${pr_number_arg:-${DSO_CI_REVIEW_PR:-}}"
        if [[ -z "$_pr_resolved" ]] || ! [[ "$_pr_resolved" =~ ^[0-9]+$ ]]; then
            echo "error: PR number must be a positive integer when --reconstruct-from-pr is set (set via --pr-number or DSO_CI_REVIEW_PR env)" >&2
            exit 1
        fi
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
    # --pr-number CLI flag wins; fall back to env var. Bug 9788 v3 fix scope:
    # the shell writer must emit v1.2.0-compliant ledger entries that include
    # the pr_number field.
    PR_NUMBER="${pr_number_arg:-${DSO_CI_REVIEW_PR:-}}"

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
commit_sha       = sys.argv[10]
findings_raw     = sys.argv[11]

# v1.2.0 schema constants — keep in sync with cycle-ledger.md contract
SCHEMA_VERSION = "1.2.0"

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
                parsed_entries = []
                for line in lines:
                    entry, gap = parse_review_cycle_line(line)
                    if entry is None:
                        continue
                    if gap:
                        reconstruction_gaps = True
                    parsed_entries.append(entry)
                if not parsed_entries:
                    reconstruction_gaps = True
                else:
                    cycles = parsed_entries
            except Exception:
                reconstruction_gaps = True
        else:
            reconstruction_gaps = True

        # Append the current cycle entry (v1.2.0 fields populated from args).
        # pr_number is included when > 0 (bug 9788 v3: shell writer must emit
        # v1.2.0 with pr_number per cycle-ledger.md:67).
        _new_entry = {
            "cycle_num": cycle_num,
            "timestamp_utc": timestamp_utc,
            "findings_hash": findings_hash,
            "commit_sha": commit_sha,
            "findings": findings_value,
        }
        try:
            _pr_int = int(pr_number) if pr_number else 0
        except (TypeError, ValueError):
            _pr_int = 0
        if _pr_int > 0:
            _new_entry["pr_number"] = _pr_int
        cycles.append(_new_entry)

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

        # Duplicate-cycle guard (bug 7fe1-c997): reject if cycle_num already
        # present in the ledger. Required by test-write-cycle-ledger.sh.
        # cycle_num is parsed as int at line 273 above; we also int-coerce the
        # ledger's stored value defensively so type drift between writers (int
        # vs. JSON-stringified int) cannot bypass the check.
        target_cycle_num = int(cycle_num)
        for existing in ledger.get("cycles", []):
            raw_cn = existing.get("cycle_num")
            if raw_cn is None:
                continue
            try:
                existing_cn = int(raw_cn)
            except (TypeError, ValueError):
                continue
            if existing_cn == target_cycle_num:
                print(
                    f"error: cycle_num {target_cycle_num} already exists in ledger",
                    file=sys.stderr,
                )
                sys.exit(1)

        new_entry = {
            "cycle_num": cycle_num,
            "timestamp_utc": timestamp_utc,
            "findings_hash": findings_hash,
            "commit_sha": commit_sha,
            "findings": findings_value,
        }
        # pr_number when provided (bug 9788 v3: v1.2.0 contract)
        try:
            _pr_int = int(pr_number) if pr_number else 0
        except (TypeError, ValueError):
            _pr_int = 0
        if _pr_int > 0:
            new_entry["pr_number"] = _pr_int
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

SCHEMA_VERSION = "1.2.0"

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
