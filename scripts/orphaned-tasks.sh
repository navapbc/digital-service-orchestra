#!/usr/bin/env bash
# Lists open tasks/features that are not children of any epic.
# Bugs are excluded (they are standalone by nature during normal development).
# Reads ticket files from TICKETS_DIR (default: <repo_root>/.tickets).
# Usage: ./scripts/orphaned-tasks.sh [--json]
set -euo pipefail

# Source shared tk availability helper for consistency with other ticket scripts.
# Note: this script reads .tickets/ directly via Python and does not call tk,
# but sourcing require-tk.sh ensures the tk dependency is validated consistently.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/require-tk.sh"
# Do not call require_tk here — this script works without tk (reads files directly).
# The source is for consistency and so adopters see require-tk.sh is available.

JSON_FLAG=""
if [[ "${1:-}" == "--json" ]]; then
  JSON_FLAG="true"
fi

# Resolve tickets directory: env var override or repo-root default
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
TICKETS_DIR="${TICKETS_DIR:-${REPO_ROOT}/.tickets}"

python3 - "$TICKETS_DIR" ${JSON_FLAG:+--json} << 'PYEOF'
import json
import os
import sys

tickets_dir = sys.argv[1]
json_mode = "--json" in sys.argv

orphans = []

if not os.path.isdir(tickets_dir):
    if json_mode:
        print(json.dumps([]))
    else:
        print("(none — tickets directory not found)")
    sys.exit(0)

for fname in sorted(os.listdir(tickets_dir)):
    if not fname.endswith(".md"):
        continue
    fpath = os.path.join(tickets_dir, fname)
    with open(fpath, encoding="utf-8") as f:
        content = f.read()

    # Parse YAML frontmatter between the two '---' delimiters
    if not content.startswith("---"):
        continue
    parts = content.split("---", 2)
    if len(parts) < 3:
        continue
    frontmatter = parts[1]
    body = parts[2]

    # Extract fields from frontmatter
    fields = {}
    current_key = None
    in_list = False
    list_items = []

    for line in frontmatter.splitlines():
        # List item under a key
        if in_list and (line.startswith("  - ") or line.startswith("  -\t") or line.rstrip() == "  -"):
            list_items.append(line.strip()[2:].strip())
            continue
        # Nested mapping item under a list key (e.g. deps entries)
        if in_list and (line.startswith("    ") or line.startswith("\t")):
            # Append raw text for later parsing
            list_items.append(line.strip())
            continue
        # Blank lines within a block list are valid YAML — skip them
        if in_list and line.strip() == "":
            continue
        # End of list when we hit a new top-level key
        if in_list:
            fields[current_key] = list_items
            in_list = False
            list_items = []

        if ":" in line:
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip()
            if val == "" or val == "[]":
                # Could be start of a block list or empty
                current_key = key
                if val == "[]":
                    fields[key] = []
                else:
                    in_list = True
                    list_items = []
            else:
                fields[key] = val

    if in_list:
        fields[current_key] = list_items

    status = fields.get("status", "").strip()
    itype = fields.get("type", "task").strip()
    title_fm = fields.get("title", "").strip()
    priority = fields.get("priority", "4").strip()

    # Only consider open or in_progress tickets
    if status not in ("open", "in_progress"):
        continue

    # Skip epics and bugs
    if itype in ("epic", "bug"):
        continue

    # Determine if this ticket has a parent-child dependency
    deps_raw = fields.get("deps", [])
    has_parent = False
    if isinstance(deps_raw, list):
        # Each dep item might be raw text like "type: parent-child" or "id: ..."
        # We need to detect whether any dep block has type=parent-child
        dep_type = None
        dep_id = None
        for item in deps_raw:
            item = item.strip()
            if item.startswith("type:"):
                dep_type = item.split(":", 1)[1].strip()
            elif item.startswith("id:"):
                dep_id = item.split(":", 1)[1].strip()
            elif item.startswith("- type:"):
                dep_type = item.split(":", 1)[1].strip()
            elif item.startswith("- id:"):
                dep_id = item.split(":", 1)[1].strip()
            # When we've collected both parts of a dep block, check it
            if dep_type is not None and dep_id is not None:
                if dep_type == "parent-child":
                    has_parent = True
                    break
                dep_type = None
                dep_id = None
        # Handle case where dep_type was set but dep_id not yet seen
        if dep_type == "parent-child":
            has_parent = True

    # Also support simple "parent:" field (alternative frontmatter style)
    parent_field = fields.get("parent", "").strip()
    if parent_field:
        has_parent = True

    if has_parent:
        continue

    # Extract title: prefer frontmatter title, fall back to first # heading
    title = title_fm
    if not title:
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("# "):
                title = line[2:].strip()
                break
    if not title:
        title = fname.replace(".md", "")

    # Derive id: prefer frontmatter id field, fall back to filename stem
    ticket_id = fields.get("id", fname.replace(".md", "")).strip()

    try:
        prio = int(priority)
    except ValueError:
        prio = 4

    orphans.append({
        "id": ticket_id,
        "title": title,
        "issue_type": itype,
        "parent": None,
        "priority": prio,
    })

if json_mode:
    print(json.dumps(orphans, indent=2, default=str))
else:
    if not orphans:
        print("(none — all open tasks belong to an epic)")
    else:
        # Group by priority
        by_priority = {}
        for o in orphans:
            p = o.get("priority", 4)
            by_priority.setdefault(p, []).append(o)

        for p in sorted(by_priority.keys()):
            items = by_priority[p]
            print(f"P{p} ({len(items)} tasks):")
            for item in items:
                itype = item.get("issue_type", "task")
                print(f"  {item['id']}  [{itype}]  {item['title']}")
            print()
        print(f"Total: {len(orphans)} orphaned tasks")
PYEOF
