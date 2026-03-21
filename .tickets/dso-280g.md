---
id: dso-280g
status: closed
deps: [dso-hzwm]
links: []
created: 2026-03-21T16:10:36Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-goqp
---
# Wire tickets-tracker guards into pre-edit.sh, pre-write.sh, and pre-bash.sh dispatchers

Wire hook_tickets_tracker_guard and hook_tickets_tracker_bash_guard into the three dispatchers.

Changes required:

1. plugins/dso/hooks/dispatchers/pre-edit.sh:
   - Update header comment to add hook_tickets_tracker_guard as step 4
   - Add hook_tickets_tracker_guard to _pre_edit_dispatch() for loop after hook_title_length_validator

2. plugins/dso/hooks/dispatchers/pre-write.sh:
   - Update header comment to add hook_tickets_tracker_guard as step 4
   - Add hook_tickets_tracker_guard to _pre_write_dispatch() for loop after hook_title_length_validator

3. plugins/dso/hooks/dispatchers/pre-bash.sh:
   - Update header comment to add hook_tickets_tracker_bash_guard as step 9
   - Add hook_tickets_tracker_bash_guard to _pre_bash_dispatch() for loop after hook_blocked_test_command

All three dispatchers already source the respective function libraries:
- pre-edit.sh and pre-write.sh source pre-edit-write-functions.sh (which will have hook_tickets_tracker_guard)
- pre-bash.sh sources pre-bash-functions.sh (which will have hook_tickets_tracker_bash_guard)

No new source lines needed — only for loop additions and comment updates.

Verify by running the full test suite.


## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] hook_tickets_tracker_guard appears in pre-edit.sh for loop
  Verify: grep -q 'hook_tickets_tracker_guard' $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-edit.sh
- [ ] hook_tickets_tracker_guard appears in pre-write.sh for loop
  Verify: grep -q 'hook_tickets_tracker_guard' $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-write.sh
- [ ] hook_tickets_tracker_bash_guard appears in pre-bash.sh for loop
  Verify: grep -q 'hook_tickets_tracker_bash_guard' $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-bash.sh
- [ ] End-to-end: Edit to .tickets-tracker/ path blocked via pre-edit.sh dispatcher
  Verify: echo '{"tool_name":"Edit","tool_input":{"file_path":"/repo/.tickets-tracker/foo.json"}}' | bash $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-edit.sh; test $? -eq 2
- [ ] End-to-end: Edit to non-.tickets-tracker/ path allowed via pre-edit.sh dispatcher
  Verify: echo '{"tool_name":"Edit","tool_input":{"file_path":"/repo/src/app.py"}}' | bash $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-edit.sh; test $? -eq 0
- [ ] ruff check plugins/dso/scripts/*.py tests/**/*.py passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py

## Notes

**2026-03-21T19:12:37Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T19:13:02Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T19:13:02Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T19:13:56Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T19:15:16Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T19:15:28Z**

CHECKPOINT 6/6: Done ✓
