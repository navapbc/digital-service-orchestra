---
id: dso-mso2
status: in_progress
deps: [dso-sdb4]
links: []
created: 2026-03-21T04:56:43Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# Extend ticket-reducer.py to handle STATUS, COMMENT events and ghost/corrupt ticket directory behavior

Extend plugins/dso/scripts/ticket-reducer.py to handle the STATUS and COMMENT event types and implement ghost ticket prevention.

Implementation changes:

1. STATUS event handling (in reduce_ticket):
   elif event_type == 'STATUS':
     state['status'] = data.get('status', state['status'])
   (Current code already has this — verify it is present and update if needed)

2. COMMENT event handling (in reduce_ticket):
   elif event_type == 'COMMENT':
     state['comments'].append({
       'body': data.get('body', ''),
       'author': event.get('author'),
       'timestamp': event.get('timestamp'),
     })

3. Ghost ticket prevention — zero valid events:
   After the event loop, if state['ticket_type'] is None (no CREATE was processed):
   - Check if there were any event files at all (len(event_files) > 0)
   - If yes: return a sentinel dict {'status': 'error', 'error': 'no_valid_create_event', 'ticket_id': ticket_id}
     (not None — None is reserved for 'directory was empty')
   - This prevents the reducer from crashing on a directory with only corrupt events

4. Corrupt CREATE event detection:
   If a CREATE event is found but is missing required fields (ticket_type or title):
   - Set state['status'] = 'fsck_needed'
   - Set state['error'] = 'corrupt_create_event'
   - Stop processing further events (return early)
   This satisfies the done definition: 'ghost prevention defines behavior for corrupt CREATE: ticket is flagged as needing fsck repair rather than silently blocking all operations'

TDD Requirement: Run tests/scripts/test_ticket_reducer.py. The 6 RED tests from dso-sdb4 must pass (GREEN) after this task. Existing reducer tests must continue to pass.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] All 6 RED tests from dso-sdb4 now pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -k 'status_event or comment_event or multiple_status or multiple_comments or error_state or corrupt_create' --tb=short -q
- [ ] Pre-existing reducer tests still pass
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -k 'not status_event and not comment_event and not multiple_status and not multiple_comments and not error_state and not corrupt_create' --tb=short -q
- [ ] ticket-reducer.py handles COMMENT events and appends to state['comments'] list
  Verify: python3 -c "import importlib.util, json, pathlib, tempfile; spec=importlib.util.spec_from_file_location('r','$(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-reducer.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); d=pathlib.Path(tempfile.mkdtemp()); t=d/'tkt-test'; t.mkdir(); (t/'1-aaa-CREATE.json').write_text(json.dumps({'timestamp':1,'uuid':'aaa','event_type':'CREATE','env_id':'x','author':'a','data':{'ticket_type':'task','title':'T','parent_id':''}})); (t/'2-bbb-COMMENT.json').write_text(json.dumps({'timestamp':2,'uuid':'bbb','event_type':'COMMENT','env_id':'x','author':'a','data':{'body':'hello'}})); s=m.reduce_ticket(t); assert s['comments']==[{'body':'hello','author':'a','timestamp':2}], s"
- [ ] ticket-reducer.py returns error-state dict (not None) for ticket dirs with only corrupt events
  Verify: python3 -c "import importlib.util, pathlib, tempfile; spec=importlib.util.spec_from_file_location('r','$(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-reducer.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); d=pathlib.Path(tempfile.mkdtemp()); t=d/'tkt-ghost'; t.mkdir(); (t/'1-aaa-STATUS.json').write_text('not json'); s=m.reduce_ticket(t); assert s is not None and s.get('status')=='error', s"
- [ ] [Gap AC amendment] ticket-reducer.py main() exits non-zero for error-state dicts (backward compat with ticket-show.sh)
  Verify: python3 -c "
import subprocess, sys, json, pathlib, tempfile, os
repo=subprocess.check_output(['git','rev-parse','--show-toplevel']).decode().strip()
d=pathlib.Path(tempfile.mkdtemp()); t=d/'tkt-ghost'; t.mkdir()
(t/'1-aaa-STATUS.json').write_text('not json')
r=subprocess.run([sys.executable,f'{repo}/plugins/dso/scripts/ticket-reducer.py',str(t)],capture_output=True)
assert r.returncode != 0, f'main() must exit non-zero for error-state; got 0 with output: {r.stdout}'
"

## Notes

**2026-03-21T05:28:35Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T05:28:43Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T05:28:54Z**

CHECKPOINT 3/6: Tests written (pre-existing RED tests) ✓ — 5 failing: conflict detection, COMMENT handling (x2), ghost ticket error state, corrupt CREATE fsck_needed

**2026-03-21T05:29:33Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T05:30:15Z**

CHECKPOINT 5/6: All 11 tests GREEN, ruff check + format pass ✓

**2026-03-21T05:30:46Z**

CHECKPOINT 6/6: All AC verified ✓ — 11/11 tests GREEN, all inline AC checks pass, ruff clean
