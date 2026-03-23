---
id: dso-ech8
status: closed
deps: []
links: []
created: 2026-03-23T00:25:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o5ap
---
# Write ticket CLI reference document

Create plugins/dso/docs/ticket-cli-reference.md — the authoritative CLI reference for all ticket commands. Document each subcommand: init, create, show, list, transition, comment, link, unlink, deps, sync, archive, bridge-status, bridge-fsck, and the --format=llm output mode. Each command section covers: usage syntax, required/optional arguments, exit codes, output format (default JSON vs --format=llm JSONL), and a representative example showing input and expected output.

Source truth for each command is in plugins/dso/scripts/ticket-*.sh and plugins/dso/scripts/ticket-*.py. Consult the dispatcher plugins/dso/scripts/ticket for the full subcommand list and routing.

IMPORTANT: Write files to working tree only. Do NOT commit. This documentation will be included in w21-wbqz's atomic commit.

TDD Requirement: TDD exemption — Criterion #3 (static assets only): this task creates only a Markdown documentation file with no conditional logic, no executable code, and no testable behavior. Any test written would be a change-detector that only asserts the file exists.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] File exists at plugins/dso/docs/ticket-cli-reference.md
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/ticket-cli-reference.md
- [ ] File documents all 13 subcommands: init, create, show, list, transition, comment, link, unlink, deps, sync, archive, bridge-status, bridge-fsck
  Verify: for cmd in init create show list transition comment link unlink deps sync archive bridge-status bridge-fsck; do grep -q "$cmd" $(git rev-parse --show-toplevel)/plugins/dso/docs/ticket-cli-reference.md || exit 1; done
- [ ] File documents --format=llm output mode
  Verify: grep -q 'format=llm' $(git rev-parse --show-toplevel)/plugins/dso/docs/ticket-cli-reference.md
- [ ] File is NOT committed (lives in working tree only; will be included in w21-wbqz atomic commit)
  Verify: git -C $(git rev-parse --show-toplevel) status --short | grep -q 'ticket-cli-reference.md'


## Notes

**2026-03-23T01:50:00Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T01:51:33Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T01:51:37Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-23T01:53:38Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T02:04:42Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-23T02:04:53Z**

CHECKPOINT 6/6: Done ✓
