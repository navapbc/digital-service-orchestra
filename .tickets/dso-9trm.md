---
id: dso-9trm
status: in_progress
deps: [dso-gfph]
links: []
created: 2026-03-23T03:57:20Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-7mlx
---
# Implement _phase_snapshot in cutover-tickets-migration.sh

Implement the _phase_snapshot stub in plugins/dso/scripts/cutover-tickets-migration.sh to capture a comprehensive pre-flight snapshot of all tickets.

Implementation details:

1. Introduce CUTOVER_SNAPSHOT_FILE env var (default: ${CUTOVER_LOG_DIR}/cutover-snapshot-${_LOG_TIMESTAMP}.json) at the top of the script (near other env var defaults).

2. Replace _phase_snapshot() stub body with:
   - Collect all ticket IDs from .tickets/*.md (ls .tickets/*.md | xargs basename -s .md, filtered to exclude .index.json and non-ticket files)
   - For each ticket ID, run: tk show <id> (capture full output including frontmatter + body)
   - Capture: total ticket count, list of IDs, full tk show output per ticket, dep graph (tk dep tree on parent epic IDs found), Jira mappings (from frontmatter jira_key fields)
   - Write JSON snapshot to $CUTOVER_SNAPSHOT_FILE using python3 json.dumps (handles special chars)
   - Schema: {"timestamp": "ISO8601", "ticket_count": N, "tickets": [{"id": "...", "tk_show_output": "..."}, ...], "jira_mappings": {"id": "jira_key"}}
   - Print: "Snapshot written to $CUTOVER_SNAPSHOT_FILE" to stdout
   - If .tickets/ does not exist or has no tickets, write snapshot with ticket_count=0 and exit 0 (non-fatal)

3. Malformed ticket handling: if tk show <id> exits non-zero, log the error to stderr and continue (do not abort the phase). Include the ticket ID in the snapshot with tk_show_output set to 'ERROR: <message>'.

File to edit: plugins/dso/scripts/cutover-tickets-migration.sh

TDD REQUIREMENT: Tests from Task (dso-gfph) must be RED before starting. After implementation, run bash tests/scripts/test-cutover-tickets-migration.sh to confirm snapshot tests turn GREEN.

## Acceptance Criteria

- [ ] bash tests/scripts/test-cutover-tickets-migration.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-cutover-tickets-migration.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] CUTOVER_SNAPSHOT_FILE env var is supported and defaults to a timestamped path
  Verify: grep -q 'CUTOVER_SNAPSHOT_FILE' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] _phase_snapshot function body creates the snapshot JSON file
  Verify: grep -A 5 '_phase_snapshot()' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh | grep -q 'CUTOVER_SNAPSHOT_FILE'
- [ ] All 3 snapshot tests from Task dso-gfph turn GREEN (no FAIL lines for snapshot)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -v 'FAIL.*snapshot' | grep -qv '^PASSED: 0'


## Notes

**2026-03-23T05:15:37Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T05:16:40Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T05:16:45Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

**2026-03-23T05:18:14Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T05:18:29Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-23T05:19:26Z**

CHECKPOINT 6/6: Done ✓
