#!/usr/bin/env bash
# audit-closure-checks-migration.sh
# Read-only audit: scan all tickets in .tickets-tracker/ and report which  # tickets-boundary-ok
# epics/stories lack a ## Closure Checks section.
#
# Usage:
#   audit-closure-checks-migration.sh [--target <host-project-root>]
#
# Flags:
#   --target <path>     Path to the host project root (default: git rev-parse --show-toplevel)
#
# Output (stdout):
#   One tab-separated line per epic/story that needs migration:
#     <ticket-id>\t<type>\t<status>\t<title>
#
# Exit codes:
#   0 — One or more epics/stories lack ## Closure Checks (migration needed)
#   1 — All epics/stories already have ## Closure Checks (migration complete)
#   2 — Error (e.g., .tickets-tracker not found)  # tickets-boundary-ok

set -euo pipefail

# ── Self-location ────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ──────────────────────────────────────────────────────────
_TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            _TARGET="$2"
            shift 2
            ;;
        --target=*)
            _TARGET="${1#--target=}"
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

# Resolve target (default: git rev-parse --show-toplevel from within script context)
if [ -z "$_TARGET" ]; then
    _TARGET="$(git rev-parse --show-toplevel)"
fi

# ── Ticket tracker location ───────────────────────────────────────────────────
_TRACKER_DIR="$_TARGET/.tickets-tracker"  # tickets-boundary-ok

if [ ! -d "$_TRACKER_DIR" ]; then
    echo "Error: no .tickets-tracker at '$_TARGET'" >&2  # tickets-boundary-ok
    exit 2
fi

# ── Single-pass audit ────────────────────────────────────────────────────────
# Scan every epic/story ticket; emit tab-separated lines for those lacking
# a ## Closure Checks section.
#
# stdout contract:
#   <ticket-id>\t<type>\t<status>\t<title>  — one line per ticket needing migration
_python_exit=0
_audit_output=$(python3 - "$_TRACKER_DIR" <<'PYEOF'
import json
import os
import sys

TRACKER = sys.argv[1]
CLOSURE_HEADING = "## Closure Checks"
EPIC_STORY_TYPES = {"epic", "story"}


def _get_compiled_state(tdir):
    """
    Walk the event log and return the compiled state dict with keys:
      ticket_type, title, status, description
    Returns None if the ticket directory is unreadable or has no events.
    """
    state = {}
    try:
        files = sorted(
            f for f in os.listdir(tdir)
            if f.endswith(".json") and not f.startswith(".")
        )
    except OSError:
        return None

    for fn in files:
        try:
            with open(os.path.join(tdir, fn)) as f:
                ev = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        etype = ev.get("event_type", "")
        data = ev.get("data") or {}

        if etype == "CREATE":
            state.update({k: v for k, v in data.items() if v is not None})
        elif etype == "EDIT":
            fields = data.get("fields") or {}
            state.update({k: v for k, v in fields.items() if v is not None})
        elif etype == "SNAPSHOT":
            cs = data.get("compiled_state") or {}
            state.update({k: v for k, v in cs.items() if v is not None})

    return state if state else None


try:
    entries = sorted(os.listdir(TRACKER))
except OSError:
    sys.exit(0)

found_any = False
for tid in entries:
    if tid.startswith("."):
        continue
    tdir = os.path.join(TRACKER, tid)
    if not os.path.isdir(tdir):
        continue

    state = _get_compiled_state(tdir)
    if state is None:
        continue

    ticket_type = state.get("ticket_type", "")
    if ticket_type not in EPIC_STORY_TYPES:
        continue

    description = state.get("description", "") or ""
    if CLOSURE_HEADING in description:
        # Already has ## Closure Checks — skip
        continue

    title = state.get("title", "") or ""
    status = state.get("status", "open") or "open"

    found_any = True
    print(f"{tid}\t{ticket_type}\t{status}\t{title}")

# Signal to bash: 0 = found tickets needing migration, 1 = all migrated
sys.exit(0 if found_any else 1)
PYEOF
) || _python_exit=$?

# Propagate exit code from python: 0=found, 1=all migrated
if [ $_python_exit -eq 1 ]; then
    # All tickets already migrated
    exit 1
fi

# Print the tab-separated audit lines to stdout
printf '%s' "$_audit_output"
if [ -n "$_audit_output" ]; then
    # Ensure trailing newline
    printf '\n'
fi

exit 0
