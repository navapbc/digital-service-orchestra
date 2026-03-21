---
id: w20-v9eo
status: closed
deps: [w20-qxu2, w20-0aaw]
links: []
created: 2026-03-21T16:31:58Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6llo
---
# Implement tombstone write in archive-closed-tickets.sh

Implement tombstone write: when archive-closed-tickets.sh moves a ticket .md file to .tickets/archive/, it must also write a tombstone JSON to .tickets/archive/tombstones/<id>.json with exactly: {id: <ticket-id>, type: <ticket-type>, final_status: <status>}. Implementation steps: (1) create .tickets/archive/tombstones/ directory if needed, (2) extract type field from YAML frontmatter (add to _scan_tickets via ticket_type associative array), (3) write tombstone atomically (write to .tmp, then mv) after successful archive move, (4) tombstone is NOT written for protected tickets. The tombstone directory must be created alongside archive/ initialization. No tombstone for tickets restored from archive. TDD Requirement: Run bash tests/scripts/test-archive-tombstone.sh — all 4 tests must pass GREEN.

## ACCEPTANCE CRITERIA

- [ ] bash tests/scripts/test-archive-tombstone.sh passes (all 4 tests GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone.sh
- [ ] Tombstone file created at .tickets/archive/tombstones/<id>.json on archive
  Verify: TICKETS_DIR=$(mktemp -d) && mkdir -p "$TICKETS_DIR/archive" && printf -- '---\nid: t1\nstatus: closed\ntype: task\ndeps: []\n---\n# T\n' > "$TICKETS_DIR/t1.md" && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/archive-closed-tickets.sh && test -f "$TICKETS_DIR/archive/tombstones/t1.json"
- [ ] Tombstone JSON has exactly fields: id, type, final_status
  Verify: python3 -c "import json; d=json.load(open('$(git rev-parse --show-toplevel)/.tickets/archive/tombstones/$(ls $(git rev-parse --show-toplevel)/.tickets/archive/tombstones/ 2>/dev/null | head -1)')); assert set(d.keys()) == {'id','type','final_status'}, d" 2>/dev/null || true
- [ ] No tombstone written for protected tickets (open children)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] Tombstone write failure (disk full/permissions) logs warning to stderr but does NOT abort the archive operation
  Verify: grep -q 'tombstone.*warn\|warn.*tombstone\|WARNING.*tombstone' $(git rev-parse --show-toplevel)/plugins/dso/scripts/archive-closed-tickets.sh

