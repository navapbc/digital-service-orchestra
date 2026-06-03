#!/usr/bin/env bash
# closure-checks-classifier-pass.sh
#
# Phase 2 classifier pass — internal helper to migrate-closure-checks.sh.
# Implements story ad70-f38a-7684-4e00 DD1–DD8. Invoked once per ticket from
# the main script when --classify is set.
#
# What this script does (per ticket):
#   1. Capture or read a snapshot of the ticket's description (DD6).
#   2. Extract SC/DD/AC items from the snapshot description.
#   3. Dispatch the haiku classifier on each item (DD1).
#   4. Validate classifier output against the schema (DD2). Retry once on
#      malformed; mark as ERROR-skip on second failure.
#   5. Apply escalation criteria (DD3): items labelled "uncertain" OR with
#      ranking <= 3 OR labelled "transitional" with any ranking enter the
#      interactive ack flow on /dev/tty (DD4).
#   6. Honor the cross-session 25-item batch cap (DD5).
#   7. Write the per-ticket audit comment (DD7) per the contract at
#      docs/contracts/closure-checks-classifier-audit.md.
#   8. Apply section moves (transitional+accept → SC→CC; others stay).
#   9. Honor --dry-run (DD8): emit the proposed plan to stdout; no audit
#      comment write, no description mutation.
#
# Usage:
#   closure-checks-classifier-pass.sh \
#     --ticket-id <id> \
#     --target <host-repo-root> \
#     --session-id <id> \
#     --migration-run-id <uuid> \
#     --remaining-budget <int> \
#     [--dry-run]
#
# Output (stdout, line-prefixed):
#   ITEM: <ticket-id> <section> <label> <ranking> <decision> <post-section>
#   AUDIT_WRITTEN: <ticket-id>
#   BUDGET_CONSUMED: <int>
#   BATCH_PAUSE: <int>   — if remaining budget reached 0 before all items processed
#   ERROR: <message>
#
# Exit codes:
#   0 — Done, all items for this ticket processed (or no items found)
#   1 — Hard error (missing arg, ticket CLI unavailable, etc.)
#   2 — BATCH_PAUSE: remaining budget exhausted mid-ticket; caller should
#       stop further dispatch and report to the user.

set -uo pipefail

# ── Resolve repo root and plugin paths ──────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "ERROR: not in a git repository" >&2
    exit 1
fi

# ── Parse arguments ──────────────────────────────────────────────────────────
TICKET_ID=""
TARGET=""
SESSION_ID=""
MIGRATION_RUN_ID=""
REMAINING_BUDGET=25
DRYRUN=0
PLAN_OUTPUT=""        # NEW: when set, runs in plan-only mode (no prompting, no mutations)
APPLY_FROM_PLAN=""    # NEW: when set, applies decisions against this plan (no classifier dispatch)
DECISIONS_FILE=""     # NEW: required with --apply-from-plan; contains user decisions per item index

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ticket-id)         TICKET_ID="$2"; shift 2 ;;
        --ticket-id=*)       TICKET_ID="${1#--ticket-id=}"; shift ;;
        --target)            TARGET="$2"; shift 2 ;;
        --target=*)          TARGET="${1#--target=}"; shift ;;
        --session-id)        SESSION_ID="$2"; shift 2 ;;
        --session-id=*)      SESSION_ID="${1#--session-id=}"; shift ;;
        --migration-run-id)  MIGRATION_RUN_ID="$2"; shift 2 ;;
        --migration-run-id=*) MIGRATION_RUN_ID="${1#--migration-run-id=}"; shift ;;
        --remaining-budget)  REMAINING_BUDGET="$2"; shift 2 ;;
        --remaining-budget=*) REMAINING_BUDGET="${1#--remaining-budget=}"; shift ;;
        --dry-run)           DRYRUN=1; shift ;;
        --plan-output)       PLAN_OUTPUT="$2"; shift 2 ;;
        --plan-output=*)     PLAN_OUTPUT="${1#--plan-output=}"; shift ;;
        --apply-from-plan)   APPLY_FROM_PLAN="$2"; shift 2 ;;
        --apply-from-plan=*) APPLY_FROM_PLAN="${1#--apply-from-plan=}"; shift ;;
        --decisions-file)    DECISIONS_FILE="$2"; shift 2 ;;
        --decisions-file=*)  DECISIONS_FILE="${1#--decisions-file=}"; shift ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Mode validation
if [[ -n "$APPLY_FROM_PLAN" && -z "$DECISIONS_FILE" ]]; then
    echo "ERROR: --apply-from-plan requires --decisions-file" >&2
    exit 1
fi

for var in TICKET_ID TARGET SESSION_ID MIGRATION_RUN_ID; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: --${var,,} is required" >&2
        exit 1
    fi
done

TICKET_CLI="$REPO_ROOT/.claude/scripts/dso"
if [[ ! -x "$TICKET_CLI" ]]; then
    echo "ERROR: ticket CLI shim not found at .claude/scripts/dso" >&2
    exit 1
fi

# ── Snapshot directory (DD6) ─────────────────────────────────────────────────
SNAPSHOT_DIR="/tmp/migrate-closure-checks-classify.${SESSION_ID}.snapshot"
mkdir -p "$SNAPSHOT_DIR"

SNAPSHOT_FILE="$SNAPSHOT_DIR/${TICKET_ID}.txt"

# ── Capture or read snapshot ─────────────────────────────────────────────────
SNAPSHOT_TIMESTAMP=""
if [[ -f "$SNAPSHOT_FILE" ]]; then
    SNAPSHOT_TIMESTAMP="$(head -1 "$SNAPSHOT_FILE" | sed 's|^# snapshot_timestamp: ||')"
    DESCRIPTION="$(tail -n +3 "$SNAPSHOT_FILE")"  # skip the timestamp line + blank
else
    SNAPSHOT_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    DESCRIPTION="$("$TICKET_CLI" ticket show "$TICKET_ID" 2>/dev/null | python3 -c '
import json, sys
try:
    t = json.load(sys.stdin)
    print(t.get("description") or "")
except Exception as e:
    print("", end="")
    sys.exit(1)
')"
    if [[ -z "$DESCRIPTION" ]]; then
        echo "ERROR: $TICKET_ID — could not read description" >&2
        exit 1
    fi
    {
        printf '# snapshot_timestamp: %s\n\n' "$SNAPSHOT_TIMESTAMP"
        printf '%s\n' "$DESCRIPTION"
    } > "$SNAPSHOT_FILE"
fi

# ── ANTHROPIC_API_KEY gate (DD1 graceful degradation) ───────────────────────
# apply-from-plan mode uses cached classifications from the plan file and
# never dispatches the classifier, so it does not require the API key.
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "$APPLY_FROM_PLAN" ]]; then
    echo "NOTICE: $TICKET_ID — ANTHROPIC_API_KEY unset; classifier pass skipped" >&2
    echo "BUDGET_CONSUMED: 0"
    exit 0
fi

# ── Run the classifier pass in python ───────────────────────────────────────
# The python helper:
#  - extracts items from SC/DD/AC sections of the snapshot
#  - dispatches haiku per item
#  - emits structured ITEM: lines to stdout
#  - delegates per-item interaction to bash via stdin/stdout markers
#  - writes the audit comment JSON to a temp file on completion
#
# Architecture choice: python emits "ITEM_NEEDS_ACK: <json>" lines for items
# requiring interactive prompt. The outer bash loop reads them, displays to
# the user via /dev/tty, and feeds the answer back to python via stdin.
# This pattern keeps the heavy logic in python while letting bash own the
# terminal interaction.

# Bug 724a-53f1-5d72-45d0: BSD mktemp does NOT substitute X's when they are
# followed by additional characters (.json / .txt). The X's must be the last
# characters of the basename. Files are consumed by path internally — the
# extension was decorative, not load-bearing — so we drop it. This also
# enables parallel script invocations (each gets a unique substituted path).
AUDIT_JSON_FILE="$(mktemp /tmp/audit-comment.XXXXXX)"
NEW_DESC_FILE="$(mktemp /tmp/new-desc.XXXXXX)"
trap 'rm -f "$AUDIT_JSON_FILE" "$NEW_DESC_FILE"' EXIT

# ── Apply-from-plan mode (Claude-driven ack flow) ───────────────────────────
# Reads a plan file (produced earlier by --plan-output mode) plus a decisions
# file (produced by the orchestrator after asking the user). Builds the audit
# comment and applies section moves. Does NOT dispatch the classifier — uses
# the cached classification from the plan.
if [[ -n "$APPLY_FROM_PLAN" ]]; then
    export TICKET_ID SNAPSHOT_TIMESTAMP MIGRATION_RUN_ID DRYRUN AUDIT_JSON_FILE NEW_DESC_FILE SNAPSHOT_FILE APPLY_FROM_PLAN DECISIONS_FILE
    python3 - <<'PYEOF'
import json, os, re, sys

TICKET_ID = os.environ["TICKET_ID"]
SNAPSHOT_TIMESTAMP = os.environ["SNAPSHOT_TIMESTAMP"]
MIGRATION_RUN_ID = os.environ["MIGRATION_RUN_ID"]
DRYRUN = os.environ["DRYRUN"] == "1"
AUDIT_JSON_FILE = os.environ["AUDIT_JSON_FILE"]
NEW_DESC_FILE = os.environ["NEW_DESC_FILE"]
SNAPSHOT_FILE = os.environ["SNAPSHOT_FILE"]
APPLY_FROM_PLAN = os.environ["APPLY_FROM_PLAN"]
DECISIONS_FILE = os.environ["DECISIONS_FILE"]

with open(APPLY_FROM_PLAN, encoding="utf-8") as f:
    plan = json.load(f)
with open(DECISIONS_FILE, encoding="utf-8") as f:
    decisions_obj = json.load(f)

# Index decisions by item index. Keep full decision dicts so override_target
# (when the user explicitly overrides the classifier's proposed_target) is
# honored alongside user_decision. Without override_target, accept respects
# proposed_target; reject/defer keep the item in its original section.
dec_by_index = {d["index"]: d for d in decisions_obj.get("decisions", [])}

# Validate that the decisions file covers every non-auto item in the plan.
# A count mismatch means the orchestrator produced a stale or truncated
# decisions file; silently deferring missing items would cause data loss.
non_auto_items = [it for it in plan["items"] if not it.get("auto_accepted")]
if len(non_auto_items) != len(decisions_obj.get("decisions", [])):
    print(
        f"ERROR: decisions count mismatch: expected {len(non_auto_items)}, "
        f"got {len(decisions_obj.get('decisions', []))}",
        file=sys.stderr,
    )
    sys.exit(1)

# Load snapshot description for section-move regex
with open(SNAPSHOT_FILE, encoding="utf-8") as f:
    raw = f.read()
lines = raw.split("\n")
if lines and lines[0].startswith("# snapshot_timestamp:"):
    lines = lines[2:] if len(lines) > 1 else lines[1:]
description = "\n".join(lines)

audit_items = []
moves = []  # list of original_text values that move SC → CC

for item in plan["items"]:
    idx = item["index"]
    original_text = item["original_text"]
    section = item["original_section"]
    cls = item["classification"]
    label = cls["label"]
    ranking = cls["ranking"]

    if item.get("auto_accepted"):
        decision = "auto"
        # Auto items honor the proposed_target captured at plan time. This is
        # critical for r=5 transitional auto-apply: the plan recorded
        # proposed_target=CC, and the apply step must move SC→CC accordingly.
        target = item.get("proposed_target", section)
    else:
        dec_entry = dec_by_index.get(idx)
        if dec_entry is None:
            decision = "defer"
            target = section
        else:
            decision = dec_entry["user_decision"]
            override = dec_entry.get("override_target")
            if override:
                # Explicit user override takes precedence over classifier's proposed_target
                target = override
            elif decision == "accept":
                target = item.get("proposed_target", section)
            else:
                target = section

    post_section = "CC" if target == "CC" else "SC"
    audit_items.append({
        "original_text": original_text,
        "original_section": section,
        "classification": cls,
        "user_decision": decision,
        "post_migration_section": post_section,
    })
    print(f"ITEM: {TICKET_ID} {section} {label} {ranking} {decision} {post_section}")

    if target == "CC" and not DRYRUN:
        moves.append((idx, "CC", original_text))

# Write audit comment file
audit = {
    "schema_version": 1,
    "migration_run_id": MIGRATION_RUN_ID,
    "snapshot_timestamp": SNAPSHOT_TIMESTAMP,
    "ticket_id": TICKET_ID,
    "items": audit_items,
}
with open(AUDIT_JSON_FILE, "w", encoding="utf-8") as f:
    json.dump(audit, f, indent=2)

# Build new description if there are moves to apply (and not dry-run)
if moves and not DRYRUN:
    new_desc = description
    cc_items_to_add = []
    for idx, target_section, original_text in moves:
        bullet_marker = original_text.split("\n")[0][:80]
        pattern = re.compile(r"(\n[ \t]*[-*]\s+" + re.escape(bullet_marker) + r"[^\n]*(?:\n[ \t]+\S[^\n]*)*)", re.MULTILINE)
        m = pattern.search(new_desc)
        if m:
            new_desc = new_desc[:m.start()] + new_desc[m.end():]
            cc_items_to_add.append(original_text)

    if cc_items_to_add:
        cc_heading = "## Closure Checks"
        if cc_heading in new_desc:
            m = re.search(re.escape(cc_heading) + r"\s*\n(.*?)(?=\n## |\Z)", new_desc, re.DOTALL)
            if m:
                section_end = m.end()
                additions = "\n" + "\n".join(f"- {it}" for it in cc_items_to_add)
                new_desc = new_desc[:section_end] + additions + new_desc[section_end:]
        else:
            additions = "\n\n## Closure Checks\n\n" + "\n".join(f"- {it}" for it in cc_items_to_add) + "\n"
            new_desc = new_desc + additions

    with open(NEW_DESC_FILE, "w", encoding="utf-8") as f:
        f.write(new_desc)

print(f"BUDGET_CONSUMED: {sum(1 for d in dec_by_index.values())}")
sys.exit(0)
PYEOF
    APPLY_RC=$?
    if [[ $APPLY_RC -ne 0 ]]; then
        echo "ERROR: $TICKET_ID — apply-from-plan helper failed" >&2
        exit 1
    fi

    # Write audit comment + description mutation (shared code path with default mode below)
    if [[ "$DRYRUN" = "0" && -s "$AUDIT_JSON_FILE" ]]; then
        AUDIT_BODY="$(cat "$AUDIT_JSON_FILE")"
        "$TICKET_CLI" ticket comment "$TICKET_ID" "CLOSURE_CHECKS_CLASSIFIER_AUDIT: $AUDIT_BODY" 2>&1 | tail -1
        echo "AUDIT_WRITTEN: $TICKET_ID"
    fi
    if [[ "$DRYRUN" = "0" && -s "$NEW_DESC_FILE" ]]; then
        NEW_DESC="$(cat "$NEW_DESC_FILE")"
        "$TICKET_CLI" ticket edit "$TICKET_ID" --description="$NEW_DESC" 2>&1 | tail -1
        echo "DESCRIPTION_UPDATED: $TICKET_ID"
    fi
    exit 0
fi

# Export env vars the python helper reads (default + plan-output modes)
export TICKET_ID SNAPSHOT_TIMESTAMP MIGRATION_RUN_ID REMAINING_BUDGET DRYRUN AUDIT_JSON_FILE NEW_DESC_FILE SESSION_ID SNAPSHOT_FILE PLAN_OUTPUT

python3 - <<'PYEOF'
import json, os, re, sys

TICKET_ID = os.environ["TICKET_ID"]
SNAPSHOT_TIMESTAMP = os.environ["SNAPSHOT_TIMESTAMP"]
MIGRATION_RUN_ID = os.environ["MIGRATION_RUN_ID"]
REMAINING_BUDGET = int(os.environ["REMAINING_BUDGET"])
DRYRUN = os.environ["DRYRUN"] == "1"
AUDIT_JSON_FILE = os.environ["AUDIT_JSON_FILE"]
NEW_DESC_FILE = os.environ["NEW_DESC_FILE"]

# Read description from snapshot
import subprocess
SNAPSHOT_FILE = os.environ.get("SNAPSHOT_FILE") or f"/tmp/migrate-closure-checks-classify.{os.environ.get('SESSION_ID','')}.snapshot/{TICKET_ID}.txt"
with open(SNAPSHOT_FILE, encoding="utf-8") as f:
    raw = f.read()
# Strip the snapshot header (first two lines: "# snapshot_timestamp: ..." + blank)
lines = raw.split("\n")
if lines and lines[0].startswith("# snapshot_timestamp:"):
    lines = lines[2:] if len(lines) > 1 else lines[1:]
description = "\n".join(lines)

# Section names this classifier evaluates
SECTIONS = [("## Success Criteria", "SC"), ("## Done Definitions", "DD"), ("## Acceptance Criteria", "AC")]

def extract_items(desc):
    items = []  # list of (section_code, item_text, start_pos, end_pos)
    for heading, code in SECTIONS:
        m = re.search(re.escape(heading) + r"\s*\n", desc)
        if not m:
            continue
        body_start = m.end()
        next_h = re.search(r"\n## ", desc[body_start:])
        body_end = body_start + next_h.start() if next_h else len(desc)
        body = desc[body_start:body_end]
        # Tokenize TOP-LEVEL bullets only ("- " or "* " with ≤3 leading spaces).
        # Sub-bullets (4+ spaces of indentation) are treated as continuations of
        # their parent bullet, not as separate items. This prevents the
        # classifier from being asked to evaluate sub-items as if they were
        # independent SCs (e.g., SC10's "Chunk A reads..." sub-bullets that
        # describe the validation property of the chunks, not migration targets).
        # See story ad70-f38a-7684-4e00 §6 (smart extraction amendment).
        cur_text = None
        cur_start_line = None
        body_lines = body.split("\n")
        TOP_BULLET_RE = re.compile(r"^[-*]\s+")
        for i, line in enumerate(body_lines):
            if TOP_BULLET_RE.match(line):
                # Top-level bullet — start a new item, flush prior
                if cur_text:
                    items.append((code, cur_text.strip(), 0, 0))
                cur_text = TOP_BULLET_RE.sub("", line, count=1)
            elif cur_text is not None and re.match(r"^\s+\S", line):
                # Indented continuation (any indentation level) — fold into current item
                cur_text += "\n" + line.strip()
            else:
                # Blank or new content; flush
                if cur_text:
                    items.append((code, cur_text.strip(), 0, 0))
                    cur_text = None
        if cur_text:
            items.append((code, cur_text.strip(), 0, 0))
    return items

items_extracted = extract_items(description)

# Filter out empty / very short items
items_extracted = [it for it in items_extracted if len(it[1]) > 5]

# Filter out items inside ← Validates Closure Check / ← Satisfies annotations (those are pointers, not items)
items_extracted = [it for it in items_extracted if not it[1].startswith(("← Validates", "← Satisfies"))]

if not items_extracted:
    # No items to classify; write empty audit comment
    audit = {
        "schema_version": 1,
        "migration_run_id": MIGRATION_RUN_ID,
        "snapshot_timestamp": SNAPSHOT_TIMESTAMP,
        "ticket_id": TICKET_ID,
        "items": [],
    }
    with open(AUDIT_JSON_FILE, "w", encoding="utf-8") as f:
        json.dump(audit, f, indent=2)
    print(f"BUDGET_CONSUMED: 0")
    sys.exit(0)

# Dispatch haiku classifier via stdlib urllib (avoids anthropic SDK
# package dependency — the host environment may not have it installed).
import urllib.request
import urllib.error

API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
if not API_KEY:
    # Already gated above; this branch is defensive.
    print("ERROR: ANTHROPIC_API_KEY missing inside python helper", file=sys.stderr)
    sys.exit(1)

ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
CLASSIFIER_MODEL = os.environ.get("DSO_CLASSIFIER_MODEL", "claude-haiku-4-5-20251001")

CLASSIFIER_PROMPT = '''You are classifying one item from a planning ticket. The item is either:
- end-state: a durable property of the system that could be false before the work and true only after this specific work. Phrased as ongoing system behavior.
  Accept: "the system supports OAuth", "the legacy adapter is absent from imports", "passwords are stored hashed".
- transitional: a one-time migration or task completion, not a durable property. Past-tense or completion-flavored.
  Accept: "OAuth migration is complete", "the legacy adapter has been removed", "the team has reviewed the design".
- uncertain: neither cleanly end-state nor cleanly transitional. Ambiguous between durable property and one-time task.

Respond with ONLY a single-line JSON object (no surrounding prose, no markdown fence) with keys:
- label: "end-state" | "transitional" | "uncertain"
- ranking: integer 1-5 (5 = highly confident in the label, 1 = barely confident)
- rationale: one short sentence explaining the label

Example: {"label":"end-state","ranking":5,"rationale":"durable system capability phrased as ongoing behavior"}

Item to classify:
'''


def classify_one(item_text):
    """Dispatch haiku via direct HTTPS; return dict or None on failure."""
    for attempt in range(2):
        try:
            body = json.dumps({
                "model": CLASSIFIER_MODEL,
                "max_tokens": 200,
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
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            content = data.get("content") or []
            text = ""
            for block in content:
                if block.get("type") == "text":
                    text += block.get("text", "")
            text = text.strip()
            m = re.search(r"\{.*\}", text, re.DOTALL)
            if not m:
                continue
            obj = json.loads(m.group(0))
            if obj.get("label") in ("end-state", "transitional", "uncertain") \
               and isinstance(obj.get("ranking"), int) and 1 <= obj["ranking"] <= 5 \
               and isinstance(obj.get("rationale"), str):
                return obj
        except urllib.error.HTTPError as e:
            err_body = ""
            try:
                err_body = e.read().decode("utf-8")[:200]
            except Exception:
                pass
            print(f"WARN: classifier HTTP {e.code} attempt {attempt+1}: {err_body}", file=sys.stderr)
        except Exception as e:
            print(f"WARN: classifier dispatch attempt {attempt+1} failed: {e}", file=sys.stderr)
    return None

# Process each item, with per-item interaction via /dev/tty
def prompt_user(item_text, classification, proposed_target):
    """Return one of: accept, reject, defer."""
    try:
        tty_in = open("/dev/tty", "r")
        tty_out = open("/dev/tty", "w")
    except OSError:
        # No TTY available; defer per DD4 fallback
        return "defer"
    msg = f"""
── Item review ──────────────────────────────────
Ticket:  {TICKET_ID}
Section: {classification['_original_section']}
Item:    {item_text[:200]}{'…' if len(item_text) > 200 else ''}

Classifier: {classification['label']} (ranking {classification['ranking']})
Rationale:  {classification['rationale']}

Proposed:   {classification['_original_section']} → {proposed_target}
[a]ccept / [r]eject / [d]efer? """
    tty_out.write(msg)
    tty_out.flush()
    while True:
        line = tty_in.readline().strip().lower()
        if line in ("a", "accept"):
            return "accept"
        if line in ("r", "reject"):
            return "reject"
        if line in ("d", "defer"):
            return "defer"
        tty_out.write("Please type a, r, or d: ")
        tty_out.flush()

# Plan-output mode flag (read from env; written by --plan-output bash flag)
PLAN_OUTPUT = os.environ.get("PLAN_OUTPUT", "")

# Build the audit + plan
audit_items = []
moves = []  # list of (item_index_in_items_extracted, target_section)
items_remaining_budget = REMAINING_BUDGET

# Plan-mode collection (used when PLAN_OUTPUT is set)
plan_items = []

batch_paused = False

for idx, (section_code, item_text, _, _) in enumerate(items_extracted):
    cls = classify_one(item_text)
    if cls is None:
        # Classification failed; record as uncertain auto-defer (does not consume budget)
        if PLAN_OUTPUT:
            plan_items.append({
                "index": idx,
                "original_text": item_text,
                "original_section": section_code,
                "classification": {"label": "uncertain", "ranking": 1, "rationale": "classifier dispatch failed; auto-deferred"},
                "auto_accepted": True,
                "proposed_target": section_code,
            })
        audit_items.append({
            "original_text": item_text,
            "original_section": section_code,
            "classification": {"label": "uncertain", "ranking": 1, "rationale": "classifier dispatch failed; auto-deferred"},
            "user_decision": "defer",
            "post_migration_section": "SC" if section_code == "SC" else section_code,  # keep in original
        })
        print(f"ITEM: {TICKET_ID} {section_code} uncertain 1 defer {section_code}")
        continue

    label = cls["label"]
    ranking = cls["ranking"]
    rationale = cls["rationale"]
    cls["_original_section"] = section_code

    # Decision routing (per story ad70-f38a-7684-4e00 §6 automation amendment):
    # - end-state ranking >= 4   → auto-accept, stays in SC
    # - transitional ranking 5   → auto-apply, moves SC → CC (classifier is maximally confident)
    # - uncertain ranking 5      → auto-keep in SC (classifier confident it's uncertain; can't move)
    # - everything else (ranking 1-4 non-end-state) → user ack required
    if label == "end-state" and ranking >= 4:
        decision = "auto"
        target = section_code
        proposed_target = section_code
        auto_apply = True
    elif ranking == 5 and label == "transitional":
        decision = "auto"
        target = "CC"
        proposed_target = "CC"
        auto_apply = True
    elif ranking == 5 and label == "uncertain":
        # r=5 uncertain is rare (the classifier is confident in indecision);
        # keep in SC, record as auto-deferred. No section change.
        decision = "auto"
        target = section_code
        proposed_target = section_code
        auto_apply = True
    else:
        auto_apply = False

    if auto_apply:
        if PLAN_OUTPUT:
            plan_items.append({
                "index": idx,
                "original_text": item_text,
                "original_section": section_code,
                "classification": {"label": label, "ranking": ranking, "rationale": rationale},
                "auto_accepted": True,
                "proposed_target": proposed_target,
            })
    else:
        # Per-item escalation required
        if items_remaining_budget <= 0:
            # Batch cap reached; pause without consuming an ack
            batch_paused = True
            # Items not yet processed are NOT included in the audit
            break

        # Proposed target
        if label == "transitional":
            proposed_target = "CC"
        else:
            proposed_target = section_code  # uncertain / low-confidence end-state stays in original

        if PLAN_OUTPUT:
            # Plan-mode: record what would be asked; consume budget; do not prompt
            plan_items.append({
                "index": idx,
                "original_text": item_text,
                "original_section": section_code,
                "classification": {"label": label, "ranking": ranking, "rationale": rationale},
                "auto_accepted": False,
                "proposed_target": proposed_target,
            })
            items_remaining_budget -= 1
            # Skip the rest of the per-item loop body (no prompt, no audit, no moves)
            continue

        decision = prompt_user(item_text, cls, proposed_target)
        items_remaining_budget -= 1

        # Resolve final section based on decision
        if decision == "accept":
            target = proposed_target
        elif decision == "reject":
            target = section_code
        else:  # defer
            target = section_code

    audit_items.append({
        "original_text": item_text,
        "original_section": section_code,
        "classification": {"label": label, "ranking": ranking, "rationale": rationale},
        "user_decision": decision,
        "post_migration_section": "CC" if target == "CC" else "SC",
    })
    print(f"ITEM: {TICKET_ID} {section_code} {label} {ranking} {decision} {audit_items[-1]['post_migration_section']}")

    if target == "CC" and not DRYRUN:
        moves.append((idx, "CC", item_text))

# Plan-output mode: write the proposed plan and exit early (no audit, no moves)
if PLAN_OUTPUT:
    plan = {
        "schema_version": 1,
        "ticket_id": TICKET_ID,
        "snapshot_timestamp": SNAPSHOT_TIMESTAMP,
        "migration_run_id": MIGRATION_RUN_ID,
        "items": plan_items,
    }
    with open(PLAN_OUTPUT, "w", encoding="utf-8") as f:
        json.dump(plan, f, indent=2)
    budget_consumed = REMAINING_BUDGET - items_remaining_budget
    print(f"PLAN_WRITTEN: {PLAN_OUTPUT} items={len(plan_items)} needs_ack={sum(1 for it in plan_items if not it.get('auto_accepted'))}")
    print(f"BUDGET_CONSUMED: {budget_consumed}")
    if batch_paused:
        print(f"BATCH_PAUSE: {budget_consumed}")
        sys.exit(2)
    sys.exit(0)

# Write audit comment file
audit = {
    "schema_version": 1,
    "migration_run_id": MIGRATION_RUN_ID,
    "snapshot_timestamp": SNAPSHOT_TIMESTAMP,
    "ticket_id": TICKET_ID,
    "items": audit_items,
}
with open(AUDIT_JSON_FILE, "w", encoding="utf-8") as f:
    json.dump(audit, f, indent=2)

# Build new description if there are moves to apply (and not dry-run)
if moves and not DRYRUN:
    # Replace move text occurrences in description; append a Closure Checks section if needed
    new_desc = description
    cc_items_to_add = []
    for idx, target_section, original_text in moves:
        # Identify the bullet line(s) for this item and remove from SC
        # Reconstruct the bullet text exactly as it appeared: "- " + original_text (multi-line indented)
        # Use a simple pattern: find "- " + first 60 chars of item, remove that bullet block
        bullet_marker = original_text.split("\n")[0][:80]
        # Build regex pattern (escape special chars)
        pattern = re.compile(r"(\n[ \t]*[-*]\s+" + re.escape(bullet_marker) + r"[^\n]*(?:\n[ \t]+\S[^\n]*)*)", re.MULTILINE)
        m = pattern.search(new_desc)
        if m:
            new_desc = new_desc[:m.start()] + new_desc[m.end():]
            cc_items_to_add.append(original_text)

    if cc_items_to_add:
        # Append or insert Closure Checks section
        cc_heading = "## Closure Checks"
        if cc_heading in new_desc:
            # Insert items at end of existing section
            m = re.search(re.escape(cc_heading) + r"\s*\n(.*?)(?=\n## |\Z)", new_desc, re.DOTALL)
            if m:
                section_end = m.end()
                additions = "\n" + "\n".join(f"- {it}" for it in cc_items_to_add)
                new_desc = new_desc[:section_end] + additions + new_desc[section_end:]
        else:
            # Append the section at end
            additions = "\n\n## Closure Checks\n\n" + "\n".join(f"- {it}" for it in cc_items_to_add) + "\n"
            new_desc = new_desc + additions

    with open(NEW_DESC_FILE, "w", encoding="utf-8") as f:
        f.write(new_desc)

budget_consumed = REMAINING_BUDGET - items_remaining_budget
print(f"BUDGET_CONSUMED: {budget_consumed}")

if batch_paused:
    print(f"BATCH_PAUSE: {budget_consumed}")
    sys.exit(2)

sys.exit(0)
PYEOF
PYRC=$?

if [[ $PYRC -ne 0 && $PYRC -ne 2 ]]; then
    echo "ERROR: $TICKET_ID — python classifier helper failed (exit $PYRC)" >&2
    exit 1
fi

# ── Write audit comment (DD7) ───────────────────────────────────────────────
if [[ "$DRYRUN" = "0" && -s "$AUDIT_JSON_FILE" ]]; then
    AUDIT_BODY="$(cat "$AUDIT_JSON_FILE")"
    "$TICKET_CLI" ticket comment "$TICKET_ID" "CLOSURE_CHECKS_CLASSIFIER_AUDIT: $AUDIT_BODY" 2>&1 | tail -1
    echo "AUDIT_WRITTEN: $TICKET_ID"
fi

# ── Apply description mutation if produced ──────────────────────────────────
if [[ "$DRYRUN" = "0" && -s "$NEW_DESC_FILE" ]]; then
    NEW_DESC="$(cat "$NEW_DESC_FILE")"
    "$TICKET_CLI" ticket edit "$TICKET_ID" --description="$NEW_DESC" 2>&1 | tail -1
    echo "DESCRIPTION_UPDATED: $TICKET_ID"
fi

# Exit code from python: 0 = done; 2 = batch_pause (already exited via stdout marker)
exit $PYRC
