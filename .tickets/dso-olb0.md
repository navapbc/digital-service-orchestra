---
id: dso-olb0
status: closed
deps: []
links: []
created: 2026-03-22T00:58:45Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dww7
---
# RED: Write failing tests for outbound comment push in bridge-outbound.py

Write failing tests for COMMENT event handling to be added to `plugins/dso/scripts/bridge-outbound.py`.

## Test file

`tests/scripts/test_bridge_outbound_comment.py`

## Tests to write (all must fail RED before implementation)

- `test_outbound_push_comment_calls_add_comment_with_uuid_marker` — given a COMMENT event in the git diff for a ticket with an existing SYNC (mapped to DSO-42), `process_outbound` calls `acli_client.add_comment('DSO-42', body)` where body ends with `<!-- origin-uuid: {event_uuid} -->`
- `test_outbound_push_comment_skips_ticket_without_sync` — given a COMMENT event for a ticket with NO SYNC event (no Jira mapping), `process_outbound` does NOT call `acli_client.add_comment`
- `test_outbound_push_comment_skips_bridge_originated_comment` — given a COMMENT event whose `env_id` matches the bridge env ID, `process_outbound` does NOT call `acli_client.add_comment` (echo prevention)
- `test_outbound_push_comment_writes_jira_id_to_dedup_map` — after a successful `add_comment` call returning `{id: 'jira-comment-42'}`, the dedup map file at `.tickets-tracker/<ticket-id>/.jira-comment-map` is written with `uuid_to_jira_id[event_uuid] = 'jira-comment-42'` and `jira_id_to_uuid['jira-comment-42'] = event_uuid`
- `test_outbound_push_comment_does_not_duplicate_if_already_in_dedup_map` — if the event UUID is already in `uuid_to_jira_id`, `add_comment` is NOT called again (idempotency)

## TDD requirement

Write all 5 tests FIRST. Run `python3 -m pytest tests/scripts/test_bridge_outbound_comment.py` and confirm all fail. Do NOT implement until RED is verified.

## Helper fixtures needed

Reuse `_write_event` and `_BRIDGE_ENV_ID` patterns from `tests/scripts/test_bridge_outbound.py`. Tests must be independently runnable — do not import from test_bridge_outbound.py.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file `tests/scripts/test_bridge_outbound_comment.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound_comment.py
- [ ] Test file contains all 5 required test functions
  Verify: cd $(git rev-parse --show-toplevel) && grep -c 'def test_' tests/scripts/test_bridge_outbound_comment.py | awk '{exit ($1 < 5)}'
- [ ] All 5 tests FAIL (RED) before implementation — non-zero exit
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_comment.py 2>&1; test $? -ne 0

## Notes

<!-- note-id: wbdt6sny -->
<!-- timestamp: 2026-03-22T01:21:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: zilrfv37 -->
<!-- timestamp: 2026-03-22T01:21:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Read bridge-outbound.py, test_bridge_outbound.py, and comment-sync-dedup.md ✓

<!-- note-id: 4jqzr0mu -->
<!-- timestamp: 2026-03-22T01:22:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Wrote 5 RED tests to tests/scripts/test_bridge_outbound_comment.py ✓

<!-- note-id: g7uuf6j0 -->
<!-- timestamp: 2026-03-22T01:24:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Verified all 5 tests fail RED (5 failed, 0 passed); failure reasons confirmed correct ✓

<!-- note-id: uxxktags -->
<!-- timestamp: 2026-03-22T01:24:15Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: ruff check and ruff format --check pass on test file ✓

<!-- note-id: i2gm321a -->
<!-- timestamp: 2026-03-22T01:31:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — 5 RED tests written and verified; ruff check/format pass; pytest exit 1 (all 5 fail for correct reasons)
