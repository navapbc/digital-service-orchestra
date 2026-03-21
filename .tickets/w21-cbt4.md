---
id: w21-cbt4
status: open
deps: [w21-vz2h, w21-cjso]
links: []
created: 2026-03-21T07:12:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-q0nn
---
# INTEG: Verify cache-compaction interaction — warm cache before compaction returns correct state after

Integration test verifying that the compiled-state cache (from w21-f8tg) correctly handles compaction: a warm cache before compaction returns correct state after compaction runs.

## Why This Task Is Needed
The cache invalidation in w21-f8tg uses directory listing hash (filename + file size). Compaction deletes event files and adds a SNAPSHOT. This changes both the file count and the filenames, guaranteeing a cache miss. This task verifies that guarantee holds end-to-end in an integrated scenario.

## TDD Requirement
Write the test BEFORE verifying it passes (it may already be GREEN due to w21-f8tg cache implementation — but the test must exist).
Confirm test exists and passes:
  cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -k 'integ_cache_compaction' --tb=short -q

If the test already passes after reducer SNAPSHOT implementation (w21-vz2h), note it as GREEN from day 1 (no separate RED phase needed — the cache logic was already deletion-aware per w21-f8tg done definition).

## Implementation Steps

File: tests/scripts/test_ticket_reducer.py (add new integration test)

### test_integ_cache_warm_before_compaction_returns_correct_state_after

```python
@pytest.mark.integration
@pytest.mark.scripts
def test_integ_cache_warm_before_compaction_returns_correct_state_after(tmp_path, reducer):
    ticket_dir = tmp_path / 'tkt-compact-cache'
    ticket_dir.mkdir()

    # Write a CREATE + 3 STATUS events
    _write_event(ticket_dir, 1742605200, _UUID, 'CREATE', {'ticket_type': 'task', 'title': 'Cache test', 'parent_id': None})
    _write_event(ticket_dir, 1742605201, _UUID2, 'STATUS', {'status': 'in_progress', 'current_status': None})
    _write_event(ticket_dir, 1742605202, _UUID3, 'STATUS', {'status': 'closed', 'current_status': None})
    _write_event(ticket_dir, 1742605203, 'aaaabbbb-aaaa-bbbb-cccc-ddddeeeeFFFF', 'STATUS', {'status': 'open', 'current_status': None})

    # Warm the cache
    state_before = reducer.reduce_ticket(ticket_dir)
    assert state_before['status'] == 'open'

    # Simulate compaction: delete all 4 event files, write SNAPSHOT
    for f in ticket_dir.glob('*.json'):
        if f.name != '.cache.json':
            f.unlink()

    snapshot_payload = {
        'timestamp': 1742605210,
        'uuid': 'snapshot-uuid-1234',
        'event_type': 'SNAPSHOT',
        'env_id': '00000000-0000-4000-8000-000000000001',
        'author': 'Alice',
        'data': {
            'compiled_state': {
                'ticket_id': 'tkt-compact-cache',
                'ticket_type': 'task',
                'title': 'Cache test',
                'status': 'closed',  # compacted final state
                'author': 'Alice',
                'created_at': 1742605200,
                'env_id': '00000000-0000-4000-8000-000000000001',
                'parent_id': None,
                'comments': [],
                'deps': [],
            },
            'source_event_uuids': [_UUID, _UUID2, _UUID3, 'aaaabbbb-aaaa-bbbb-cccc-ddddeeeeFFFF']
        }
    }
    (ticket_dir / '1742605210-snapshot-uuid-1234-SNAPSHOT.json').write_text(json.dumps(snapshot_payload))

    # After compaction — cache must miss (file count changed) and return SNAPSHOT state
    state_after = reducer.reduce_ticket(ticket_dir)
    assert state_after is not None
    assert state_after['status'] == 'closed', f'Expected closed (SNAPSHOT state), got {state_after["status"]}'
    assert state_after['title'] == 'Cache test'
```

## Note on E2E Coverage
This is a unit-level integration test (no git commit involved). The full E2E test (w21-yvhg) covers the git-committed flow.

## Files to Edit
tests/scripts/test_ticket_reducer.py

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] test_integ_cache_warm_before_compaction_returns_correct_state_after exists in test_ticket_reducer.py
  Verify: grep -q 'test_integ_cache_warm_before_compaction_returns_correct_state_after' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py
- [ ] Integration test passes GREEN
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -k 'integ_cache_compaction' --tb=short -q 2>&1 | grep -q 'passed'

