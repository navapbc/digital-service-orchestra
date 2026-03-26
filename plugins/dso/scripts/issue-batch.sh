#!/usr/bin/env bash
set -euo pipefail
# scripts/issue-batch.sh — Next-batch selector using ticket commands.
#
# Selects tasks for a parallel agent batch under a given epic. Uses the
# v3 ticket CLI for all issue lookups. Provides equivalent functionality to
# sprint-next-batch.sh built on the v3 event-sourced ticket system.
#
# Handles the 3-tier hierarchy (epic -> story -> task):
#   - Non-closed task tickets are candidates (ticket list filtered by type+status).
#   - Tasks with file-level overlap are serialized.
#   - Opus cap: at most 2 opus-classified tasks per batch.
#   - Classification is included so the orchestrator can launch sub-agents.
#
# Usage:
#   issue-batch.sh <epic-id>              # All non-conflicting ready tasks
#   issue-batch.sh <epic-id> --limit=N    # Up to N tasks
#   issue-batch.sh <epic-id> --json       # Machine-readable JSON output
#
# Text output lines:
#   EPIC: <id>  <title>
#   AVAILABLE_POOL: <n>
#   BATCH_SIZE: <n>
#   TASK: <id>  P<priority>  <type>  <model>  <subagent>  <class>  <title>
#   SKIPPED_OVERLAP: <id>  deferred (overlaps with <other-id> on <file>)
#   SKIPPED_OPUS_CAP: <id>  deferred (opus cap reached)
#   SKIPPED_IN_PROGRESS: <id>  already in_progress
#
# Exit codes:
#   0 — Batch generated (BATCH_SIZE may be 0 if no ready tasks)
#   1 — Epic not found or ticket error
#   2 — Usage error

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository" >&2
    exit 2
fi

# Source config-paths.sh for CFG_APP_DIR
_batch_config_paths="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
[[ -f "$_batch_config_paths" ]] && source "$_batch_config_paths"

# Resolve Python — prefer poetry env (classify-task.py needs its dependencies)
# Fall back to system python3 when poetry is absent (graceful degradation).
if command -v poetry >/dev/null 2>&1 && [ -f "$REPO_ROOT/${CFG_APP_DIR:-app}/poetry.lock" ]; then
    PYTHON="$(cd "$REPO_ROOT/${CFG_APP_DIR:-app}" && poetry env info -e 2>/dev/null || echo "python3")"
else
    PYTHON="python3"
fi
SCORER="${CLAUDE_PLUGIN_ROOT}/scripts/classify-task.py"

# --- Argument parsing ---

epic_id=""
limit=0          # 0 = unlimited
json_output=false

for arg in "$@"; do
    case "$arg" in
        --limit=*)
            limit="${arg#--limit=}"
            if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
                echo "Error: --limit must be a non-negative integer" >&2
                exit 2
            fi
            ;;
        --json)
            json_output=true
            ;;
        --help|-h)
            sed -n '2,45p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Unknown flag: $arg" >&2
            echo "Usage: issue-batch.sh <epic-id> [--limit=N] [--json]" >&2
            exit 2
            ;;
        *)
            if [ -z "$epic_id" ]; then
                epic_id="$arg"
            else
                echo "Error: Multiple epic IDs provided. Expected exactly one." >&2
                exit 2
            fi
            ;;
    esac
done

if [ -z "$epic_id" ]; then
    echo "Usage: issue-batch.sh <epic-id> [--limit=N] [--json]" >&2
    exit 2
fi

# --- Data collection using ticket CLI ---

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Fetch epic details via ticket show
"$TICKET_CMD" show "$epic_id" >"$tmpdir/epic.txt" 2>/dev/null || true
if [ ! -s "$tmpdir/epic.txt" ]; then
    echo "Error: Could not load epic $epic_id" >&2
    exit 1
fi

# Extract epic title from ticket show output.
# ticket show outputs YAML frontmatter followed by markdown body.
# The title is the first H1 heading (# Title) in the body, or the frontmatter title field.
# If the mock returns JSON, extract from JSON.
epic_title=""
if grep -q '"title"' "$tmpdir/epic.txt" 2>/dev/null; then
    # JSON output from mock
    epic_title=$(python3 -c "
import json, sys
data = json.load(open('$tmpdir/epic.txt'))
print(data.get('title', ''))
" 2>/dev/null || echo "")
else
    # Real ticket show: markdown with YAML frontmatter; title is the H1 heading
    epic_title=$(grep '^# ' "$tmpdir/epic.txt" 2>/dev/null | head -1 | sed 's/^# //' || echo "")
fi

# Fetch all tasks via ticket list (JSON array output)
"$TICKET_CMD" list >"$tmpdir/ready.txt" 2>/dev/null || true

# Fetch task IDs belonging to this epic (2-level: epic→story→task)
SPRINT_CHILD_IDS=$(python3 - "$epic_id" "$TICKET_CMD" <<'PYEOF' 2>/dev/null
import json, subprocess, sys

epic_id = sys.argv[1]
ticket_cmd = sys.argv[2]

def get_children(ticket_id):
    try:
        result = subprocess.run([ticket_cmd, "deps", ticket_id],
                                capture_output=True, text=True, timeout=10)
        d = json.loads(result.stdout)
        return d.get("children", [])
    except Exception:
        return []

# Level 1: epic -> stories
stories = get_children(epic_id)
all_task_ids = []
# Level 2: stories -> tasks
for story_id in stories:
    tasks = get_children(story_id)
    all_task_ids.extend(tasks)
if not all_task_ids:
    # Flat epic: direct children are tasks (no story layer)
    all_task_ids = list(stories)

print(",".join(all_task_ids))
PYEOF
)

# --- Core logic ---

SPRINT_TMPDIR="$tmpdir" \
SPRINT_EPIC_ID="$epic_id" \
SPRINT_EPIC_TITLE="$epic_title" \
SPRINT_LIMIT="$limit" \
SPRINT_JSON="$json_output" \
SPRINT_SCORER="$SCORER" \
SPRINT_PYTHON="$PYTHON" \
SPRINT_CHILD_IDS="$SPRINT_CHILD_IDS" \
python3 - <<'PYEOF'
import json
import os
import re
import subprocess
import sys

tmpdir     = os.environ["SPRINT_TMPDIR"]
epic_id    = os.environ["SPRINT_EPIC_ID"]
epic_title = os.environ.get("SPRINT_EPIC_TITLE", "")
limit      = int(os.environ.get("SPRINT_LIMIT", "0"))
json_mode  = os.environ.get("SPRINT_JSON", "false").lower() == "true"
scorer     = os.environ.get("SPRINT_SCORER", "")
python     = os.environ.get("SPRINT_PYTHON", "python3")
ticket_bin = os.environ.get("TICKET_CMD", "ticket")
child_ids_raw = os.environ.get("SPRINT_CHILD_IDS", "")
epic_child_ids = set(cid.strip() for cid in child_ids_raw.split(",") if cid.strip())

OPUS_CAP = 2

# ── Helpers ──────────────────────────────────────────────────────────────────

def parse_ready_tickets(json_text, child_ids=None):
    """
    Parse ticket list JSON output.
    Format: JSON array of ticket objects with ticket_id, ticket_type, title, status, priority.
    Returns only non-closed task tickets (restores ready-candidate semantics: tasks that can be acted on).
    Closed tickets and non-task ticket types (epics, stories) are filtered out.
    When child_ids is a non-empty set, only tickets whose ID is in child_ids are returned
    (scopes the result to the given epic's children). If child_ids is empty (deps call failed),
    returns an empty list — no graceful fallback to all tasks to avoid unscoped results.
    """
    # Statuses that represent actionable work items
    ACTIVE_STATUSES = {"open", "in_progress", "pending"}
    try:
        items = json.loads(json_text)
        if not isinstance(items, list):
            return []
        result = []
        for item in items:
            tid = item.get("ticket_id") or item.get("id", "")
            if not tid:
                continue
            ticket_type = item.get("ticket_type", "task")
            status = item.get("status", "open")
            # Only include task-type tickets in an active (non-closed) state.
            # This restores the semantics of the former ready-candidate filter which
            # returned only dependency-unblocked tasks. Since `ticket list` returns
            # all tickets of all types and statuses, we filter here to prevent
            # closed, epic, and story tickets from entering the candidate pool.
            if ticket_type != "task":
                continue
            if status not in ACTIVE_STATUSES:
                continue
            # Scope to the epic's children. When child_ids is empty (deps call failed),
            # return nothing — an empty scope must not fall back to all tasks.
            if not child_ids or tid not in child_ids:
                continue
            result.append({
                "id": tid,
                "priority": int(item.get("priority", 4)),
                "status": status,
                "title": item.get("title", "untitled"),
                "issue_type": ticket_type,
            })
        return result
    except Exception:
        return []

def ticket_show(ticket_id):
    """Run ticket show <id> and return a simple dict with id, title, status."""
    result = subprocess.run(
        [ticket_bin, "show", ticket_id],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return {}
    output = result.stdout.strip()
    # Handle JSON output (mock)
    if output.startswith('{'):
        try:
            return json.loads(output)
        except json.JSONDecodeError:
            pass
    # Parse YAML frontmatter + markdown body
    data = {"id": ticket_id, "status": "open"}
    in_frontmatter = False
    frontmatter_done = False
    lines = output.splitlines()
    for i, line in enumerate(lines):
        if i == 0 and line == "---":
            in_frontmatter = True
            continue
        if in_frontmatter and line == "---":
            in_frontmatter = False
            frontmatter_done = True
            continue
        if in_frontmatter:
            if ": " in line:
                k, v = line.split(": ", 1)
                data[k.strip()] = v.strip()
        elif frontmatter_done and line.startswith("# "):
            data["title"] = line[2:].strip()
    return data

def extract_files(text):
    """Extract candidate file paths from task description.

    Lines beginning with acceptance-criteria markers (e.g. "AC Verify:") are
    shell commands used to validate the work, not files that will be modified.
    They are stripped before extraction to prevent false-positive batch
    conflicts when multiple tickets reference the same validation command
    (e.g. "AC Verify: bash scripts/validate.sh --ci").
    """
    if not text:
        return set()

    # Strip acceptance-criteria lines: they contain shell commands, not file paths
    AC_LINE_RE = re.compile(r'^\s*AC\s+\w[\w\s]*:', re.IGNORECASE)
    text = "\n".join(
        line for line in text.splitlines() if not AC_LINE_RE.match(line)
    )

    files = set()

    # Backtick-delimited paths
    for m in re.finditer(r"`([^`]+\.\w+)`", text):
        files.add(m.group(1).lstrip("./"))

    # Explicit directory-rooted paths
    for m in re.finditer(
        r"\b((?:src|tests?|app|\.claude|scripts)/[\w/\-\.]+\.(?:py|sh|md|json|yaml|toml))\b",
        text,
    ):
        files.add(m.group(1).lstrip("./"))

    # Python module notation
    for m in re.finditer(r"\b((?:src|app)(?:\.\w+)+)\b", text):
        files.add(m.group(1).replace(".", "/") + ".py")

    # Implied test files for src/ files
    implied = set()
    for f in files:
        if f.startswith("src/") and f.endswith(".py"):
            inner = f[len("src/"):]
            parts = inner.rsplit("/", 1)
            if len(parts) == 2:
                test_path = f"tests/unit/{parts[0]}/test_{parts[1]}"
            else:
                test_path = f"tests/unit/test_{parts[0]}"
            implied.add(test_path)
    files |= implied

    return files

def classify_tasks(task_list):
    """
    Run classify-task.py on task_list.
    Returns dict: task_id -> classification dict.
    Falls back to default classification on any error.
    """
    default_cls = lambda tid: {
        "id": tid, "priority": 3, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "fallback"
    }

    if not task_list or not scorer or not os.path.exists(scorer):
        return {t.get("id", ""): default_cls(t.get("id", "")) for t in task_list}

    try:
        result = subprocess.run(
            [python, scorer],
            input=json.dumps(task_list),
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0 or not result.stdout.strip():
            return {t.get("id", ""): default_cls(t.get("id", "")) for t in task_list}
        data = json.loads(result.stdout)
        if not isinstance(data, list):
            data = [data]
        return {item["id"]: item for item in data if "id" in item}
    except Exception:
        return {t.get("id", ""): default_cls(t.get("id", "")) for t in task_list}

# ── Load pre-fetched data ─────────────────────────────────────────────────────

ready_tasks = []
try:
    with open(os.path.join(tmpdir, "ready.txt")) as f:
        ready_tasks = parse_ready_tickets(f.read(), child_ids=epic_child_ids)
except FileNotFoundError:
    pass

# ── Build candidate list ───────────────────────────────────────────────────────

skipped_in_progress = []   # (task_id, title)
candidates_raw      = []   # task dicts that are eligible

for raw in ready_tasks:
    tid    = raw.get("id", "")
    title  = raw.get("title", "untitled")
    status = raw.get("status", "open").lower()

    if status == "in_progress":
        skipped_in_progress.append((tid, title))
        continue

    candidates_raw.append(raw)

# ── Classify all candidates in one batch call ─────────────────────────────────

classifications = classify_tasks(candidates_raw)

# ── Build enriched candidate objects ─────────────────────────────────────────

class Candidate:
    __slots__ = (
        "id", "title", "priority", "itype", "status", "files",
        "model", "subagent", "cls", "complexity", "classify_priority",
    )

    def __init__(self, raw, cls_info):
        self.id               = raw.get("id", "")
        self.title            = raw.get("title", "untitled")
        self.priority      = raw.get("priority", 4)
        self.itype            = raw.get("issue_type", "task")
        self.status           = raw.get("status", "open").lower()
        text                  = raw.get("description", "") + " " + raw.get("notes", "")
        self.files            = extract_files(text)
        self.model            = cls_info.get("model", "sonnet")
        self.subagent         = cls_info.get("subagent", "general-purpose")
        self.cls              = cls_info.get("class", "independent")
        self.complexity       = cls_info.get("complexity", "low")
        self.classify_priority = cls_info.get("priority", 3)

candidates = [
    Candidate(raw, classifications.get(raw.get("id", ""), {}))
    for raw in candidates_raw
]

# Sort: classify_priority first, then priority, then id for stable tie-breaking.
candidates.sort(key=lambda c: (c.classify_priority, c.priority, c.id))

# ── Greedy selection with file-overlap and opus cap ───────────────────────────

claimed_files   = {}   # file -> task_id that claimed it
batch           = []   # Candidate objects in batch
opus_in_batch   = 0

skipped_overlap  = []  # (id, title, conflict_file, conflict_task_id)
skipped_opus_cap = []  # (id, title)

for c in candidates:
    # Hard stop if limit reached
    if limit > 0 and len(batch) >= limit:
        break

    # File conflict check
    conflict_file = None
    conflict_task = None
    for f in c.files:
        if f in claimed_files:
            conflict_file = f
            conflict_task = claimed_files[f]
            break

    if conflict_file:
        skipped_overlap.append((c.id, c.title, conflict_file, conflict_task))
        continue

    # Opus cap check
    if c.model == "opus" and opus_in_batch >= OPUS_CAP:
        skipped_opus_cap.append((c.id, c.title))
        continue

    # Add to batch
    batch.append(c)
    for f in c.files:
        claimed_files[f] = c.id
    if c.model == "opus":
        opus_in_batch += 1

# ── Output ────────────────────────────────────────────────────────────────────

if json_mode:
    print(json.dumps({
        "epic_id":        epic_id,
        "epic_title":     epic_title,
        "batch_size":     len(batch),
        "available_pool": len(candidates),
        "opus_cap":       OPUS_CAP,
        "batch": [
            {
                "id":             c.id,
                "title":          c.title,
                "priority":       c.priority,
                "type":           c.itype,
                "model":          c.model,
                "subagent":       c.subagent,
                "class":          c.cls,
                "complexity":     c.complexity,
                "files":          sorted(c.files),
            }
            for c in batch
        ],
        "skipped_overlap": [
            {"id": tid, "title": title, "conflict_file": cf, "conflict_with": ct}
            for tid, title, cf, ct in skipped_overlap
        ],
        "skipped_opus_cap": [
            {"id": tid, "title": title}
            for tid, title in skipped_opus_cap
        ],
        "skipped_in_progress": [
            {"id": tid, "title": title}
            for tid, title in skipped_in_progress
        ],
    }, indent=2))
else:
    print(f"EPIC: {epic_id}\t{epic_title}")
    print(f"AVAILABLE_POOL: {len(candidates)}")
    print(f"BATCH_SIZE: {len(batch)}")
    for c in batch:
        print(
            f"TASK: {c.id}\tP{c.priority}\t{c.itype}"
            f"\t{c.model}\t{c.subagent}\t{c.cls}\t{c.title}"
        )
    for tid, title, cf, ct in skipped_overlap:
        print(f"SKIPPED_OVERLAP: {tid}\tdeferred (overlaps with {ct} on {cf})")
    for tid, title in skipped_opus_cap:
        print(f"SKIPPED_OPUS_CAP: {tid}\tdeferred (opus cap of {OPUS_CAP} reached)")
    for tid, title in skipped_in_progress:
        print(f"SKIPPED_IN_PROGRESS: {tid}\talready in_progress")

PYEOF
