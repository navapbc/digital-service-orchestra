#!/usr/bin/env bash
# Lists open tasks/features that are not children of any epic.
# Bugs are excluded (they are standalone by nature during normal development).
# Usage: ./scripts/orphaned-tasks.sh [--json]
set -euo pipefail

JSON_FLAG=""
if [[ "${1:-}" == "--json" ]]; then
  JSON_FLAG="true"
fi

bd list --status=open --limit=0 --json 2>/dev/null | python3 -c "
import json, sys

issues = json.load(sys.stdin)
json_mode = '--json' in sys.argv

orphans = []
for issue in issues:
    itype = issue.get('issue_type', 'task')
    # Skip epics and bugs (bugs are standalone by nature)
    if itype in ('epic', 'bug'):
        continue
    # Check if this issue is a child of any epic via parent-child dependency
    is_child = any(
        dep.get('type') == 'parent-child' and dep.get('depends_on_id') != issue['id']
        for dep in issue.get('dependencies', [])
    )
    if not is_child:
        orphans.append(issue)

if json_mode:
    print(json.dumps(orphans, indent=2, default=str))
else:
    if not orphans:
        print('(none — all open tasks belong to an epic)')
    else:
        # Group by priority
        by_priority = {}
        for o in orphans:
            p = o.get('priority', 4)
            by_priority.setdefault(p, []).append(o)

        for p in sorted(by_priority.keys()):
            items = by_priority[p]
            print(f'P{p} ({len(items)} tasks):')
            for item in items:
                itype = item.get('issue_type', 'task')
                print(f\"  {item['id']}  [{itype}]  {item['title']}\")
            print()
        print(f'Total: {len(orphans)} orphaned tasks')
" ${JSON_FLAG:+--json}
