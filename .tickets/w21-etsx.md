---
id: w21-etsx
status: in_progress
deps: [w21-cxzv, w21-v9tg, w21-4d04]
links: []
created: 2026-03-21T23:39:13Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-5e4i
---
# Update project-detect.sh script header comment and usage docs

Update the header comment block in plugins/dso/scripts/project-detect.sh to document the new --suites flag, its output schema, and heuristic sources. No logic changes.

test-exempt: This task has no conditional logic and modifies only static documentation comments within the script (no branching, no behavioral contract to assert). Exemption criterion: 'The task is infrastructure-boundary-only — it touches only configuration wiring, dependency injection setup, or module registration with no business logic.' (comment-only change).

Implementation steps:
1. Update the Usage line: 'Usage: project-detect.sh [--suites] <project-dir>'
2. Add --suites to the description block
3. Document the JSON output schema for --suites mode: name (string, unique), command (string), speed_class (fast|slow|unknown), runner (make|pytest|npm|bash|config)
4. Document the heuristic precedence order: config > Makefile /^test[-_]/ > pytest dirs > npm scripts > bash runners
5. Document the name derivation rules: Makefile test-foo -> foo, pytest tests/unit/ -> unit, npm test:integration -> integration, bash test-hooks.sh -> hooks
6. Document backward compatibility guarantee: without --suites, output is unchanged KEY=VALUE format

## Acceptance Criteria

- [ ] Script header contains '--suites' flag documentation
  Verify: grep -q '\-\-suites' $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh
- [ ] Script header documents the JSON output schema fields (name, command, speed_class, runner)
  Verify: grep -q 'speed_class' $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh
- [ ] Script header documents heuristic precedence order
  Verify: grep -q 'precedence\|Precedence' $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh
- [ ] ruff format --check passes (exit 0) on py files
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py
- [ ] ruff check passes (exit 0) on py files
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py


## Notes

**2026-03-22T00:45:13Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T00:45:26Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T00:45:29Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-22T00:46:20Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T00:46:20Z**

CHECKPOINT 5/6: Tests pass — 112 PASSED, 0 FAILED (bash tests/scripts/test-project-detect.sh) ✓

**2026-03-22T00:46:20Z**

CHECKPOINT 6/6: Done ✓ — AC1 (--suites grep) PASS, AC2 (speed_class grep) PASS, AC3 (precedence grep) PASS, AC4 (ruff format) PASS, AC5 (ruff check) PASS
