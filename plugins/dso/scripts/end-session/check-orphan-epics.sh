#!/usr/bin/env bash
# scripts/end-session/check-orphan-epics.sh
# Helper for /dso:end-session Step 3 (Close Orphaned Epics). Enumerates in-progress epics, classifies
# child_status (no_children | open_children | all_closed), and decides
# session-relatedness via commit-keyword match against the worktree branch.
#
# OUTPUT CONTRACT (stdout, JSON array):
# [
#   {
#     "epic_id": "abc1-def2",
#     "title": "Foo bar",
#     "child_status": "no_children" | "open_children" | "all_closed",
#     "session_related": true | false,
#     "match_reason": "epic_id" | "child_id" | "title_keywords" | null
#   },
#   ...
# ]
#
# child_status semantics:
#   no_children   — epic has zero children (skip in skill).
#   open_children — at least one child is not closed (do NOT close epic).
#   all_closed    — epic has children, all closed (closeability candidate).
#
# session_related semantics:
#   true  — at least one commit on this branch (or recent main commits when
#           branch has no unmerged commits) references the epic by id, a child
#           id, or matches >=2 non-trivial keywords from the epic title.
#   false — no such commit. Skill reports informationally; does NOT auto-close.
#
# Decisions about closure (user confirmation, verifier-result shortcut) stay
# in the skill — this helper only emits enumeration + relatedness.
#
# Usage:
#   bash scripts/end-session/check-orphan-epics.sh [--base-ref <ref>]
# Env:
#   TICKET_CMD — override ticket binary (default: $_SCRIPT_DIR/../ticket)
# Exit codes:
#   0 — emitted JSON (possibly empty array)
#   2 — usage error
#
# Exits 0 with `[]` when there are no in-progress epics.

set -uo pipefail

BASE_REF="main"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-ref)
            BASE_REF="$2"; shift 2 ;;
        --base-ref=*)
            BASE_REF="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,40p' "$0"; exit 0 ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 2 ;;
    esac
done

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKET_CMD="${TICKET_CMD:-${_SCRIPT_DIR%/*}/ticket}"

if [[ ! -x "$TICKET_CMD" ]]; then
    echo "Error: ticket CLI not found or not executable at $TICKET_CMD" >&2
    exit 2
fi

# Collect commit messages from the worktree branch. Prefer unmerged commits;
# fall back to the last 30 commits from the base ref when nothing is unmerged.
_COMMITS=$(git log "${BASE_REF}..HEAD" --format='%H %s' 2>/dev/null || true)
if [[ -z "$_COMMITS" ]]; then
    _COMMITS=$(git log --format='%H %s' -30 "$BASE_REF" 2>/dev/null || true)
fi

# Pull in-progress epics (JSON array) and per-epic children (JSON arrays).
_EPICS_JSON=$("$TICKET_CMD" list --type=epic --status=in_progress 2>/dev/null || echo "[]")

# Hand the joined data to python for classification + matching. Python receives
# the epic list, the commits blob, and uses `ticket list --parent=<id>` per
# epic via a callback shell (passed as $TICKET_CMD in env).
export _EPICS_JSON _COMMITS
python3 - "$TICKET_CMD" <<'PYEOF'
import json, os, re, subprocess, sys

ticket_cmd = sys.argv[1]
epics_json = os.environ.get("_EPICS_JSON", "[]")
commits_raw = os.environ.get("_COMMITS", "")

try:
    epics = json.loads(epics_json)
except json.JSONDecodeError:
    epics = []

if not isinstance(epics, list):
    epics = []

# Stop-words excluded from title-keyword matching. Tuned for typical ticket
# titles: project verbs (add/fix/remove), pronouns, articles. Keywords must be
# >=4 chars and >=2 must match for a positive title-match signal.
STOP = {
    "the", "and", "for", "with", "that", "this", "from", "into", "when",
    "should", "would", "could", "have", "has", "are", "is", "be", "to",
    "of", "in", "on", "an", "a", "as", "at", "by", "or", "but", "not",
    "add", "fix", "use", "via", "all", "any", "new", "old", "via",
    "epic", "story", "task", "bug", "ticket", "tickets",
}

def title_keywords(title):
    if not title:
        return []
    words = re.findall(r"[A-Za-z][A-Za-z0-9_-]{3,}", title.lower())
    return [w for w in words if w not in STOP]

def list_children(epic_id):
    try:
        out = subprocess.run(
            [ticket_cmd, "list", f"--parent={epic_id}"],
            capture_output=True, text=True, check=False, timeout=15,
        )
        if out.returncode != 0:
            return []
        if not out.stdout.strip():
            return []
        parsed = json.loads(out.stdout)
        # Guard against the CLI returning a non-list payload (error object,
        # null, scalar). Without this, dict iteration downstream produces a
        # false-positive all_closed classification.
        if not isinstance(parsed, list):
            return []
        return parsed
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return []

results = []
for epic in epics:
    if not isinstance(epic, dict):
        continue
    epic_id = epic.get("ticket_id") or epic.get("id")
    title = epic.get("title") or epic.get("ttl") or ""
    if not epic_id:
        continue

    children = list_children(epic_id)
    if not children:
        child_status = "no_children"
    else:
        open_children = [
            c for c in children
            if isinstance(c, dict) and c.get("status") != "closed"
        ]
        child_status = "open_children" if open_children else "all_closed"

    # Session-relatedness only matters for closeable candidates; skip the
    # match work for no_children / open_children to keep output clean.
    match_reason = None
    session_related = False
    if child_status == "all_closed":
        child_ids = [
            c.get("ticket_id") or c.get("id")
            for c in children
            if isinstance(c, dict) and (c.get("ticket_id") or c.get("id"))
        ]
        kw = title_keywords(title)

        if epic_id and epic_id in commits_raw:
            session_related = True
            match_reason = "epic_id"
        else:
            for cid in child_ids:
                if cid and cid in commits_raw:
                    session_related = True
                    match_reason = "child_id"
                    break
            if not session_related and len(kw) >= 2:
                lc = commits_raw.lower()
                hits = sum(1 for w in kw if w in lc)
                if hits >= 2:
                    session_related = True
                    match_reason = "title_keywords"

    results.append({
        "epic_id": epic_id,
        "title": title,
        "child_status": child_status,
        "session_related": session_related,
        "match_reason": match_reason,
    })

print(json.dumps(results, indent=2))
PYEOF
