---
id: dso-dpvo
status: in_progress
deps: []
links: []
created: 2026-03-22T00:59:19Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dww7
---
# RED: Write failing tests for inbound comment pull and dedup in bridge-inbound.py

Write failing tests for `plugins/dso/scripts/bridge-inbound.py` — a new file implementing inbound Jira comment pull with dual-key dedup.

## Test file

`tests/scripts/test_bridge_inbound_comment.py`

## Expected bridge-inbound.py public API

```python
def pull_comments(
    jira_key: str,
    ticket_id: str,
    ticket_dir: Path,
    acli_client: Any,
    bridge_env_id: str,
) -> list[dict[str, Any]]:
    """Pull Jira comments for a ticket and write new COMMENT events locally.
    Returns list of written COMMENT event dicts.
    """
```

## Tests to write (all must fail RED before implementation)

- `test_pull_comments_writes_comment_event_for_new_jira_comment` — given a Jira comment `{id: 'j-1', body: 'Hello'}` not in dedup map, `pull_comments` writes a COMMENT event file in `ticket_dir` with `event_type='COMMENT'`, `env_id=bridge_env_id`, `data.body='Hello'`
- `test_pull_comments_skips_comment_already_in_dedup_map_by_jira_id` — given Jira comment ID `j-1` already in `jira_id_to_uuid` map, no COMMENT event is written (primary dedup key)
- `test_pull_comments_skips_local_origin_comment_with_uuid_marker` — given Jira comment body containing `<!-- origin-uuid: {some_uuid} -->` where that UUID is in `uuid_to_jira_id` map, no COMMENT event is written (secondary dedup via UUID)
- `test_pull_comments_skips_local_origin_comment_stripped_marker_via_jira_id` — given Jira comment whose marker was stripped (body has no marker) but jira_id `j-99` is in dedup map, no event is written (primary key survives stripping)
- `test_pull_comments_updates_dedup_map_after_writing_event` — after writing a new COMMENT event, the dedup map is updated with `jira_id_to_uuid[jira_comment_id] = new_event_uuid` and `uuid_to_jira_id[new_event_uuid] = jira_comment_id`
- `test_pull_comments_returns_empty_list_when_no_new_comments` — all Jira comments are in dedup map; returns empty list

## TDD requirement

Write all 6 tests FIRST. Run `python3 -m pytest tests/scripts/test_bridge_inbound_comment.py` and confirm all fail with ImportError (file not found). Do NOT create bridge-inbound.py until RED is verified.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file `tests/scripts/test_bridge_inbound_comment.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_inbound_comment.py
- [ ] Test file contains all 6 required test functions
  Verify: cd $(git rev-parse --show-toplevel) && grep -c 'def test_' tests/scripts/test_bridge_inbound_comment.py | awk '{exit ($1 < 6)}'
- [ ] All 6 tests FAIL (RED) before implementation — non-zero exit expected (bridge-inbound.py does not exist yet)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_inbound_comment.py 2>&1; test $? -ne 0

## Notes

<!-- note-id: mai1si3l -->
<!-- timestamp: 2026-03-22T01:21:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: hkkk94tj -->
<!-- timestamp: 2026-03-22T01:22:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Reference files read — contract, bridge-outbound.py, test_bridge_outbound.py conventions noted ✓

<!-- note-id: i0bdn68c -->
<!-- timestamp: 2026-03-22T01:22:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: RED tests written to tests/scripts/test_bridge_inbound_comment.py — 6 test functions covering all AC scenarios ✓

<!-- note-id: 0uxhypz3 -->
<!-- timestamp: 2026-03-22T01:23:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — 6 RED tests written, ruff clean, all 6 fail with expected ImportError (bridge-inbound.py absent)
