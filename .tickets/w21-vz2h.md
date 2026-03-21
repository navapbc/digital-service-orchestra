---
id: w21-vz2h
status: closed
deps: [w21-6qw0]
links: []
created: 2026-03-21T07:11:11Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-q0nn
---
# IMPL: Extend ticket-reducer to handle SNAPSHOT events and source_event_uuids deduplication

Implement SNAPSHOT event handling in plugins/dso/scripts/ticket-reducer.py so that the RED tests from the prerequisite task pass GREEN.

## TDD Requirement
Depends on: RED tests for SNAPSHOT reducer (w21-6qw0). Those tests must be RED before starting.
After implementation, confirm GREEN:
  cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -k 'snapshot or cache_invalidation_after_compaction' --tb=short -q
Expected: all 5 snapshot tests pass.

## Implementation Steps

File: plugins/dso/scripts/ticket-reducer.py

### 1. Add SNAPSHOT event branch to the reduce_ticket() event loop

After the existing event_type checks (CREATE, STATUS, COMMENT), add:

```python
elif event_type == 'SNAPSHOT':
    compiled_state = data.get('compiled_state', {})
    source_event_uuids = set(data.get('source_event_uuids', []))
    # Restore compiled state from snapshot
    for key, value in compiled_state.items():
        state[key] = value
    # Store source_event_uuids for deduplication of subsequent events
    state['_snapshot_source_uuids'] = source_event_uuids
```

### 2. Add deduplication guard for post-snapshot events

At the top of the event loop iteration (before event_type dispatch), add:

```python
event_uuid = event.get('uuid', '')
# Skip events whose UUID was included in the most recent SNAPSHOT
if event_uuid and event_uuid in state.get('_snapshot_source_uuids', set()):
    continue
```

### 3. Clean up internal tracking key from returned state

Before the cache write and return, remove the internal key:

```python
state.pop('_snapshot_source_uuids', None)
```

### 4. Handle SNAPSHOT-only tickets (no CREATE event present)

The existing guard checks if state['ticket_type'] is None after the loop. For SNAPSHOT-sourced tickets, the compiled_state contains ticket_type. Update the guard:

After the SNAPSHOT branch restores state from compiled_state, ensure ticket_id and ticket_type are populated from compiled_state (they already will be if compiled_state contains them). The guard should remain: if state['ticket_type'] is None after all events processed, return None (unless valid_event_count == 0, which is ghost-ticket error).

## Constraints
- No new imports required — uses only existing dict operations and set()
- The _snapshot_source_uuids key must NOT appear in the cached or returned state (pop before return)
- valid_event_count must count SNAPSHOT events as valid (they are parseable JSON events)
- Ghost-ticket error logic unchanged for dirs with no parseable events

## File to Edit
plugins/dso/scripts/ticket-reducer.py

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] All 5 SNAPSHOT reducer tests pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -k 'snapshot or cache_invalidation_after_compaction' --tb=short -q 2>&1 | grep -E '5 passed|all passed'
- [ ] _snapshot_source_uuids key does NOT appear in reduce_ticket() return value
  Verify: cd $(git rev-parse --show-toplevel) && python3 -c "
import importlib.util, json, tempfile, pathlib
spec = importlib.util.spec_from_file_location('r', 'plugins/dso/scripts/ticket-reducer.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
td = pathlib.Path(tempfile.mkdtemp()) / 'tkt-x'; td.mkdir()
(td / '1742605200-aaaa-SNAPSHOT.json').write_text(json.dumps({'timestamp':1742605200,'uuid':'aaaa','event_type':'SNAPSHOT','env_id':'e','author':'a','data':{'compiled_state':{'ticket_id':'x','ticket_type':'task','title':'T','status':'open','author':'a','created_at':1742605200,'env_id':'e','parent_id':None,'comments':[],'deps':[]},'source_event_uuids':[]}}))
state = m.reduce_ticket(td)
assert '_snapshot_source_uuids' not in state, 'internal key leaked into state'
print('PASS')
"
- [ ] All existing ticket_reducer tests continue to pass (no regression)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py --tb=short -q 2>&1 | tail -5


## Notes

**2026-03-21T07:35:05Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T07:36:04Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T07:36:04Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T07:46:27Z**

CHECKPOINT 6/6: Done ✓ — SNAPSHOT event handling in reducer. 22 tests GREEN.
