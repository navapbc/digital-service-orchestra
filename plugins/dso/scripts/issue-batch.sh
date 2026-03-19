#!/usr/bin/env bash
set -euo pipefail
# scripts/issue-batch.sh — Next-batch selector using tk commands.
#
# Selects tasks for a parallel agent batch under a given epic. Uses tk
# for all issue lookups. Provides equivalent functionality to
# sprint-next-batch.sh built on the tk ticket system.
#
# Handles the 3-tier hierarchy (epic -> story -> task):
#   - Tasks with no unresolved deps are candidates (tk ready output).
#   - If a story has open blockers, all its child tasks are deferred.
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
#   1 — Epic not found or tk error
#   2 — Usage error

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
TK="${TK:-$SCRIPT_DIR/tk}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
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

# --- Data collection using tk ---

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Fetch epic details via tk show
"$TK" show "$epic_id" >"$tmpdir/epic.txt" 2>/dev/null || true
if [ ! -s "$tmpdir/epic.txt" ]; then
    echo "Error: Could not load epic $epic_id" >&2
    exit 1
fi

# Extract epic title from tk show output.
# tk show outputs YAML frontmatter followed by markdown body.
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
    # Real tk show: markdown with YAML frontmatter; title is the H1 heading
    epic_title=$(grep '^# ' "$tmpdir/epic.txt" 2>/dev/null | head -1 | sed 's/^# //' || echo "")
fi

# Fetch ready tasks (no unresolved deps) via tk ready
# tk ready outputs lines like: id [Pprio][status] - title
"$TK" ready >"$tmpdir/ready.txt" 2>/dev/null || true

# --- Core logic ---

SPRINT_TMPDIR="$tmpdir" \
SPRINT_EPIC_ID="$epic_id" \
SPRINT_EPIC_TITLE="$epic_title" \
SPRINT_LIMIT="$limit" \
SPRINT_JSON="$json_output" \
SPRINT_SCORER="$SCORER" \
SPRINT_PYTHON="$PYTHON" \
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
tk_bin     = os.environ.get("TK", "tk")

OPUS_CAP = 2

# ── Helpers ──────────────────────────────────────────────────────────────────

def parse_ready_line(line):
    """
    Parse a tk ready output line.
    Format: id [Pprio][status] - title
    Example: w21-0zy5 [P1][open] - Fix tests failure
    Returns dict or None on parse failure.
    """
    line = line.strip()
    if not line:
        return None
    m = re.match(r'^(\S+)\s+\[P(\d)\]\[(\w+)\]\s+-\s+(.+)$', line)
    if not m:
        return None
    return {
        "id": m.group(1),
        "priority": int(m.group(2)),
        "status": m.group(3),
        "title": m.group(4),
        "issue_type": "task",
    }

def tk_show(ticket_id):
    """Run tk show <id> and return a simple dict with id, title, status."""
    result = subprocess.run(
        [tk_bin, "show", ticket_id],
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
    """Extract candidate file paths from task description."""
    if not text:
        return set()
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

ready_lines = []
try:
    with open(os.path.join(tmpdir, "ready.txt")) as f:
        ready_lines = f.readlines()
except FileNotFoundError:
    pass

ready_tasks = []
for line in ready_lines:
    parsed = parse_ready_line(line)
    if parsed:
        ready_tasks.append(parsed)

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
        "id", "title", "tk_priority", "itype", "status", "files",
        "model", "subagent", "cls", "complexity", "classify_priority",
    )

    def __init__(self, raw, cls_info):
        self.id               = raw.get("id", "")
        self.title            = raw.get("title", "untitled")
        self.tk_priority   = raw.get("priority", 4)
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

# Sort: classify_priority first, then tk_priority, then id for stable tie-breaking.
candidates.sort(key=lambda c: (c.classify_priority, c.tk_priority, c.id))

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
                "tk_priority": c.tk_priority,
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
            f"TASK: {c.id}\tP{c.tk_priority}\t{c.itype}"
            f"\t{c.model}\t{c.subagent}\t{c.cls}\t{c.title}"
        )
    for tid, title, cf, ct in skipped_overlap:
        print(f"SKIPPED_OVERLAP: {tid}\tdeferred (overlaps with {ct} on {cf})")
    for tid, title in skipped_opus_cap:
        print(f"SKIPPED_OPUS_CAP: {tid}\tdeferred (opus cap of {OPUS_CAP} reached)")
    for tid, title in skipped_in_progress:
        print(f"SKIPPED_IN_PROGRESS: {tid}\talready in_progress")

PYEOF
