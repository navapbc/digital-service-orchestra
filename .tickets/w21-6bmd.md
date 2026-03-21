---
id: w21-6bmd
status: open
deps: [w21-y51q]
links: []
created: 2026-03-21T00:54:46Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ablv
---
# Implement ticket-reducer.py (python3 event reducer with error-tolerant JSON parsing)


## Description

Implement `plugins/dso/scripts/ticket-reducer.py` — the Python3 reducer that compiles event files to current ticket state.

### Module interface:
```python
def reduce_ticket(ticket_dir_path: str) -> dict | None:
    """
    Compile all events in ticket_dir_path to current ticket state.
    Returns dict of current state, or None if no CREATE event found.
    """
```

### Implementation specification:
1. List all `*.json` files in `ticket_dir_path`
2. Sort files by filename (lexicographic) — this enforces the ordering contract from w21-mtvm:
   - `sorted(glob.glob(os.path.join(ticket_dir_path, '*.json')))` gives correct chronological order
3. For each file, attempt `json.load(f, encoding='utf-8')` in a try/except:
   - On `json.JSONDecodeError`: print a warning to stderr (`print(f"WARNING: skipping corrupt event {filepath}", file=sys.stderr)`) and continue
   - Do NOT raise; skip the corrupt file
4. Reducer logic (fold events into state):
   - Initial state: `{"ticket_id": None, "ticket_type": None, "title": None, "status": "open", "author": None, "created_at": None, "env_id": None, "parent_id": None, "comments": [], "deps": []}`
   - CREATE: set ticket_id, ticket_type, title, author, created_at, env_id, parent_id
   - STATUS: set status
   - (COMMENT, LINK handled in w21-o72z — reducer must not crash on unknown types; ignore them)
5. After reducing, if `state["ticket_type"]` is None (no CREATE event processed), return None
6. Return the state dict

### CLI interface (for `ticket show` to call):
```
python3 ticket-reducer.py <ticket_dir_path>
```
- Prints JSON of compiled state to stdout (json.dumps, ensure_ascii=False)
- Exits 0 on success, 1 if ticket not found (no CREATE event)
- All file I/O uses `open(path, encoding='utf-8')`

### Constraints:
- stdlib only (json, os, glob, sys) — no new dependencies
- All JSON I/O via json.load/json.dumps — never string interpolation
- Error-tolerant: corrupt files are skipped with warning, not fatal

## TDD Requirement
GREEN: After implementation, `python3 -m pytest tests/scripts/test_ticket_reducer.py` must return exit 0.
Depends on RED task w21-y51q which defines the failing tests.

## Acceptance Criteria
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/run-all.sh`
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `plugins/dso/scripts/ticket-reducer.py` exists
  Verify: `test -f $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-reducer.py`
- [ ] `reduce_ticket` function is importable from `ticket-reducer`
  Verify: `cd $(git rev-parse --show-toplevel)/plugins/dso/scripts && python3 -c "from ticket_reducer import reduce_ticket" 2>/dev/null || python3 -c "import importlib.util; s=importlib.util.spec_from_file_location('r','ticket-reducer.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); assert hasattr(m,'reduce_ticket')"`
- [ ] Reducer test suite passes (all 5 assertions green)
  Verify: `cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_reducer.py -v`
- [ ] No new runtime dependencies added beyond stdlib
  Verify: `python3 -c "import json, os, glob, sys"` (no third-party imports in ticket-reducer.py)
