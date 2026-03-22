---
id: dso-b979
status: closed
deps: [dso-olb0, dso-yx0j]
links: []
created: 2026-03-22T00:59:01Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dww7
---
# Implement COMMENT event handling in bridge-outbound.py (outbound comment push)

Add COMMENT event handling to `process_outbound` in `plugins/dso/scripts/bridge-outbound.py`.

## Changes to bridge-outbound.py

### 1. Add dedup map helpers

Add two private functions:

```python
def _read_dedup_map(ticket_dir: Path) -> dict[str, Any]:
    """Read .jira-comment-map from ticket_dir. Returns empty dict on missing/corrupt."""

def _write_dedup_map(ticket_dir: Path, dedup_map: dict[str, Any]) -> None:
    """Write .jira-comment-map atomically (write temp, rename)."""
```

The map file is `.tickets-tracker/<ticket-id>/.jira-comment-map` — a JSON object with:
- `uuid_to_jira_id`: {event_uuid -> jira_comment_id}
- `jira_id_to_uuid`: {jira_comment_id -> event_uuid}

### 2. Add UUID marker embed helper

```python
def _embed_uuid_marker(body: str, event_uuid: str) -> str:
    """Append <!-- origin-uuid: {event_uuid} --> as a new line at end of body."""
```

### 3. Add COMMENT case to process_outbound loop

After the STATUS elif block, add:

```python
elif event_type == "COMMENT":
    # Get Jira key from SYNC event
    # Read event file to get uuid and body
    # Check dedup map: if uuid already in uuid_to_jira_id, skip (idempotent)
    # Echo prevention: bridge-originated events already filtered by filter_bridge_events
    # Embed UUID marker in body
    # Call acli_client.add_comment(jira_key, body_with_marker)
    # Update dedup map with returned jira_comment_id
```

## Key invariants

- Only push COMMENT events for tickets that have an existing SYNC event (mapped to Jira)
- Idempotency: if `event_uuid` already in `uuid_to_jira_id`, skip
- Bridge-originated COMMENT events are already filtered by `filter_bridge_events` (echo prevention at filter level, not comment level)
- Dedup map written atomically: write to temp file, then `os.replace` to target

## TDD requirement

Depends on RED task `dso-olb0`. All 5 tests in `tests/scripts/test_bridge_outbound_comment.py` must be GREEN after this implementation.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] All 5 tests in `tests/scripts/test_bridge_outbound_comment.py` pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_comment.py -q 2>&1; test $? -eq 0
- [ ] `_embed_uuid_marker` helper function exists in `bridge-outbound.py`
  Verify: grep -q 'def _embed_uuid_marker' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py
- [ ] `_read_dedup_map` and `_write_dedup_map` helpers exist in `bridge-outbound.py`
  Verify: grep -q 'def _read_dedup_map' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py && grep -q 'def _write_dedup_map' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py
- [ ] COMMENT case handled in `process_outbound` loop
  Verify: grep -q 'COMMENT' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py
- [ ] Dedup map file `.jira-comment-map` is written atomically (os.replace or equivalent)
  Verify: grep -q 'os.replace\|os\.rename\|rename' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py
- [ ] Outbound bridge skips COMMENT events with no existing SYNC mapping
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_comment.py::test_outbound_push_comment_skips_ticket_without_sync -q 2>&1; test $? -eq 0

## Notes

**2026-03-22T01:45:43Z**

CHECKPOINT 1/6: Read task description and all source files

**2026-03-22T01:53:09Z**

CHECKPOINT 6/6: Done — all 5 comment tests GREEN, all AC verified, pre-existing failures in test_bridge_inbound.py and test_bridge_comment_roundtrip.py are unrelated (RED tests for other stories)
