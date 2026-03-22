---
id: dso-c9p5
status: closed
deps: []
links: []
created: 2026-03-22T00:58:17Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dww7
---
# RED: Write failing tests for ACLI comment operations (add_comment, get_comments)

Write failing tests for two new functions to be added to `plugins/dso/scripts/acli-integration.py`:
- `add_comment(jira_key, body, acli_cmd=None) -> dict` — posts a comment to a Jira issue via ACLI `addComment` action; returns dict with at minimum `{id: str, body: str}`
- `get_comments(jira_key, acli_cmd=None) -> list[dict]` — retrieves all comments on a Jira issue via ACLI `getComments` action; each dict has at minimum `{id: str, body: str}`

## Test file

`tests/scripts/test_acli_integration_comments.py`

## Tests to write (all must fail RED before implementation)

- `test_add_comment_calls_acli_addComment_action` — mock ACLI subprocess; assert `--action addComment` and `--issue <jira_key>` are passed; assert `--comment <body>` is passed; returns dict with `id` and `body`
- `test_add_comment_with_marker_preserves_full_body` — body includes `<!-- origin-uuid: ... -->` marker; assert the full body (marker included) is passed to ACLI unchanged
- `test_add_comment_retries_on_transient_failure` — first ACLI call raises CalledProcessError (non-401); assert second call succeeds and result is returned
- `test_add_comment_fast_aborts_on_auth_failure` — ACLI returns exit code 401; assert CalledProcessError is raised immediately (no retry)
- `test_get_comments_calls_acli_getComments_action` — mock ACLI subprocess; assert `--action getComments` and `--issue <jira_key>` are passed; returns list of dicts with `id` and `body`
- `test_get_comments_returns_empty_list_when_no_comments` — ACLI returns JSON empty array; function returns empty list

## TDD requirement

Write all 6 tests FIRST. Run `python3 -m pytest tests/scripts/test_acli_integration_comments.py` and confirm all fail (ImportError or AttributeError on missing functions). Do NOT implement the functions until the RED task is verified.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file `tests/scripts/test_acli_integration_comments.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_acli_integration_comments.py
- [ ] Test file contains all 6 required test functions
  Verify: cd $(git rev-parse --show-toplevel) && grep -c 'def test_' tests/scripts/test_acli_integration_comments.py | awk '{exit ($1 < 6)}'
- [ ] All 6 tests FAIL (RED) before implementation — non-zero exit
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_acli_integration_comments.py 2>&1; test $? -ne 0

## Notes

**2026-03-22T01:21:23Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T01:21:23Z**

CHECKPOINT 2/6: Read acli-integration.py and test_acli_integration.py ✓

**2026-03-22T01:22:07Z**

CHECKPOINT 3/6: RED failing tests written at tests/scripts/test_acli_integration_comments.py ✓

**2026-03-22T01:23:05Z**

CHECKPOINT 4/6: All 6 tests fail RED with AttributeError (missing add_comment/get_comments) ✓

**2026-03-22T01:23:06Z**

CHECKPOINT 5/6: ruff check + ruff format --check both pass ✓

**2026-03-22T01:23:06Z**

CHECKPOINT 6/6: Done ✓ — AC verified: file exists, 6 test functions, all fail RED (exit 1)
