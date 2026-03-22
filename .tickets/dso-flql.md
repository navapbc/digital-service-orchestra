---
id: dso-flql
status: in_progress
deps: [dso-dpvo, dso-yx0j]
links: []
created: 2026-03-22T00:59:37Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dww7
---
# Implement bridge-inbound.py: inbound Jira comment pull with dual-key dedup

Create `plugins/dso/scripts/bridge-inbound.py` implementing inbound Jira comment pull with dual-key dedup (Jira comment ID primary, UUID marker secondary).

## File to create

`plugins/dso/scripts/bridge-inbound.py`

## Module structure

```python
#!/usr/bin/env python3
"""Inbound bridge: pull Jira comments into local ticket events.

Dual-key dedup: Jira comment ID (primary) + UUID marker (secondary).
No external dependencies — stdlib only.
"""
```

## Public API

### `pull_comments(jira_key, ticket_id, ticket_dir, acli_client, bridge_env_id) -> list[dict]`

1. Call `acli_client.get_comments(jira_key)` → list of `{id, body}` dicts
2. Read dedup map from `ticket_dir / '.jira-comment-map'` (via shared helper pattern from bridge-outbound.py)
3. For each Jira comment:
   a. **Primary check**: if `jira_comment_id` in `jira_id_to_uuid` → skip (already processed)
   b. **Secondary check**: extract UUID from `<!-- origin-uuid: {uuid} -->` in body; if UUID found AND in `uuid_to_jira_id` → skip (locally originated)
   c. **Write event**: create COMMENT event file in `ticket_dir` with:
      - `event_type: 'COMMENT'`
      - `env_id: bridge_env_id`
      - `author: 'bridge'`
      - `data.body: body_with_marker_stripped` (strip `<!-- origin-uuid: ... -->` line if present)
      - `uuid: new UUID4`
      - `timestamp: int(time.time())`
   d. Update dedup map: `jira_id_to_uuid[jira_comment_id] = new_uuid` and `uuid_to_jira_id[new_uuid] = jira_comment_id`
4. Write updated dedup map atomically
5. Return list of written event dicts

## Implementation notes

- **REQUIRED**: Define dedup map helpers (`_read_dedup_map`, `_write_dedup_map`) as private functions INLINE in bridge-inbound.py. Do NOT import them from bridge-outbound.py via importlib. Reason: cross-module internal function import creates an undeclared, untested dependency; if bridge-outbound.py renames or removes the helper, bridge-inbound.py breaks silently. Both modules independently implement the same simple JSON read/write logic against the same schema (defined in `plugins/dso/docs/contracts/comment-sync-dedup.md`).
- The dedup map schema is authoritative in `comment-sync-dedup.md` — both implementations must conform to it.
- Marker extraction regex: `re.search(r'<!-- origin-uuid: ([0-9a-f-]+) -->', body)`
- Body stored in COMMENT event has marker stripped (the marker is a bridge transport artifact, not user content)
- File naming: `{timestamp}-{uuid}-COMMENT.json` following ticket-event-format.md convention

## TDD requirement

Depends on RED task `dso-dpvo`. All 6 tests in `tests/scripts/test_bridge_inbound_comment.py` must be GREEN after this implementation.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `plugins/dso/scripts/bridge-inbound.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-inbound.py
- [ ] `pull_comments` function is defined in `bridge-inbound.py`
  Verify: grep -q 'def pull_comments' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-inbound.py
- [ ] All 6 tests in `tests/scripts/test_bridge_inbound_comment.py` pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_inbound_comment.py -q 2>&1; test $? -eq 0
- [ ] `pull_comments` strips UUID marker from body before writing local COMMENT event
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_inbound_comment.py::test_pull_comments_writes_comment_event_for_new_jira_comment -q 2>&1; test $? -eq 0
- [ ] Primary dedup (Jira comment ID) works when marker is stripped
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_inbound_comment.py::test_pull_comments_skips_local_origin_comment_stripped_marker_via_jira_id -q 2>&1; test $? -eq 0
- [ ] Dedup map is updated after writing new COMMENT event
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_inbound_comment.py::test_pull_comments_updates_dedup_map_after_writing_event -q 2>&1; test $? -eq 0

## Notes

**2026-03-22T01:45:46Z**

CHECKPOINT 1/6: Task read ✓

**2026-03-22T01:46:48Z**

CHECKPOINT 6/6: Done ✓
