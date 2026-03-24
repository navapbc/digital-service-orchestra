#!/usr/bin/env bash
set -euo pipefail
# sprint-next-batch.sh — Deterministic next-batch selector for sprint orchestration.
#
# Selects tasks for a parallel agent batch under a given epic. Produces a
# fully-classified, conflict-free batch in one script call — the orchestrator
# receives everything it needs to launch sub-agents without further analysis.
#
# NOTE: Delegates to scripts/issue-batch.sh for ticket-based issue tracking.
#
# Handles the 3-tier hierarchy (epic -> story -> task):
#   - If a story has open blockers, all its child tasks are deferred regardless
#     of their own dependency state.
#   - Tasks with file-level overlap are serialized: only the higher-priority
#     task enters the batch; the lower-priority one defers to the next cycle.
#   - Opus cap: at most 2 opus-classified tasks per batch. Remaining opus tasks
#     are deferred (SKIPPED_OPUS_CAP); freed slots are filled with non-opus tasks.
#   - Classification (subagent, model, class, complexity) is included in output
#     so the orchestrator can launch sub-agents directly without extra calls.
#
# Usage:
#   sprint-next-batch.sh <epic-id>              # All non-conflicting ready tasks
#   sprint-next-batch.sh <epic-id> --limit=N    # Up to N tasks
#   sprint-next-batch.sh <epic-id> --json       # Machine-readable JSON output
#
# Text output lines:
#   EPIC: <id>  <title>
#   AVAILABLE_POOL: <n>  (candidates before overlap/opus-cap filtering)
#   BATCH_SIZE: <n>
#   TASK: <id>  P<priority>  <type>  <model>  <subagent>  <class>  <title>  [story:<id>]
#   SKIPPED_OVERLAP: <id>  deferred (overlaps with <other-id> on <file>)
#   SKIPPED_BLOCKED_STORY: <id>  deferred (parent story <story-id> is blocked)
#   SKIPPED_OPUS_CAP: <id>  deferred (opus cap reached; 2 opus tasks already in batch)
#   SKIPPED_IN_PROGRESS: <id>  already in_progress
#
# TASK field order (tab-separated after "TASK: "):
#   id  P<priority>  issue-type  model  subagent-type  class  title  [story:id]
#
# Exit codes:
#   0 — Batch generated (BATCH_SIZE may be 0 if no ready tasks)
#   1 — Epic not found or tk error
#   2 — Usage error

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository" >&2
    exit 2
fi

TK="${TK:-${CLAUDE_PLUGIN_ROOT}/scripts/tk}"

ISSUE_BATCH="${CLAUDE_PLUGIN_ROOT}/scripts/issue-batch.sh"
ANALYZE_IMPACT="${CLAUDE_PLUGIN_ROOT}/scripts/analyze-file-impact.py"
REDUCER="${CLAUDE_PLUGIN_ROOT}/scripts/ticket-reducer.py"

# ---------------------------------------------------------------------------
# Detect v3 event-sourced ticket system (mirrors sprint-list-epics.sh logic).
# v3 stores events in .tickets-tracker/ (or TICKETS_TRACKER_DIR env override).
# Detection:
#   - TICKETS_TRACKER_DIR explicitly set → v3 (test override for v3)
#   - TICKETS_DIR explicitly set without TICKETS_TRACKER_DIR → v2
#   - Neither set → auto-detect: use v3 if .tickets-tracker/ exists
# ---------------------------------------------------------------------------
_TICKETS_DIR_EXPLICIT="${TICKETS_DIR+yes}"
USE_V3=false
if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
    TRACKER_DIR="$TICKETS_TRACKER_DIR"
    USE_V3=true
elif [ "$_TICKETS_DIR_EXPLICIT" != "yes" ]; then
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
    if [ -d "$TRACKER_DIR" ]; then
        USE_V3=true
    fi
else
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
fi

# Resolve Python — prefer config-driven venv path; fallback to python3
READ_CONFIG="${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" # reads dso-config.conf
_config_python=""
if [ -x "$READ_CONFIG" ]; then
    _config_python=$("$READ_CONFIG" interpreter.python_venv "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null || true) # read-config.sh interpreter
    if [ -n "$_config_python" ] && [ -x "$REPO_ROOT/$_config_python" ]; then
        _config_python="$REPO_ROOT/$_config_python"
    else
        _config_python=""
    fi
fi
PYTHON="${_config_python:-python3}"
SCORER="${CLAUDE_PLUGIN_ROOT}/scripts/classify-task.py"

# Read config-driven path patterns for extract_files()
CFG_SRC_DIR=""
CFG_TEST_DIR=""
CFG_TEST_UNIT_DIR=""
if [ -x "$READ_CONFIG" ]; then
    CFG_SRC_DIR=$("$READ_CONFIG" paths.src_dir "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null || true)
    CFG_TEST_DIR=$("$READ_CONFIG" paths.test_dir "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null || true)
    CFG_TEST_UNIT_DIR=$("$READ_CONFIG" paths.test_unit_dir "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null || true)
fi
# Defaults for when config is unavailable
CFG_SRC_DIR="${CFG_SRC_DIR:-src}"
CFG_TEST_DIR="${CFG_TEST_DIR:-tests}"
CFG_TEST_UNIT_DIR="${CFG_TEST_UNIT_DIR:-tests/unit}"

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
            sed -n '2,50p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Unknown flag: $arg" >&2
            echo "Usage: sprint-next-batch.sh <epic-id> [--limit=N] [--json]" >&2
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
    echo "Usage: sprint-next-batch.sh <epic-id> [--limit=N] [--json]" >&2
    exit 2
fi

# --- Data collection using tk ---

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Epic details via tk show
"$TK" show "$epic_id" >"$tmpdir/epic.txt" 2>/dev/null || true
if [ ! -s "$tmpdir/epic.txt" ]; then
    echo "Error: Could not load epic $epic_id" >&2
    exit 1
fi

# Resolve the canonical full ID from the tk show response.
epic_id_canonical=$(python3 -c "
import json, sys, re

txt = open('$tmpdir/epic.txt').read().strip()

# If JSON output (mock), extract id field
if txt.startswith('{'):
    try:
        data = json.loads(txt)
        print(data.get('id', ''))
        sys.exit(0)
    except json.JSONDecodeError:
        pass

# YAML frontmatter: look for 'id: <value>'
m = re.search(r'^id:\s*(\S+)', txt, re.MULTILINE)
if m:
    print(m.group(1))
else:
    print('')
" 2>/dev/null)
if [ -n "$epic_id_canonical" ]; then
    epic_id="$epic_id_canonical"
fi

# Descendants of epic — scan ticket data for parent references.
# Handles 3-tier hierarchy: epic -> story -> task (grandchildren).
# v3: scan .tickets-tracker/ dirs via the reducer (reads parent_id from CREATE events)
# v2: scan .tickets/*.md frontmatter for parent: field (legacy)
TICKETS_DIR="${TICKETS_DIR:-$REPO_ROOT/.tickets}"
touch "$tmpdir/epic_children.txt"
touch "$tmpdir/parent_ids_with_children.txt"
if [ "$USE_V3" = true ] && [ -d "$TRACKER_DIR" ]; then
    SPRINT_TRACKER_DIR="$TRACKER_DIR" \
    SPRINT_EPIC_ID_BFS="$epic_id" \
    SPRINT_REDUCER="$REDUCER" \
    python3 - "$tmpdir/epic_children.txt" "$tmpdir/parent_ids_with_children.txt" <<'DESCEOF_V3'
import os, sys, json, importlib.util, pathlib

outfile = sys.argv[1]
parents_outfile = sys.argv[2]
tracker_dir = os.environ["SPRINT_TRACKER_DIR"]
root_id = os.environ["SPRINT_EPIC_ID_BFS"]
reducer_path = os.environ.get("SPRINT_REDUCER", "")

# Load reducer module
reduce_ticket = None
if reducer_path and os.path.exists(reducer_path):
    try:
        spec = importlib.util.spec_from_file_location("ticket_reducer", reducer_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        reduce_ticket = mod.reduce_ticket
    except Exception:
        pass

# Build parent_map by scanning each ticket dir via the reducer
parent_map = {}  # parent_id -> [child_id, ...]
try:
    for tid in os.listdir(tracker_dir):
        tdir = os.path.join(tracker_dir, tid)
        if not os.path.isdir(tdir) or tid.startswith("."):
            continue
        parent_id = None
        if reduce_ticket:
            try:
                state = reduce_ticket(tdir)
                if state and isinstance(state, dict):
                    parent_id = state.get("parent_id") or None
            except Exception:
                pass
        else:
            # Fallback: scan event files for CREATE event parent_id
            try:
                for fname in sorted(os.listdir(tdir)):
                    if not fname.endswith(".json") or fname == ".cache.json":
                        continue
                    try:
                        with open(os.path.join(tdir, fname), encoding="utf-8") as f:
                            ev = json.load(f)
                        if ev.get("event_type") == "CREATE":
                            parent_id = ev.get("data", {}).get("parent_id") or None
                            break
                    except Exception:
                        pass
            except Exception:
                pass
        if parent_id:
            parent_map.setdefault(parent_id, []).append(tid)
except Exception:
    pass

# BFS from root to find all descendants
descendants = set()
queue = [root_id]
while queue:
    pid = queue.pop(0)
    for child in parent_map.get(pid, []):
        if child not in descendants:
            descendants.add(child)
            queue.append(child)

# Identify descendants that have children (stories with impl tasks)
parents_with_children = {pid for pid in parent_map if pid in descendants and parent_map[pid]}
with open(outfile, "w") as f:
    for d in sorted(descendants):
        f.write(d + "\n")
with open(parents_outfile, "w") as f:
    for p in sorted(parents_with_children):
        f.write(p + "\n")
DESCEOF_V3
elif [ -d "$TICKETS_DIR" ]; then
    python3 - "$TICKETS_DIR" "$epic_id" "$tmpdir/epic_children.txt" "$tmpdir/parent_ids_with_children.txt" <<'DESCEOF'
import os, sys, re
tickets_dir, root_id, outfile, parents_outfile = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# Build parent -> children map by scanning ticket frontmatter
parent_map = {}  # parent_id -> [child_id, ...]
for fname in os.listdir(tickets_dir):
    if not fname.endswith(".md"):
        continue
    tid = fname[:-3]
    try:
        with open(os.path.join(tickets_dir, fname)) as f:
            for line in f:
                m = re.match(r'^parent:\s*(\S+)', line)
                if m:
                    parent_map.setdefault(m.group(1), []).append(tid)
                    break
    except Exception:
        pass
# BFS from root to find all descendants
descendants = set()
queue = [root_id]
while queue:
    pid = queue.pop(0)
    for child in parent_map.get(pid, []):
        if child not in descendants:
            descendants.add(child)
            queue.append(child)
# Identify descendants that have children (stories with impl tasks)
parents_with_children = {pid for pid in parent_map if pid in descendants and parent_map[pid]}
with open(outfile, "w") as f:
    for d in sorted(descendants):
        f.write(d + "\n")
with open(parents_outfile, "w") as f:
    for p in sorted(parents_with_children):
        f.write(p + "\n")
DESCEOF
fi

# Ready tasks (no unresolved deps) via tk ready
"$TK" ready >"$tmpdir/ready.txt" 2>/dev/null || true

# Blocked tasks (for story-level blocking check)
"$TK" blocked >"$tmpdir/blocked.txt" 2>/dev/null || true

# --- Core logic ---

SPRINT_TMPDIR="$tmpdir" \
SPRINT_EPIC_ID="$epic_id" \
SPRINT_LIMIT="$limit" \
SPRINT_JSON="$json_output" \
SPRINT_SCORER="$SCORER" \
SPRINT_PYTHON="$PYTHON" \
SPRINT_ANALYZE_IMPACT="$ANALYZE_IMPACT" \
SPRINT_REPO_ROOT="$REPO_ROOT" \
SPRINT_CFG_SRC_DIR="$CFG_SRC_DIR" \
SPRINT_CFG_TEST_DIR="$CFG_TEST_DIR" \
SPRINT_CFG_TEST_UNIT_DIR="$CFG_TEST_UNIT_DIR" \
SPRINT_USE_V3="$USE_V3" \
SPRINT_TRACKER_DIR="$TRACKER_DIR" \
SPRINT_REDUCER="$REDUCER" \
python3 - <<'PYEOF'
import json
import os
import re
import subprocess
import sys

tmpdir          = os.environ["SPRINT_TMPDIR"]
epic_id         = os.environ["SPRINT_EPIC_ID"]
limit           = int(os.environ.get("SPRINT_LIMIT", "0"))
json_mode       = os.environ.get("SPRINT_JSON", "false").lower() == "true"
scorer          = os.environ.get("SPRINT_SCORER", "")
python          = os.environ.get("SPRINT_PYTHON", "python3")
tk_bin          = os.environ.get("TK", "tk")
analyze_impact  = os.environ.get("SPRINT_ANALYZE_IMPACT", "")
repo_root       = os.environ.get("SPRINT_REPO_ROOT", "")
cfg_src_dir     = os.environ.get("SPRINT_CFG_SRC_DIR", "src")
cfg_test_dir    = os.environ.get("SPRINT_CFG_TEST_DIR", "tests")
cfg_test_unit_dir = os.environ.get("SPRINT_CFG_TEST_UNIT_DIR", "tests/unit")
use_v3          = os.environ.get("SPRINT_USE_V3", "false").lower() == "true"
tracker_dir     = os.environ.get("SPRINT_TRACKER_DIR", "")
reducer_path    = os.environ.get("SPRINT_REDUCER", "")

# Load v3 reducer module once if available
_reduce_ticket = None
if use_v3 and reducer_path and os.path.exists(reducer_path):
    try:
        import importlib.util as _ilu
        _spec = _ilu.spec_from_file_location("ticket_reducer", reducer_path)
        _mod = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_mod)
        _reduce_ticket = _mod.reduce_ticket
    except Exception:
        pass

OPUS_CAP = 2

# ── Helpers ──────────────────────────────────────────────────────────────────

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
        "dependencies": [],
    }

def extract_files(text):
    """
    Extract candidate file paths from a task description.
    Returns a set of normalised path strings.

    Lines beginning with acceptance-criteria markers (e.g. "AC Verify:") are
    shell commands used to validate the work, not files that will be modified.
    They are stripped before extraction to prevent false-positive batch
    conflicts when multiple tickets reference the same validation command
    (e.g. "AC Verify: bash scripts/validate.sh --ci").
    """
    if not text:
        return set()

    # Strip acceptance-criteria content: shell commands, not files to be modified.
    # Phase 1: remove entire ## ACCEPTANCE CRITERIA sections (through next ## or EOF)
    text = re.sub(
        r'(?m)^##\s+ACCEPTANCE\s+CRITERIA\b.*?(?=^##\s|\Z)',
        '', text, flags=re.IGNORECASE | re.DOTALL,
    )
    # Phase 2: strip individual AC-prefixed lines (AC Verify:, AC Check:, etc.)
    AC_LINE_RE = re.compile(
        r'^\s*(?:AC\s+\w[\w\s]*:|Acceptance\s+criteria\s*:)',
        re.IGNORECASE,
    )
    text = "\n".join(
        line for line in text.splitlines() if not AC_LINE_RE.match(line)
    )

    files = set()

    # Backtick-delimited paths (any extension)
    for m in re.finditer(r"`([^`]+\.\w+)`", text):
        files.add(m.group(1).lstrip("./"))

    # Build directory-rooted path regex from config values + fixed dirs
    dir_roots = {cfg_src_dir, cfg_test_dir, "app", ".claude"}
    # Also add bare test_dir variants (e.g. "test" if test_dir is "tests")
    if cfg_test_dir.endswith("s"):
        dir_roots.add(cfg_test_dir[:-1])
    dir_pattern = "|".join(re.escape(d) for d in sorted(dir_roots))

    # Explicit directory-rooted paths in prose (any common extension)
    for m in re.finditer(
        r"\b((?:" + dir_pattern + r")/[\w/\-\.]+\.(?:py|sh|md|json|yaml|toml))\b",
        text,
    ):
        files.add(m.group(1).lstrip("./"))

    # Python module notation
    for m in re.finditer(r"\b((?:" + re.escape(cfg_src_dir) + r"|app)(?:\.\w+)+)\b", text):
        files.add(m.group(1).replace(".", "/") + ".py")

    # Implied test files for src_dir files
    src_prefix = cfg_src_dir + "/"
    test_unit_prefix = cfg_test_unit_dir + "/"
    implied = set()
    for f in files:
        if f.startswith(src_prefix) and f.endswith(".py"):
            inner = f[len(src_prefix):]
            parts = inner.rsplit("/", 1)
            if len(parts) == 2:
                test_path = f"{test_unit_prefix}{parts[0]}/test_{parts[1]}"
            else:
                test_path = f"{test_unit_prefix}test_{parts[0]}"
            implied.add(test_path)
    files |= implied

    return files

def _load_ticket_body(ticket_id):
    """Return ticket text content for file path extraction.

    v3 (event-sourced): compile ticket state via the reducer; build text
    from title + comment bodies (the markdown body fields in CREATE events
    are not stored separately — file references appear in comments).

    v2 (legacy): read the full text from .tickets/<id>.md (frontmatter + body).

    Falls back to empty string on any error.
    """
    if use_v3 and tracker_dir:
        ticket_dir = os.path.join(tracker_dir, ticket_id)
        if os.path.isdir(ticket_dir):
            parts = []
            if _reduce_ticket:
                try:
                    state = _reduce_ticket(ticket_dir)
                    if state and isinstance(state, dict):
                        # Include title for file references mentioned there
                        if state.get("title"):
                            parts.append(state["title"])
                        # Include all comment bodies — file paths live here
                        for comment in state.get("comments") or []:
                            body = comment.get("body", "")
                            if body:
                                parts.append(body)
                except Exception:
                    pass
            else:
                # Fallback: scan event JSON files directly without the reducer
                try:
                    for fname in sorted(os.listdir(ticket_dir)):
                        if not fname.endswith(".json") or fname == ".cache.json":
                            continue
                        try:
                            with open(os.path.join(ticket_dir, fname), encoding="utf-8") as f:
                                ev = json.load(f)
                            etype = ev.get("event_type", "")
                            data = ev.get("data", {})
                            if etype == "CREATE" and data.get("title"):
                                parts.append(data["title"])
                            elif etype == "COMMENT" and data.get("body"):
                                parts.append(data["body"])
                        except Exception:
                            pass
                except Exception:
                    pass
            return "\n".join(parts)
        return ""

    # v2 path: read .tickets/<id>.md
    tickets_dir = os.path.join(repo_root, ".tickets")
    ticket_path = os.path.join(tickets_dir, f"{ticket_id}.md")
    try:
        with open(ticket_path, encoding="utf-8") as f:
            return f.read()
    except (OSError, FileNotFoundError):
        return ""

def analyze_file_impact(seed_files):
    """
    Run analyze-file-impact.py on seed file paths.
    Returns (files_likely_modified, files_likely_read) or (None, None) on failure.
    Falls back gracefully if the script is missing, times out, or fails.
    """
    if not analyze_impact or not os.path.exists(analyze_impact):
        return None, None
    if not seed_files:
        return None, None

    try:
        cmd = [python, analyze_impact, "--root", os.path.join(repo_root, "app")]
        cmd.extend(seed_files)
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return None, None
        data = json.loads(result.stdout)
        files_likely_modified = set(data.get("files_likely_modified", []))
        files_likely_read = set(data.get("files_likely_read", []))
        return files_likely_modified, files_likely_read
    except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception):
        return None, None

def classify_tasks(task_list):
    """
    Run classify-task.py on task_list (list of raw task dicts).
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

# ── Load epic details ─────────────────────────────────────────────────────────

epic_txt = ""
try:
    with open(os.path.join(tmpdir, "epic.txt")) as f:
        epic_txt = f.read().strip()
except FileNotFoundError:
    pass

if not epic_txt:
    print("Error: Epic data is empty", file=sys.stderr)
    sys.exit(1)

# Extract epic title
epic_title = ""
if epic_txt.startswith('{'):
    try:
        epic_data = json.loads(epic_txt)
        epic_title = epic_data.get("title", "")
    except json.JSONDecodeError:
        pass
else:
    for line in epic_txt.splitlines():
        if line.startswith("# "):
            epic_title = line[2:].strip()
            break

# ── Load epic children IDs (scope ready tasks to this epic) ──────────────────

epic_children_ids = set()
try:
    with open(os.path.join(tmpdir, "epic_children.txt")) as f:
        for line in f:
            tid = line.strip()
            if tid:
                epic_children_ids.add(tid)
except FileNotFoundError:
    pass

# ── Load blocked task IDs (for story-level blocking) ─────────────────────────

blocked_ids = set()
try:
    with open(os.path.join(tmpdir, "blocked.txt")) as f:
        for line in f:
            # Match ticket ID formats: dso-xxxx, w21-xxxx, JIRA-123, etc.
            # Suffix is either short (2-4 chars, covers hash-style IDs like dso-ptzz)
            # or contains a digit (covers JIRA-123, w21-v0ad). This excludes most
            # hyphenated English words (in-progress, pre-commit, non-blocking).
            for m in re.finditer(r'\b([a-zA-Z][a-zA-Z0-9]+-(?:[a-z0-9]{2,4}|[a-z0-9]*\d[a-z0-9]*))\b', line):
                blocked_ids.add(m.group(1))
except FileNotFoundError:
    pass

# ── Load ready tasks ──────────────────────────────────────────────────────────

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
        # Only include tasks that are descendants of the epic
        if epic_children_ids and parsed["id"] not in epic_children_ids:
            continue
        ready_tasks.append(parsed)

# ── Identify stories and check which are blocked ──────────────────────────────

STORY_TYPES = {"story"}
CLOSED = {"closed", "done", "completed"}

status_cache  = {}   # issue_id -> status string
story_map     = {}   # story_id -> raw issue dict
story_blocked = {}   # story_id -> bool

# Load children of epic from dep tree output for story detection
children_txt = ""
try:
    with open(os.path.join(tmpdir, "epic_children.txt")) as f:
        children_txt = f.read().strip()
except FileNotFoundError:
    pass

# Parse dep tree output — each line is a ticket id (possibly indented for depth)
story_children_cache = {}  # story_id -> set of task IDs

def get_blocker_ids(issue):
    """Return IDs of issues that directly block this issue."""
    return [
        d["depends_on_id"]
        for d in (issue.get("dependencies") or [])
        if d.get("type") == "blocks" and d.get("depends_on_id")
    ]

def is_story_blocked(story):
    for blocker_id in get_blocker_ids(story):
        if blocker_id not in status_cache:
            data = tk_show(blocker_id)
            status_cache[blocker_id] = data.get("status", "open").lower()
        if status_cache[blocker_id] not in CLOSED:
            return True
    return False

def find_parent_story(task_id):
    """Find the parent of a task via tk show. Returns parent ID or None."""
    data = tk_show(task_id)
    parent_id = data.get("parent", "")
    if parent_id:
        return parent_id
    return None

def is_parent_story_blocked(task_id):
    """Check if a task's parent story is in the blocked set."""
    parent_id = find_parent_story(task_id)
    if parent_id and parent_id in blocked_ids:
        return parent_id
    return None

# ── Build candidate list ───────────────────────────────────────────────────────

skipped_blocked_story = []   # (task_id, title, story_id)
skipped_in_progress   = []   # (task_id, title)
candidates_raw        = []   # raw task dicts that are eligible

# Load parent IDs with children (pre-computed by BFS in bash section above)
parent_ids_with_children = set()
try:
    with open(os.path.join(tmpdir, "parent_ids_with_children.txt")) as f:
        for line in f:
            tid = line.strip()
            if tid:
                parent_ids_with_children.add(tid)
except FileNotFoundError:
    pass

for raw in ready_tasks:
    tid    = raw.get("id", "")
    title  = raw.get("title", "untitled")
    status = raw.get("status", "open").lower()

    if status == "in_progress":
        skipped_in_progress.append((tid, title))
        continue

    # Skip stories/features that have implementation task children
    if tid in parent_ids_with_children:
        continue

    # Story-level blocking: skip if parent story is blocked
    blocked_parent = is_parent_story_blocked(tid)
    if blocked_parent:
        skipped_blocked_story.append((tid, title, blocked_parent))
        continue

    candidates_raw.append(raw)

# ── Classify all candidates in one batch call ─────────────────────────────────

classifications = classify_tasks(candidates_raw)

# ── Build enriched candidate objects ─────────────────────────────────────────

class Candidate:
    __slots__ = (
        "id", "title", "tk_priority", "itype", "status", "files",
        "files_read",
        "model", "subagent", "cls", "complexity",
        "classify_priority",
    )

    def __init__(self, raw, cls_info):
        self.id               = raw.get("id", "")
        self.title            = raw.get("title", "untitled")
        self.tk_priority   = raw.get("priority", 4)
        self.itype            = raw.get("issue_type", "task")
        self.status           = raw.get("status", "open").lower()
        # Fetch full ticket content for seed file extraction
        full_ticket           = _load_ticket_body(self.id)
        text                  = (raw.get("description") or "") + " " + (raw.get("notes") or "") + " " + full_ticket
        seed_files            = extract_files(text)
        # Try static analysis via analyze-file-impact.py
        files_likely_modified, files_likely_read = analyze_file_impact(list(seed_files))
        if files_likely_modified is not None:
            self.files        = files_likely_modified
            self.files_read   = files_likely_read or set()
        else:
            # Fallback: use extract_files() output
            self.files        = seed_files
            self.files_read   = set()
        self.model            = cls_info.get("model", "sonnet")
        self.subagent         = cls_info.get("subagent", "general-purpose")
        self.cls              = cls_info.get("class", "independent")
        self.complexity       = cls_info.get("complexity", "low")
        self.classify_priority = cls_info.get("priority", 3)

candidates = [
    Candidate(raw, classifications.get(raw.get("id", ""), {}))
    for raw in candidates_raw
]

# Sort: classify_priority first (1=interface-contract → highest urgency),
# then tk_priority (0=critical), then id for stable tie-breaking.
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

# ── Conflict matrix (stderr) ──────────────────────────────────────────────────

def print_conflict_matrix(candidates):
    """Print a human-readable NxN conflict matrix to stderr.

    Rows and columns are candidate task IDs. Cells show 'X' for conflict
    (shared files in files_likely_modified) or '.' for no conflict.
    Below the matrix, conflicting file paths are listed per pair.
    Skipped entirely when fewer than 2 candidates.
    """
    if len(candidates) < 2:
        return

    ids = [c.id for c in candidates]
    file_sets = {c.id: c.files for c in candidates}

    # Compute pairwise overlaps — keys use lexicographic (min, max) order
    # so that lookup in the matrix row loop matches storage order.
    overlaps = {}  # (id_a, id_b) -> set of shared files
    for i, a in enumerate(ids):
        for j, b in enumerate(ids):
            if i < j:
                shared = file_sets[a] & file_sets[b]
                if shared:
                    overlaps[(min(a, b), max(a, b))] = shared

    # Determine column width (max id length + padding)
    col_w = max(len(tid) for tid in ids) + 1

    # Header row
    header = " " * col_w + "".join(tid.ljust(col_w) for tid in ids)
    print(file=sys.stderr)
    print("Conflict Matrix:", file=sys.stderr)
    print(header, file=sys.stderr)

    # Matrix rows
    for a in ids:
        row = a.ljust(col_w)
        for b in ids:
            if a == b:
                cell = "."
            else:
                key = (min(a, b), max(a, b))
                cell = "X" if key in overlaps else "."
            row += cell.ljust(col_w)
        print(row, file=sys.stderr)

    # Detail: list conflicting files per pair
    if overlaps:
        print(file=sys.stderr)
        for (a, b), shared in sorted(overlaps.items()):
            print(f"  {a} <-> {b}: {', '.join(sorted(shared))}", file=sys.stderr)
    print(file=sys.stderr)

print_conflict_matrix(candidates)

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
                "files_likely_read": sorted(c.files_read),
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
        "skipped_blocked_story": [
            {"id": tid, "title": title, "blocked_story": sid}
            for tid, title, sid in skipped_blocked_story
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
    for tid, title, sid in skipped_blocked_story:
        print(f"SKIPPED_BLOCKED_STORY: {tid}\tdeferred (parent story {sid} is blocked)")
    for tid, title in skipped_in_progress:
        print(f"SKIPPED_IN_PROGRESS: {tid}\talready in_progress")

PYEOF
