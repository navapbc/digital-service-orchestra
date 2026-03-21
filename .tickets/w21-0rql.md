---
id: w21-0rql
status: closed
deps: [w21-cjso]
links: []
created: 2026-03-21T07:12:01Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-q0nn
---
# IMPL: Wire ticket compact subcommand into ticket dispatcher

Add the 'compact' subcommand to plugins/dso/scripts/ticket dispatcher script.

## TDD Requirement
Depends on: ticket-compact.sh implementation (w21-cjso).
The test-ticket-compact.sh test 'test_compact_subcommand_routes_correctly' covers this.
Confirm GREEN after implementation:
  cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh -k subcommand
Expected: routing test passes.

## Implementation Steps

File: plugins/dso/scripts/ticket

### 1. Add 'compact' to _usage() help text
Add to the Subcommands section:
  compact     Compact ticket event history into a SNAPSHOT event

### 2. Add compact case to the main case statement
```bash
compact)
    _ensure_initialized
    exec bash "$SCRIPT_DIR/ticket-compact.sh" "$@"
    ;;
```

Position: after the 'comment' case, before the '*) unknown subcommand' fallthrough.

## Stability Note
This change is independently deployable: the dispatcher routes to ticket-compact.sh, which already exists (from w21-cjso). If ticket-compact.sh does not exist, the exec will fail with 'script not found' — this is an acceptable error state during phased deployment.

## File to Edit
plugins/dso/scripts/ticket

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] 'compact' appears in ticket dispatcher usage output
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket 2>&1 | grep -q 'compact'
- [ ] ticket compact subcommand routes to ticket-compact.sh
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh 2>&1 | grep 'subcommand.*PASS'


## Notes

**2026-03-21T08:21:31Z**

CHECKPOINT 6/6: Done ✓ — compact subcommand already wired in w21-cjso implementation.
