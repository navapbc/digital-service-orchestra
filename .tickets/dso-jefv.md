---
id: dso-jefv
status: closed
deps: [dso-si1e]
links: []
created: 2026-03-21T16:09:16Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-k2yz
---
# Implement ticket deps subcommand in ticket dispatcher

## Description

Wire `ticket deps <id>` into the `ticket` dispatcher, delegating to `ticket-graph.py` for the JSON output.

**Files to modify:**
- `plugins/dso/scripts/ticket` — add `deps` dispatch case (DO NOT remove the `link`/`unlink` cases added by dso-a4fy — only ADD the `deps` case):
  ```bash
  deps)
      _ensure_initialized
      exec python3 "$SCRIPT_DIR/ticket-graph.py" "$@"
      ;;
  ```

**IMPORTANT — Cycle detection architecture**: Also update the `link` dispatch case in this task to route through `python3 ticket-graph.py --link source target relation` instead of the raw `ticket-link.sh`. `ticket-graph.py`'s `add_dependency()` function calls `check_would_create_cycle` first, then writes the LINK event (delegating to the event-writing logic). This ensures cycle detection happens at `ticket link` time. `ticket-link.sh` becomes an internal helper; the public `ticket link` command uses ticket-graph.py as the authoritative path.

**Output format** (printed to stdout as JSON):
```json
{
  "ticket_id": "tkt-001",
  "deps": [
    {"target_id": "tkt-002", "relation": "blocks", "link_uuid": "<uuid>"}
  ],
  "blockers": ["tkt-002"],
  "ready_to_work": false
}
```

**Note:** `blockers` contains only direct deps with `relation=blocks|depends_on` where the target's status is not `closed`.

**TDD Requirement (GREEN):** Make all tests in dso-si1e pass:
`bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-deps.sh`

## Acceptance Criteria

- [ ] `ticket deps <id>` subcommand is routed in `plugins/dso/scripts/ticket`
  Verify: `grep -q "deps)" $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket`
- [ ] `ticket link`, `ticket unlink`, AND `ticket deps` dispatch cases all present in `plugins/dso/scripts/ticket` (no regressions from dso-a4fy)
  Verify: `grep -c "link)\|unlink)\|deps)" $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket | awk '{exit ($1 < 3)}'`
- [ ] `ticket link` routes through ticket-graph.py's cycle-checked `add_dependency()` path
  Verify: `grep -A3 "link)" $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket | grep -q "ticket-graph.py"`
- [ ] `ticket link X Y blocks` followed by `ticket link Y X blocks` exits nonzero (cycle detected)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-link.sh`
- [ ] `ticket deps <id>` outputs valid JSON with required keys
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-deps.sh`
- [ ] `ticket deps <id>` returns `ready_to_work=true` when all blockers closed
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-deps.sh`
- [ ] `ruff check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`
