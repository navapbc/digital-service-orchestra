---
id: dso-yx0j
status: closed
deps: [dso-c9p5]
links: []
created: 2026-03-22T00:58:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dww7
---
# Implement add_comment and get_comments in acli-integration.py

Add two new public functions to `plugins/dso/scripts/acli-integration.py`:

## `add_comment(jira_key, body, *, acli_cmd=None) -> dict`

Calls ACLI `addComment` action to post a comment to a Jira issue.

```
cmd = ["--action", "addComment", "--issue", jira_key, "--comment", body]
```

Returns dict from ACLI JSON output (must contain `id` and `body` at minimum).
Uses `_run_acli` for retry + exponential backoff (same as other functions).
Fast-aborts on 401.

## `get_comments(jira_key, *, acli_cmd=None) -> list[dict]`

Calls ACLI `getComments` action to retrieve all comments on a Jira issue.

```
cmd = ["--action", "getComments", "--issue", jira_key]
```

Returns list of dicts parsed from ACLI JSON output. Each dict must contain `id` (str) and `body` (str). Returns empty list if ACLI returns empty array.
Uses `_run_acli` for retry + exponential backoff.

## Implementation notes

- Both functions follow the exact same pattern as `update_issue` and `get_issue` — use `_run_acli` internally.
- No new dependencies — stdlib only.
- Place after `get_issue` in the file (alphabetical order within public API section).

## TDD requirement

Depends on RED task `dso-c9p5`. All 6 tests in `tests/scripts/test_acli_integration_comments.py` must be GREEN after this implementation.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `add_comment` function exists in `plugins/dso/scripts/acli-integration.py`
  Verify: grep -q 'def add_comment' $(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py
- [ ] `get_comments` function exists in `plugins/dso/scripts/acli-integration.py`
  Verify: grep -q 'def get_comments' $(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py
- [ ] All 6 tests in `tests/scripts/test_acli_integration_comments.py` pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_acli_integration_comments.py -q 2>&1; test $? -eq 0
- [ ] `add_comment` uses `_run_acli` with `--action addComment` and `--issue` and `--comment` args
  Verify: grep -A 10 'def add_comment' $(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py | grep -q 'addComment'
- [ ] `get_comments` uses `_run_acli` with `--action getComments` and `--issue` args
  Verify: grep -A 10 'def get_comments' $(git rev-parse --show-toplevel)/plugins/dso/scripts/acli-integration.py | grep -q 'getComments'

## Notes

**2026-03-22T01:37:18Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T01:37:24Z**

CHECKPOINT 2/6: Relevant code read — tests (6 RED) + existing acli-integration.py ✓

**2026-03-22T01:37:50Z**

CHECKPOINT 3/6: add_comment implemented ✓

**2026-03-22T01:37:52Z**

CHECKPOINT 4/6: get_comments implemented ✓

**2026-03-22T01:38:12Z**

CHECKPOINT 5/6: All AC verified — 6/6 tests GREEN, ruff check+format clean ✓

**2026-03-22T01:38:13Z**

CHECKPOINT 6/6: Done ✓
