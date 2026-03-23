---
id: dso-5fbs
status: closed
deps: []
links: []
created: 2026-03-23T15:19:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-wbqz
---
# RED Test: write failing tests for tk→ticket infrastructure and hook guard updates

TDD RED task for story w21-wbqz. Write failing tests that assert the post-migration state BEFORE the implementation tasks run.

## TDD Requirement
Tests must FAIL (RED) before T2/T3 changes are applied. They will become GREEN after T2 and T3 complete.

## Files to Create
1. tests/hooks/test-compute-diff-hash-tickets-tracker.sh
   - test_allowlist_uses_tickets_tracker_path: assert review-gate-allowlist.conf contains .tickets-tracker/** (not .tickets/**)
   - test_compute_diff_hash_fallback_uses_tickets_tracker_path: assert compute-diff-hash.sh fallback pathspec contains :!.tickets-tracker/** (not :!.tickets/**)

2. tests/hooks/test-pre-bash-functions-ticket-guards.sh
   - test_bug_close_guard_fires_on_ticket_transition_closed: source pre-bash-functions.sh, call hook_bug_close_guard with JSON input {"tool_name":"Bash","tool_input":{"command":"ticket transition abc1-def2 open closed --reason=fixed"}} — assert exit code 2 (blocked) or non-zero output indicating the guard fires
   - test_bug_close_guard_no_false_positive_on_ticket_show: hook_bug_close_guard with command 'ticket show abc1-def2' — assert exit 0 (not blocked)
   - test_closed_parent_guard_fires_on_ticket_create_parent: invoke closed-parent-guard.sh directly via echo JSON | bash closed-parent-guard.sh — with command 'ticket create "title" --parent abc1-def2' where parent is closed — assert exit 2
   - test_closed_parent_guard_does_not_fire_on_tk_sync: command 'tk sync' — assert exit 0 (tk sync is still valid)

## Fuzzy-Match Verification
- compute-diff-hash.sh normalized: computediffhashsh → test-compute-diff-hash-tickets-tracker.sh normalized: testcomputediffhashticketstracksh — 'computediffhash' is substring ✓
- pre-bash-functions.sh normalized: prebashfunctionssh → test-pre-bash-functions-ticket-guards.sh normalized: testprebashfunctionsticketguardssh — 'prebashfunctions' is substring ✓

## Test Structure Pattern
Follow the existing pattern in tests/hooks/test-check-validation-failures.sh:
  run_hook() { echo "$1" | bash "$HOOK" > /dev/null 2>/dev/null || exit_code=$?; echo $exit_code; }
For hook_bug_close_guard tests, source pre-bash-functions.sh and call the function directly.
For closed-parent-guard.sh tests, invoke as standalone script with JSON piped to stdin.

## ACCEPTANCE CRITERIA

- [ ] `tests/hooks/test-compute-diff-hash-tickets-tracker.sh` exists
  Verify: test -f tests/hooks/test-compute-diff-hash-tickets-tracker.sh
- [ ] `tests/hooks/test-pre-bash-functions-ticket-guards.sh` exists
  Verify: test -f tests/hooks/test-pre-bash-functions-ticket-guards.sh
- [ ] Test file 1 contains at least 2 test functions
  Verify: grep -c "^test_" tests/hooks/test-compute-diff-hash-tickets-tracker.sh | awk '{exit ($1 < 2)}'
- [ ] Test file 2 contains at least 4 test functions
  Verify: grep -c "^test_" tests/hooks/test-pre-bash-functions-ticket-guards.sh | awk '{exit ($1 < 4)}'
- [ ] Tests are RED (fail before T2/T3 implementation)
  Verify: bash tests/hooks/test-compute-diff-hash-tickets-tracker.sh 2>&1 | grep -q "FAIL\|fail"
- [ ] .test-index entries added for both test files with RED markers
  Verify: grep -q "test-compute-diff-hash-tickets-tracker" .test-index && grep -q "test-pre-bash-functions-ticket-guards" .test-index


## Notes

**2026-03-23T15:26:29Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T15:27:14Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T15:29:17Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-23T15:31:15Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T15:35:48Z**

CHECKPOINT 5/6: Validation passed ✓ — both test files are syntactically valid bash, run cleanly, GREEN tests pass, RED tests fail as expected; all 6 AC criteria verified

**2026-03-23T15:35:52Z**

CHECKPOINT 6/6: Done ✓ — all 6 AC criteria pass: files exist, have correct test count, are RED, .test-index entries added with RED markers
