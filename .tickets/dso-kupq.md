---
id: dso-kupq
status: in_progress
deps: []
links: []
created: 2026-03-21T23:01:11Z
type: task
priority: 3
assignee: Joe Oakhart
parent: w21-bwfw
---
# Deduplicate to_llm() function between ticket-show.sh and ticket-list.sh

## Description
The `to_llm()` Python function (KEY_MAP, OMIT_KEYS, COMMENT_KEY_MAP, shorten_comment, shorten_dep) is copy-pasted between `plugins/dso/scripts/ticket-show.sh` and `plugins/dso/scripts/ticket-list.sh`. Extract the shared logic into a common Python module that both scripts import.

### Files to modify
- `plugins/dso/scripts/ticket-llm-format.py` (new — shared module)
- `plugins/dso/scripts/ticket-show.sh` (import shared module)
- `plugins/dso/scripts/ticket-list.sh` (import shared module)
- `tests/scripts/test-ticket-show.sh` (verify existing tests still pass)
- `tests/scripts/test-ticket-list.sh` (verify existing tests still pass)

## ACCEPTANCE CRITERIA

- [ ] A shared Python module exists at `plugins/dso/scripts/ticket-llm-format.py`
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-llm-format.py
- [ ] Both ticket-show.sh and ticket-list.sh import from the shared module instead of duplicating
  Verify: grep -c "ticket-llm-format" $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-show.sh $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-list.sh | grep -v ':0$'
- [ ] Existing tests pass unchanged
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-show.sh && bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-list.sh

## Notes

**2026-03-21T23:10:33Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T23:10:46Z**

CHECKPOINT 2/6: Code patterns understood ✓ — ticket-show.sh has inline Python for to_llm() without named function, ticket-list.sh has named to_llm() function. Both share identical KEY_MAP, OMIT_KEYS, COMMENT_KEY_MAP, DEP_KEY_MAP, shorten_comment(), shorten_dep() logic.

**2026-03-21T23:11:04Z**

CHECKPOINT 3/6: Tests written ✓ — existing tests already cover all behavior (9 pass ticket-show, 16 pass ticket-list). No new tests needed; tests will continue passing after refactor.

**2026-03-21T23:12:09Z**

CHECKPOINT 4/6: Implementation complete ✓ — Created ticket-llm-format.py with shared to_llm(), shorten_comment(), shorten_dep(). Updated ticket-show.sh and ticket-list.sh to import via importlib.util.spec_from_file_location.

**2026-03-21T23:12:29Z**

CHECKPOINT 5/6: Validation passed ✓ — ruff: clean, test-ticket-show.sh: 9/9, test-ticket-list.sh: 16/16. All 3 AC criteria pass.

**2026-03-21T23:12:30Z**

CHECKPOINT 6/6: Done ✓
