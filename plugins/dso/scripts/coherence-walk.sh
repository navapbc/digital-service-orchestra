#!/usr/bin/env bash
# coherence-walk.sh
# Multi-opus coherence gate: scan compiled ticket artifacts and flag when
# ## Success Criteria and ## Closure Checks conflict or overlap.
#
# DESIGN NOTE: This script is designed to eventually invoke LLM (multi-opus)
# analysis for semantic coherence checking. The current implementation uses
# deterministic heuristic keyword checks (transitional-language detection and
# text-overlap analysis) to keep validation fast and reproducible. Future
# integration point: replace/augment the Python heuristic pass with a call
# to the Anthropic API when ANTHROPIC_API_KEY is available.
#
# Usage:
#   coherence-walk.sh [--target <host-project-root>] [--epic <epic-id>]
#
# Flags:
#   --target <path>   Path to the host project root (default: git rev-parse --show-toplevel)
#   --epic   <id>     Restrict scan to a single epic (and its children)
#
# Output (stdout):
#   One line per scanned epic/story:
#     PASS <ticket-id>
#     FAIL <ticket-id> <reason>
#     AMBIGUOUS <ticket-id> <reason>
#   Then for each FAIL/AMBIGUOUS ticket, a recommended next step:
#     NEXT_STEP <ticket-id>: <recommended action>
#   Final aggregate summary line:
#     COHERENCE_SUMMARY: N_pass=X N_fail=Y N_ambiguous=Z
#
# Exit codes:
#   0 — All epics/stories PASS (or only AMBIGUOUS; no outright FAIL)
#   1 — One or more epics/stories FAIL
#   2 — Error (e.g., .tickets-tracker not found)  # tickets-boundary-ok

set -euo pipefail

# ── Self-location ────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ──────────────────────────────────────────────────────────
_TARGET=""
_EPIC_FILTER=""

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
        --epic)
            _EPIC_FILTER="$2"
            shift 2
            ;;
        --epic=*)
            _EPIC_FILTER="${1#--epic=}"
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

# Resolve target (default: git rev-parse --show-toplevel from script context)
if [ -z "$_TARGET" ]; then
    _TARGET="$(git rev-parse --show-toplevel)"
fi

# ── Ticket tracker location ───────────────────────────────────────────────────
_TRACKER_DIR="$_TARGET/.tickets-tracker"  # tickets-boundary-ok

if [ ! -d "$_TRACKER_DIR" ]; then
    echo "Error: no .tickets-tracker at '$_TARGET'" >&2  # tickets-boundary-ok
    exit 2
fi

# ── Coherence analysis via Python (heuristic pass) ───────────────────────────
# Runs deterministic heuristic checks:
#   - Transitional language in ## Success Criteria → AMBIGUOUS
#   - SC items that duplicate ## Closure Checks text → FAIL
#   - No ## Success Criteria section → PASS (backward-compat)
#
# Outputs per-artifact lines + NEXT_STEP lines + COHERENCE_SUMMARY.

_EPIC_FILTER_ARG=""
if [ -n "$_EPIC_FILTER" ]; then
    _EPIC_FILTER_ARG="$_EPIC_FILTER"
fi

_analysis_exit=0
_analysis_output=$(python3 - "$_TRACKER_DIR" "$_EPIC_FILTER_ARG" <<'PYEOF'
import json
import os
import re
import sys

TRACKER = sys.argv[1]
EPIC_FILTER = sys.argv[2] if len(sys.argv) > 2 else ""

EPIC_STORY_TYPES = {"epic", "story"}

# Transitional-language keywords that signal a SC item is not a durable end-state.
# These phrases suggest the criterion is describing current state or a temporary
# measure rather than a stable goal — AMBIGUOUS.
TRANSITIONAL_PATTERNS = [
    r'\bcurrently\b',
    r'\btemporary\b',
    r'\btemporarily\b',
    r'\buntil\b',
    r'\bTODO\b',
    r'\bTBD\b',
    r'\bpending\b',
    r'\bfor now\b',
    r'\bshort[-\s]term\b',
    r'\bworkaround\b',
    r'\bstop[-\s]gap\b',
]
_TRANSITIONAL_RE = re.compile('|'.join(TRANSITIONAL_PATTERNS), re.IGNORECASE)


def _normalize_line(line: str) -> str:
    """Strip leading markdown list markers and whitespace for comparison."""
    return re.sub(r'^[\s\-\*\+\d\.]+', '', line).strip().lower()


def _extract_section_items(description: str, heading: str) -> list:
    """
    Extract non-empty list items from a markdown section.
    Returns normalized strings for comparison.
    """
    lines = description.split('\n')
    in_section = False
    items = []
    for line in lines:
        stripped = line.strip()
        if stripped == heading:
            in_section = True
            continue
        if in_section:
            # Stop at next ## heading
            if stripped.startswith('## '):
                break
            if stripped.startswith('-') or stripped.startswith('*') or stripped.startswith('+'):
                items.append(_normalize_line(stripped))
            elif re.match(r'^\d+\.', stripped):
                items.append(_normalize_line(stripped))
    return [i for i in items if i]


def _check_coherence(ticket_id: str, ticket_type: str, description: str):
    """
    Run heuristic coherence checks on a single ticket description.
    Returns (verdict, reason) where verdict is PASS/FAIL/AMBIGUOUS.
    """
    if not description:
        return ("PASS", "")

    sc_items = _extract_section_items(description, "## Success Criteria")
    closure_items = _extract_section_items(description, "## Closure Checks")

    # Backward-compat: no SC section → PASS
    if not sc_items:
        return ("PASS", "")

    # Check 1: FAIL if SC items duplicate Closure Checks items
    if closure_items:
        sc_set = set(sc_items)
        closure_set = set(closure_items)
        overlap = sc_set & closure_set
        if overlap:
            sample = next(iter(overlap))
            return ("FAIL", f"SC item duplicates Closure Checks text: '{sample[:60]}'")

    # Check 2: AMBIGUOUS if SC items contain transitional language
    for item in sc_items:
        match = _TRANSITIONAL_RE.search(item)
        if match:
            return ("AMBIGUOUS", f"SC item contains transitional language: '{item[:60]}'")

    return ("PASS", "")


def _get_compiled_state(tdir):
    """
    Walk the event log and return compiled state dict with keys:
      ticket_type, title, status, description
    Returns None if unreadable or no events.
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

        if etype == "SNAPSHOT":
            state = dict(data)
        elif etype == "CREATE":
            state.update({
                k: v for k, v in data.items()
                if k in ("ticket_type", "title", "status", "description")
            })
        elif etype in ("UPDATE", "TRANSITION"):
            for k in ("ticket_type", "title", "status", "description"):
                if k in data:
                    state[k] = data[k]

    return state if state else None


# ── Main scan ─────────────────────────────────────────────────────────────────
results = []  # list of (verdict, ticket_id, reason)

try:
    ticket_dirs = sorted(os.listdir(TRACKER))
except OSError as exc:
    print(f"Error: cannot read tracker: {exc}", file=sys.stderr)
    sys.exit(2)

for entry in ticket_dirs:
    tdir = os.path.join(TRACKER, entry)
    if not os.path.isdir(tdir):
        continue

    state = _get_compiled_state(tdir)
    if not state:
        continue

    ticket_type = state.get("ticket_type", "")
    if ticket_type not in EPIC_STORY_TYPES:
        continue

    ticket_id = entry

    # Apply epic filter if specified
    if EPIC_FILTER:
        if ticket_id != EPIC_FILTER and state.get("parent_id") != EPIC_FILTER:
            continue

    description = state.get("description", "") or ""
    verdict, reason = _check_coherence(ticket_id, ticket_type, description)
    results.append((verdict, ticket_id, reason))

# ── Output per-artifact verdict lines ────────────────────────────────────────
n_pass = 0
n_fail = 0
n_ambiguous = 0

for verdict, ticket_id, reason in results:
    if verdict == "PASS":
        print(f"PASS {ticket_id}")
        n_pass += 1
    elif verdict == "FAIL":
        print(f"FAIL {ticket_id} {reason}")
        n_fail += 1
    elif verdict == "AMBIGUOUS":
        print(f"AMBIGUOUS {ticket_id} {reason}")
        n_ambiguous += 1

# ── Output recommended next steps for FAIL/AMBIGUOUS ────────────────────────
for verdict, ticket_id, reason in results:
    if verdict == "FAIL":
        print(f"NEXT_STEP {ticket_id}: Revise ## Success Criteria to remove text that duplicates ## Closure Checks. SC items should capture measurable done conditions; Closure Checks should describe durable end-state.")
    elif verdict == "AMBIGUOUS":
        print(f"NEXT_STEP {ticket_id}: Review ## Success Criteria for transitional language. Replace phrases like 'currently', 'temporary', 'TODO', 'pending' with durable end-state descriptions.")

# ── Summary line ──────────────────────────────────────────────────────────────
print(f"COHERENCE_SUMMARY: N_pass={n_pass} N_fail={n_fail} N_ambiguous={n_ambiguous}")

# Exit non-zero if any FAIL (AMBIGUOUS alone returns 0)
if n_fail > 0:
    sys.exit(1)

sys.exit(0)
PYEOF
) || _analysis_exit=$?

echo "$_analysis_output"
exit $_analysis_exit
