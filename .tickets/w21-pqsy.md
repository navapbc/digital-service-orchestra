---
id: w21-pqsy
status: in_progress
deps: [w21-81hy]
links: []
created: 2026-03-22T00:58:50Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-gykt
---
# Implement bridge-inbound.py core: fetch_jira_changes, normalize_timestamps, write_create_events

Implement the core functions of plugins/dso/scripts/bridge-inbound.py. This task implements the three functions tested by the RED task (w21-81hy). The script is inert until process_inbound() is added in a later task; all tests pass GREEN after this task.

FILE: plugins/dso/scripts/bridge-inbound.py (new file)

IMPLEMENTATION REQUIREMENTS:

1. fetch_jira_changes(last_pull_ts, overlap_buffer_minutes, acli_client, project=None) -> list[dict]
   - Computes buffered_ts = last_pull_ts (UTC epoch int) minus overlap_buffer_minutes * 60
   - Formats buffered_ts as Jira JQL datetime string (local-time per Jira service account = UTC since health check ensures UTC)
   - Calls acli_client.search_issues(jql, start_at=0, max_results=100) iterating pages until no results remain
   - Returns flat list of all Jira issue dicts
   - NOTE: pagination is stub in this task (single page); full pagination added in T4

2. normalize_timestamps(issue: dict) -> dict
   - For each of created, updated, resolutiondate in the issue dict: parse ISO 8601 string with stdlib datetime.fromisoformat() or strptime with %z (NO external dateutil dependency — stdlib only)
   - Convert to UTC epoch int via .timestamp()
   - Fields absent or None are left unchanged (no KeyError, no set to 0)
   - Returns modified issue dict (in-place modification acceptable)

3. write_create_events(issues: list[dict], tickets_root: Path, bridge_env_id: str, run_id: str = '') -> list[str]
   - For each Jira issue: checks if .tickets-tracker/<jira_key_as_local_id> already has a SYNC event (idempotency guard)
   - If no SYNC event: generates local ticket ID using pattern jira-<jira_key_lowercase> or extracts from SYNC mapping
   - Writes CREATE event file: <epoch>-<uuid>-CREATE.json with event_type=CREATE, env_id=bridge_env_id, data={normalized Jira fields}
   - Returns list of ticket_ids for which CREATE events were written

CONSTRAINTS:
- No external dependencies (stdlib only: datetime, json, os, pathlib, subprocess, time, uuid, importlib)
- Module loading pattern: _load_module_from_path() matching bridge-outbound.py convention
- ACLI client injectable (default: loads acli-integration.py via importlib)
- No conditional logic for status/type mapping in this task (added in next task)

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] python3 -m pytest tests/scripts/test_bridge_inbound.py passes
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_inbound.py -v --tb=short
- [ ] bridge-inbound.py exists and is importable
  Verify: python3 -c "import importlib.util; spec=importlib.util.spec_from_file_location('b', '$(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-inbound.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)"
- [ ] No external imports (only stdlib modules)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -c "import ast, sys; tree=ast.parse(open('plugins/dso/scripts/bridge-inbound.py').read()); imports=[n.names[0].name.split('.')[0] if isinstance(n,ast.Import) else n.module.split('.')[0] for n in ast.walk(tree) if isinstance(n,(ast.Import,ast.ImportFrom)) and getattr(n,'module',None) is not None or isinstance(n,ast.Import)]; bad=[i for i in imports if i not in ('datetime','json','os','pathlib','subprocess','time','uuid','importlib','re','sys','typing','__future__','types')]; sys.exit(1 if bad else 0)"
- [ ] ruff check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/bridge-inbound.py
- [ ] ruff format --check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/bridge-inbound.py


## Notes

**2026-03-22T01:37:19Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T01:37:25Z**

CHECKPOINT 2/6: Code read — tests, outbound pattern, acli-integration ✓

**2026-03-22T01:38:14Z**

CHECKPOINT 3/6: bridge-inbound.py implemented with fetch_jira_changes, normalize_timestamps, write_create_events ✓

**2026-03-22T01:39:08Z**

CHECKPOINT 4/6: All 6 tests GREEN, ruff check+format clean ✓

**2026-03-22T01:39:08Z**

CHECKPOINT 5/6: AC self-check — importable ✓, stdlib-only ✓, ruff check ✓, ruff format ✓, pytest 6/6 ✓

**2026-03-22T01:39:08Z**

CHECKPOINT 6/6: Done ✓
