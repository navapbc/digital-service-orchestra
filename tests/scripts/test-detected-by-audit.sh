#!/usr/bin/env bash
# test-detected-by-audit.sh — Audit non-bug tickets for detected_by:* tag contamination.
#
# Exits 0 when no non-bug tickets carry detected_by:* tags (clean).
# Exits 1 with descriptive output when contamination is found.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
DSO="${REPO_ROOT}/.claude/scripts/dso"

echo "=== detected_by contamination audit ==="
echo "Querying ticket list..."

found=$(
  "${DSO}" ticket list --format=llm 2>/dev/null | python3 -c "
import json, sys

found = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        t = json.loads(line)
    except json.JSONDecodeError:
        continue
    ticket_type = t.get('t', '')
    tags = t.get('tags', [])
    if ticket_type != 'bug' and any(tg.startswith('detected_by:') for tg in tags):
        found.append({'id': t.get('id', ''), 'type': ticket_type, 'tags': tags})

for t in found:
    print(t['id'], t['type'], ' '.join(t['tags']))

print(f'TOTAL:{len(found)}', flush=True)
"
)

total=$(echo "$found" | grep 'TOTAL:' | sed 's/TOTAL://' || echo "0")

if [[ "$total" -eq 0 ]]; then
  echo "PASS: No non-bug tickets carry detected_by:* tags."
  exit 0
else
  echo "FAIL: $total non-bug ticket(s) carry detected_by:* tags (contamination detected)."
  echo ""
  echo "Affected tickets:"
  echo "$found" | grep -v '^TOTAL:'
  echo ""
  echo "Remediation: untag via '.claude/scripts/dso ticket untag <id> detected_by:<value>'"
  echo "  or document as known exception with written rationale."
  exit 1
fi
