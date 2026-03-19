#!/usr/bin/env bash
set -euo pipefail
# dedup-tickets.sh — Deduplicate .tickets/ files
#
# Two operations:
#   A. Fix true jira_key duplicates in .sync-state.json (delete dupe file + entry)
#   B. Close spam tickets (empty shells in same-title groups of 3+)
#
# Usage:
#   scripts/dedup-tickets.sh [--dry-run|--execute]
#
# Default: --dry-run (report only)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TICKETS_DIR="$REPO_ROOT/.tickets"
SYNC_STATE="$REPO_ROOT/.tickets/.sync-state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK="${TK:-$SCRIPT_DIR/tk}"
MODE="${1:---dry-run}"

if [[ "$MODE" != "--dry-run" && "$MODE" != "--execute" ]]; then
    echo "Usage: $0 [--dry-run|--execute]" >&2
    exit 1
fi

echo "=== Ticket Dedup Tool (mode: $MODE) ==="
echo ""

# ─── Part A: Fix 16 true jira_key duplicates ────────────────────────────────

python3 - "$TICKETS_DIR" "$SYNC_STATE" "$MODE" <<'PYEOF'
import json, os, sys
from collections import defaultdict

tickets_dir = sys.argv[1]
sync_state_path = sys.argv[2]
mode = sys.argv[3]

with open(sync_state_path) as f:
    sync_state = json.load(f)

# Find jira_keys mapped to multiple local IDs
jira_to_ids = defaultdict(list)
for tk_id, entry in sync_state.items():
    if not isinstance(entry, dict):
        continue
    jk = entry.get("jira_key", "")
    if jk:
        jira_to_ids[jk].append(tk_id)

dupes = {jk: ids for jk, ids in jira_to_ids.items() if len(ids) > 1}

print(f"Part A: {len(dupes)} jira_key duplicates found")
print("")

to_delete = []  # (tk_id, jira_key, reason)

for jira_key, tk_ids in sorted(dupes.items()):
    # Score each: larger file = richer content
    scored = []
    for tk_id in tk_ids:
        path = os.path.join(tickets_dir, f"{tk_id}.md")
        size = os.path.getsize(path) if os.path.exists(path) else 0
        scored.append((tk_id, size))
    # Keep the one with most content; tie-break alphabetically
    scored.sort(key=lambda x: (-x[1], x[0]))
    keeper = scored[0][0]
    for tk_id, size in scored[1:]:
        to_delete.append((tk_id, jira_key, f"duplicate of {keeper}"))
        print(f"  {jira_key}: DELETE {tk_id} (size={size}), KEEP {keeper} (size={scored[0][1]})")

print(f"\n  Total files to delete: {len(to_delete)}")

if mode == "--execute" and to_delete:
    for tk_id, jira_key, reason in to_delete:
        path = os.path.join(tickets_dir, f"{tk_id}.md")
        if os.path.exists(path):
            os.remove(path)
            print(f"  Deleted: {path}")
        # Remove from sync state
        if tk_id in sync_state:
            del sync_state[tk_id]
            print(f"  Removed sync-state entry: {tk_id}")

    with open(sync_state_path, "w") as f:
        json.dump(sync_state, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"\n  Updated {sync_state_path}")

print("")
PYEOF

# ─── Part B: Close spam tickets (empty shells in groups of 3+) ──────────────

python3 - "$TICKETS_DIR" "$SYNC_STATE" "$MODE" "$TK" <<'PYEOF'
import json, os, re, subprocess, sys
from collections import defaultdict

tickets_dir = sys.argv[1]
sync_state_path = sys.argv[2]
mode = sys.argv[3]
tk_cmd = sys.argv[4]

def parse_ticket(path):
    """Parse a ticket file: frontmatter dict, title (from # heading), body."""
    with open(path) as f:
        content = f.read()
    fm = {}
    body = content
    m = re.match(r'^---\n(.*?)\n---\n?(.*)', content, re.DOTALL)
    if m:
        for line in m.group(1).split('\n'):
            kv = line.split(':', 1)
            if len(kv) == 2:
                fm[kv[0].strip()] = kv[1].strip()
        body = m.group(2)
    # Title is the first # heading after frontmatter
    title = ''
    tm = re.search(r'^#\s+(.+)$', body, re.MULTILINE)
    if tm:
        title = tm.group(1).strip()
    return fm, title, body

def has_content(path):
    """Check if a ticket has meaningful body content (notes, description)."""
    fm, title, body = parse_ticket(path)
    # Remove the title heading from body
    body = re.sub(r'^#\s+.+$', '', body, count=1, flags=re.MULTILINE).strip()
    # Check for notes section with content
    if '## Notes' in body:
        notes_part = body.split('## Notes', 1)[1].strip()
        if notes_part:
            return True
    # Check for any substantial body (more than just headers)
    lines = [l for l in body.split('\n') if l.strip() and not l.startswith('#')]
    return len(lines) > 0

# Group tickets by title
titles = defaultdict(list)
for fname in os.listdir(tickets_dir):
    if not fname.endswith('.md'):
        continue
    path = os.path.join(tickets_dir, fname)
    fm, title, _ = parse_ticket(path)
    if not title:
        continue
    tk_id = fname[:-3]
    size = os.path.getsize(path)
    has_body = has_content(path)
    status = fm.get('status', 'open')
    # Prefer lockpick-doc-to-logic- prefixed IDs as keepers
    is_canonical = tk_id.startswith('lockpick-doc-to-logic-')
    titles[title].append({
        'tk_id': tk_id,
        'size': size,
        'has_body': has_body,
        'status': status,
        'is_canonical': is_canonical,
        'path': path,
    })

# Find spam groups: 2+ same-title where majority are empty
spam_groups = {}
for title, tickets in titles.items():
    if len(tickets) < 2:
        continue
    empty_count = sum(1 for t in tickets if not t['has_body'])
    if empty_count < len(tickets) // 2:
        continue  # Majority have content — not spam
    spam_groups[title] = tickets

total_to_close = 0
close_list = []

print(f"Part B: {len(spam_groups)} spam title groups found")
print("")

for title, tickets in sorted(spam_groups.items(), key=lambda x: -len(x[1])):
    # Pick keeper: prefer canonical prefix, then most content, then alphabetical
    tickets.sort(key=lambda t: (
        -int(t['is_canonical']),
        -int(t['has_body']),
        -t['size'],
        t['tk_id'],
    ))
    keeper = tickets[0]
    dupes = [t for t in tickets[1:] if t['status'] != 'closed']

    if not dupes:
        continue

    print(f"  \"{title[:70]}\" ({len(tickets)} copies)")
    print(f"    KEEP: {keeper['tk_id']} (size={keeper['size']}, body={keeper['has_body']})")
    for t in dupes:
        print(f"    CLOSE: {t['tk_id']} (size={t['size']}, body={t['has_body']})")
        close_list.append((t['tk_id'], keeper['tk_id']))
    total_to_close += len(dupes)

print(f"\n  Total tickets to close: {total_to_close}")

if mode == "--execute" and close_list:
    closed = 0
    errors = 0
    for tk_id, keeper_id in close_list:
        try:
            ticket_path = os.path.join(tickets_dir, f"{tk_id}.md")
            if not os.path.exists(ticket_path):
                # Already deleted by Part A
                continue
            env = os.environ.copy()
            env['TICKETS_DIR'] = tickets_dir
            result = subprocess.run(
                [tk_cmd, 'close', tk_id, f'--reason=Duplicate of {keeper_id}'],
                capture_output=True, text=True, env=env, timeout=10
            )
            if result.returncode == 0:
                closed += 1
            else:
                # Might already be closed
                if 'already closed' in result.stderr.lower():
                    closed += 1
                else:
                    print(f"  Warning: tk close {tk_id} failed: {result.stderr.strip()}", file=sys.stderr)
                    errors += 1
        except Exception as e:
            print(f"  Error closing {tk_id}: {e}", file=sys.stderr)
            errors += 1

    print(f"\n  Closed: {closed}, Errors: {errors}")

print("")
PYEOF

echo "=== Done ==="
