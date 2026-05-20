#!/usr/bin/env bash
# migrate-ledger-v11-to-v12.sh
# Migrate a cycle-ledger.json from schema v1.1.0 to v1.2.0.
#
# Usage:
#   migrate-ledger-v11-to-v12.sh <ledger-path>
#
# Behaviour:
#   - Reads the ledger at <ledger-path>.
#   - If schema_version is already "1.2.0", exits 0 with no changes (idempotent).
#   - For each cycle entry that lacks a pr_number field, adds pr_number=0
#     (the _SENTINEL_PR_NUMBER — marks "pre-v1.2.0 origin").
#   - Cycle entries that already have a pr_number field are left unchanged.
#   - Bumps schema_version to "1.2.0".
#   - Writes the updated ledger back to the same path atomically (temp-and-rename).
#   - Malformed cycle entries (non-objects) are logged to stderr and skipped;
#     migration continues for the remaining valid entries.
#
# Exit codes:
#   0  Success (migration completed, or ledger was already v1.2.0)
#   1  Fatal error (missing argument, file not found, JSON parse failure at
#      the top-level object level, or Python not available)
#
# Contract reference: docs/contracts/cycle-ledger.md (under CLAUDE_PLUGIN_ROOT)
#   Sentinel-pr_number Migration Rule (v1.1.0 → v1.2.0):
#     Entries lacking pr_number are assigned pr_number=0 (_SENTINEL_PR_NUMBER).
#     Sentinel signals "unknown PR" (pre-v1.2.0 origin). Writers MUST NEVER
#     emit pr_number=0 for new cycles — only this migration script may do so.

# NOTE: -e intentionally omitted so that malformed-entry warnings do not abort
# the migration loop.  We manage exit explicitly.
set -uo pipefail

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    printf 'ERROR: missing argument\nUsage: %s <ledger-path>\n' "$0" >&2
    exit 1
fi

_LEDGER_PATH="$1"

if [[ ! -f "$_LEDGER_PATH" ]]; then
    printf 'ERROR: ledger file not found: %s\n' "$_LEDGER_PATH" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Delegate to Python for JSON manipulation (atomic temp-and-rename write)
# ---------------------------------------------------------------------------
python3 - "$_LEDGER_PATH" <<'PYTHON'
import json
import os
import sys
import tempfile

SENTINEL_PR_NUMBER = 0
ledger_path = sys.argv[1]

# --- Load ledger ---
try:
    with open(ledger_path, encoding="utf-8") as f:
        ledger = json.load(f)
except json.JSONDecodeError as e:
    print(f"ERROR: could not parse JSON in {ledger_path}: {e}", file=sys.stderr)
    sys.exit(1)
except OSError as e:
    print(f"ERROR: could not read {ledger_path}: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(ledger, dict):
    print(f"ERROR: top-level JSON value is not an object in {ledger_path}", file=sys.stderr)
    sys.exit(1)

# --- Idempotency check: already v1.2.0 ---
schema_version = ledger.get("schema_version", "")
if schema_version == "1.2.0":
    # No changes needed — exit cleanly without writing.
    sys.exit(0)

# --- Migrate cycle entries ---
cycles = ledger.get("cycles", [])
migrated_cycles = []
had_malformed = False

for entry in cycles:
    if not isinstance(entry, dict):
        print(
            f"WARNING: skipping malformed cycle entry (not an object): {entry!r}",
            file=sys.stderr,
        )
        had_malformed = True
        migrated_cycles.append(entry)  # preserve as-is (do not drop)
        continue

    # Only entries that lack pr_number get the sentinel; existing pr_number is preserved.
    if "pr_number" not in entry:
        entry = dict(entry)  # shallow copy to avoid mutating during iteration
        entry["pr_number"] = SENTINEL_PR_NUMBER

    migrated_cycles.append(entry)

ledger["cycles"] = migrated_cycles
ledger["schema_version"] = "1.2.0"

# --- Atomic write (temp-and-rename, same directory for cross-fs safety) ---
ledger_dir = os.path.dirname(os.path.abspath(ledger_path))
try:
    fd, tmp_path = tempfile.mkstemp(prefix="cycle-ledger-migrate.", dir=ledger_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(ledger, f, indent=2)
        os.replace(tmp_path, ledger_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise
except OSError as e:
    print(f"ERROR: could not write migrated ledger to {ledger_path}: {e}", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYTHON
