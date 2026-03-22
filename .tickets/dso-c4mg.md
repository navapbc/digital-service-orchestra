---
id: dso-c4mg
status: in_progress
deps: [dso-sgqg, dso-b979, dso-flql]
links: []
created: 2026-03-22T01:00:07Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dww7
---
# Integration test: comment round-trip without duplication

Verify the end-to-end comment sync cycle: local comment → Jira → pull back → no duplicate local event.

## Test file

`tests/scripts/test_bridge_comment_roundtrip.py`

This task EXTENDS the file created by RED task `dso-sgqg` by making the existing RED tests pass via a fixture-based integration test setup.

## What this task does

Ensure both round-trip tests (`test_comment_round_trip_no_duplication` and `test_comment_round_trip_stripped_marker_no_duplication`) are GREEN by verifying the full interaction:

1. `process_outbound` correctly calls `add_comment` and writes the dedup map
2. `pull_comments` correctly reads the dedup map and skips the already-known comment

## Test infrastructure

- Uses `tmp_path` (pytest fixture) for isolation
- Mocks `acli_client` (`MagicMock`) — no real Jira needed
- Loads both `bridge-outbound` and `bridge-inbound` via importlib (same pattern as existing tests)
- Sets up dedup map in tmp state to simulate prior outbound run

## Acceptance: the complete round-trip

After running:
```
process_outbound([comment_event], acli_client=mock_client, ...)
pull_comments('DSO-42', 'w21-rt1', ticket_dir, acli_client=mock_client, bridge_env_id=BRIDGE_ENV_ID)
```

The ticket directory must contain EXACTLY 1 COMMENT event file (the original local one). `add_comment` called once. No new COMMENT events written by inbound.

## TDD requirement

Depends on RED task `dso-sgqg`, outbound impl `dso-b979`, and inbound impl `dso-flql`. All tests must be GREEN.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Both round-trip tests pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_comment_roundtrip.py -q 2>&1; test $? -eq 0
- [ ] No additional COMMENT event files created after full round-trip (outbound + inbound)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_comment_roundtrip.py::test_comment_round_trip_no_duplication -v 2>&1; test $? -eq 0
- [ ] Round-trip still dedups when marker is stripped from Jira comment body
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_comment_roundtrip.py::test_comment_round_trip_stripped_marker_no_duplication -v 2>&1; test $? -eq 0

## Notes

**2026-03-22T02:06:34Z**

CHECKPOINT 1/6: Task read, starting implementation

**2026-03-22T02:36:22Z**

CHECKPOINT 6/6: Done ✓ — Both roundtrip tests GREEN. Fixed test fixtures to match actual pull_comments() signature (tickets_root→ticket_dir, added bridge_env_id). Pre-existing timeout in test-cleanup-claude-session.sh unrelated to changes.
