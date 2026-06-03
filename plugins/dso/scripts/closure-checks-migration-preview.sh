#!/usr/bin/env bash
# closure-checks-migration-preview.sh
#
# Phase 4 cutover gate input — chunk F (operational-dry-run) of the multi-opus
# coherence walkthrough. Lists the N most recently closed `brainstorm:complete`-
# tagged epics, runs a haiku classifier on each SC/DoD/AC item, and emits a JSON
# array describing what the bulk migration WOULD do if it ran today. Does NOT
# write events, does NOT modify tickets, does NOT dispatch the completion-
# verifier agent. Read-only preview only.
#
# Implements story 5362-7f18-4f37-4fa9 Brainstorm Decision §3.
# Consumed by scripts/coherence-walkthrough.sh and chunk F's opus prompt.
#
# Usage:
#   closure-checks-migration-preview.sh [--limit N] [--output FILE]
#
# Flags:
#   --limit N     Number of most-recent brainstorm:complete-tagged closed
#                 epics to sample. Default: 10.
#   --output F    Write JSON output to FILE. Default: stdout.
#
# Exit codes:
#   0 — Preview produced successfully (may be an empty array if zero eligible
#       epics exist; that's a valid signal, not an error).
#   1 — Hard error (ticket CLI unavailable, JSON parsing failed).
#   2 — Soft error (no ANTHROPIC_API_KEY; classifier could not run). Emits
#       {"preview_error": "<reason>"} on stdout/file; chunk F will treat as
#       AMBIGUOUS.

set -uo pipefail

# ── Resolve repo root and dependencies ──────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
    echo '{"preview_error": "not in a git repository"}'
    exit 2
fi

TICKET_CLI="$REPO_ROOT/.claude/scripts/dso"
if [[ ! -x "$TICKET_CLI" ]]; then
    echo '{"preview_error": "ticket CLI shim not found at .claude/scripts/dso"}'
    exit 2
fi

# ── Parse arguments ──────────────────────────────────────────────────────────
LIMIT=10
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        --limit=*)
            LIMIT="${1#--limit=}"
            shift
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT_FILE="${1#--output=}"
            shift
            ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Validate LIMIT is a positive integer
if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --limit must be a positive integer (got: $LIMIT)" >&2
    exit 1
fi

emit_output() {
    local payload="$1"
    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '%s\n' "$payload" > "$OUTPUT_FILE"
    else
        printf '%s\n' "$payload"
    fi
}

# ── API-key gate ─────────────────────────────────────────────────────────────
# The classifier requires an Anthropic API key. Without it, chunk F has no
# classification data and must surface as AMBIGUOUS. Emit a structured error
# rather than producing junk counts.
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    emit_output '{"preview_error": "ANTHROPIC_API_KEY not set; classifier cannot run", "epics": []}'
    exit 2
fi

# ── Enumerate eligible epics ─────────────────────────────────────────────────
# Eligible = epics with brainstorm:complete tag AND status closed.
# `ticket list-epics --all --has-tag=brainstorm:complete` returns all epics
# with the tag; we filter to closed and sort by closure timestamp (most-recent
# first), then take the top N.

ELIGIBLE_JSON="$(
    "$TICKET_CLI" ticket list \
        --type=epic \
        --status=closed \
        --format=llm 2>/dev/null \
    | python3 -c '
import json, sys
try:
    items = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            t = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Filter by tag in python — ticket list does not support --has-tag.
        tags = t.get("tg") or t.get("tags") or []
        if "brainstorm:complete" not in tags:
            continue
        items.append(t)
    items.sort(key=lambda t: t.get("closed_at", t.get("created_at", 0)), reverse=True)
    print(json.dumps(items))
except Exception as e:
    print("PARSE_ERROR:" + str(e), file=sys.stderr)
    sys.exit(1)
' 2>/dev/null
)"

if [[ -z "$ELIGIBLE_JSON" ]] || [[ "$ELIGIBLE_JSON" == "[]" ]]; then
    emit_output '{"preview_error": "no closed brainstorm:complete-tagged epics found", "epics": []}'
    exit 0
fi

# ── Per-epic classifier dispatch ─────────────────────────────────────────────
# For each of the top-N epics, extract SC/DoD/AC items from the description
# and dispatch the haiku classifier per item. Aggregate counts.
#
# This script is a PREVIEW — it does NOT use the same haiku-dispatch entry
# point story ad70 will build for production migration. It uses a minimal
# inline classifier prompt that asks: "is this item end-state, transitional,
# or uncertain?" The production classifier (story ad70) will be more
# sophisticated; this preview gives chunk F the BEFORE/AFTER signal it needs
# to validate the migration prevents false positives.

CLASSIFIER_PROMPT='You are classifying one item from a planning ticket. The item is either:
- end-state: a durable property of the system that could be false before the work and true only after this specific work. Phrased as ongoing system behavior.
  Examples: "the system supports OAuth", "the legacy adapter is absent from imports".
- transitional: a one-time migration or task completion, not a durable property.
  Examples: "OAuth has been migrated", "legacy adapter has been removed".
- uncertain: neither cleanly end-state nor cleanly transitional.

Respond with exactly one token: end-state, transitional, or uncertain.

Item: '

# Python helper that calls the Anthropic API via the SDK if available, otherwise
# falls back to curl. Keeps the script bash-only at top level.
classify_items() {
    local epic_json_path="$1"
    python3 - "$epic_json_path" <<'PYEOF'
import json, os, sys, re

epic_json_path = sys.argv[1]
with open(epic_json_path, encoding="utf-8") as f:
    epics = json.load(f)

# Dispatch haiku classifier via stdlib urllib (avoids anthropic SDK
# package dependency — the host environment may not have it installed).
import urllib.request
import urllib.error

API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
if not API_KEY:
    print(json.dumps({"preview_error": "ANTHROPIC_API_KEY not set; classifier cannot run", "epics": []}))
    sys.exit(2)

ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
CLASSIFIER_MODEL = os.environ.get("DSO_CLASSIFIER_MODEL", "claude-haiku-4-5-20251001")

# Extract items from each epic's ## Success Criteria, ## Done Definitions,
# and ## Acceptance Criteria sections. Returns list of strings.
def extract_items(description):
    items = []
    sections = ['## Success Criteria', '## Done Definitions', '## Acceptance Criteria']
    for section_name in sections:
        # Locate section start
        m = re.search(re.escape(section_name) + r'\s*\n', description)
        if not m:
            continue
        # Extract until next ## heading or EOF
        body_start = m.end()
        next_section = re.search(r'\n## ', description[body_start:])
        body_end = body_start + next_section.start() if next_section else len(description)
        body = description[body_start:body_end]
        # Each bullet is a top-level item ("- ..." or "* ...")
        for line in body.split('\n'):
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith(('-', '*')):
                # Strip leading bullet character and surrounding whitespace
                item_text = stripped.lstrip('-* ').strip()
                if item_text:
                    items.append(item_text)
    return items

CLASSIFIER_PROMPT = '''You are classifying one item from a planning ticket. The item is either:
- end-state: a durable property of the system that could be false before the work and true only after this specific work. Phrased as ongoing system behavior.
  Examples: "the system supports OAuth", "the legacy adapter is absent from imports".
- transitional: a one-time migration or task completion, not a durable property.
  Examples: "OAuth has been migrated", "legacy adapter has been removed".
- uncertain: neither cleanly end-state nor cleanly transitional.

Respond with exactly one token: end-state, transitional, or uncertain.

Item: '''

def classify_one(item_text):
    try:
        body = json.dumps({
            "model": CLASSIFIER_MODEL,
            "max_tokens": 10,
            "messages": [{"role": "user", "content": CLASSIFIER_PROMPT + item_text}],
        }).encode("utf-8")
        req = urllib.request.Request(
            ANTHROPIC_API_URL,
            data=body,
            method="POST",
            headers={
                "x-api-key": API_KEY,
                "anthropic-version": ANTHROPIC_VERSION,
                "content-type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read().decode("utf-8"))
        content = data.get("content") or []
        resp = ""
        for block in content:
            if block.get("type") == "text":
                resp += block.get("text", "")
        resp = resp.strip().lower()
        if resp.startswith("end"):
            return "end-state"
        if resp.startswith("trans"):
            return "transitional"
        if resp.startswith("uncertain"):
            return "uncertain"
        return "uncertain"
    except Exception:
        return "uncertain"

results = []
for epic in epics:
    epic_id = epic.get('ticket_id') or epic.get('id', 'unknown')
    title = epic.get('title') or epic.get('ttl', '')
    desc = epic.get('description') or epic.get('desc', '')
    items = extract_items(desc)
    counts = {'end-state': 0, 'transitional': 0, 'uncertain': 0}
    sample_transitional = []
    for item in items:
        label = classify_one(item)
        counts[label] += 1
        if label == 'transitional' and len(sample_transitional) < 3:
            sample_transitional.append(item)
    results.append({
        'epic_id': epic_id,
        'epic_title': title,
        'items_total': len(items),
        'items_classified_end_state': counts['end-state'],
        'items_classified_transitional': counts['transitional'],
        'items_classified_uncertain': counts['uncertain'],
        'sample_transitional_items': sample_transitional,
    })

print(json.dumps({'epics': results}))
PYEOF
}

# Truncate eligible epic list to LIMIT
TRUNCATED_JSON="$(
    printf '%s' "$ELIGIBLE_JSON" \
    | python3 -c "import json, sys; items = json.load(sys.stdin); print(json.dumps(items[:$LIMIT]))"
)"

# Write to temp file (Python helper reads from disk to avoid arg-length issues)
EPIC_TMP="$(mktemp /tmp/coherence-preview-epics.XXXXXX.json)"
trap 'rm -f "$EPIC_TMP"' EXIT
printf '%s' "$TRUNCATED_JSON" > "$EPIC_TMP"

PREVIEW_JSON="$(classify_items "$EPIC_TMP")"

emit_output "$PREVIEW_JSON"
exit 0
