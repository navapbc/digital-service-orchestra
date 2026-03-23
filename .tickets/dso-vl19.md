---
id: dso-vl19
status: open
deps: [dso-qki2]
links: []
created: 2026-03-23T20:27:05Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-78iq
---
# Implement hooks/pre-commit-ticket-gate.sh

Create plugins/dso/hooks/pre-commit-ticket-gate.sh — a commit-msg stage git hook that blocks commits lacking a valid v3 ticket ID in the commit message.

TDD REQUIREMENT: Task 1's RED tests must be failing before starting this task. Implement until all Task 1 tests go GREEN.

IMPLEMENTATION:
This is a commit-msg hook (receives commit message file path as $1, unlike pre-commit hooks which use git diff --cached). It follows the same structural pattern as pre-commit-review-gate.sh.

Logic (in order):
1. Read the commit message from $1 (COMMIT_EDITMSG path passed by git)
   - Support COMMIT_MSG_FILE_OVERRIDE env var for test injection
2. Merge commit exemption: if $(git rev-parse --git-dir)/MERGE_HEAD exists → exit 0 unconditionally
3. Get staged files: git diff --cached --name-only (same as pre-commit hooks)
4. Load allowlist: CONF_OVERRIDE env var or $HOOK_DIR/lib/review-gate-allowlist.conf (via _load_allowlist_patterns from deps.sh)
5. Build NON_REVIEWABLE_REGEX from allowlist patterns (via _allowlist_to_grep_regex from deps.sh)
6. Check if all staged files match allowlist: if yes → exit 0 (allowlist-skip path)
7. Graceful degradation: resolve tracker dir via TICKET_TRACKER_OVERRIDE or $REPO_ROOT/.tickets-tracker
   - If tracker dir does not exist → print WARNING to stderr → exit 0 (fail-open)
8. Extract ticket IDs from commit message: regex [a-z0-9]{4}-[a-z0-9]{4} (v3 hex format)
9. For each extracted ID: verify $TRACKER_DIR/$ID/ directory exists AND contains a *-CREATE.json file
   - If any ID passes validation → exit 0
10. If no valid ID found → exit 1 with error message including:
   - 'BLOCKED: commit-msg ticket gate'
   - Expected format: 'XXXX-XXXX (hex, e.g. dso-78iq)'
   - Pointer: 'Create a ticket: ticket create task "<description>"'
   - The commit message that was provided (for context)

SHARED INFRA: Source plugins/dso/hooks/lib/deps.sh for _load_allowlist_patterns, _allowlist_to_grep_regex, get_artifacts_dir.

FAIL-OPEN: On SIGTERM/SIGURG (timeout), trap and exit 0 with warning (same pattern as pre-commit-test-gate.sh).

DO NOT modify review-gate-allowlist.conf, pre-commit-review-gate.sh, review-gate.sh, or any other shared gate file.

## Acceptance Criteria

- [ ] plugins/dso/hooks/pre-commit-ticket-gate.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-ticket-gate.sh
- [ ] Hook exits non-zero when commit msg lacks valid v3 ticket ID and non-allowlisted files are staged
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1 | grep -q 'test_blocks_missing_ticket_id.*PASS'
- [ ] Hook exits 0 when all staged files match allowlist
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1 | grep -q 'test_skips_when_all_allowlisted.*PASS'
- [ ] Hook exits 0 unconditionally when MERGE_HEAD present
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1 | grep -q 'test_merge_commit_exempt.*PASS'
- [ ] Hook exits 0 with warning when .tickets-tracker not mounted
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1 | grep -q 'test_graceful_degradation_no_tracker.*PASS'
- [ ] Error output includes format hint and ticket creation pointer
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1 | grep -q 'test_error_message_format_hint.*PASS'
- [ ] All 10+ tests in test-pre-commit-ticket-gate.sh pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1 | grep -c 'FAIL' | awk '{exit ($1 > 0)}'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py

