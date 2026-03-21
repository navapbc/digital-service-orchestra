---
id: dso-ael7
status: open
deps: [dso-6lhe]
links: []
created: 2026-03-21T16:09:11Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-p1y3
---
# Implement symlink creation for .tickets-tracker/ in git worktrees (ticket-init.sh)

Implement symlink-based .tickets-tracker/ setup in ticket-init.sh when running from a git worktree.

TDD Requirement: Depends on dso-6lhe (RED tests). Implement until all 5 failing tests from dso-6lhe pass GREEN.

Implementation steps:
1. After the idempotency guard in ticket-init.sh, detect if running inside a git worktree by checking if $REPO_ROOT/.git is a file (not a directory). A file .git means this is a worktree.
2. If in a worktree:
   a. Parse 'git worktree list --porcelain' to extract the main worktree path (the first 'worktree' line that is not a bare repo and is not the current worktree).
   b. Determine symlink target: <main_worktree>/.tickets-tracker/
   c. If .tickets-tracker/ exists as a real directory in the current worktree (auto-init ran before symlink setup), remove it with 'rm -rf' only if it is empty or contains only transient state (guard: verify it's not a real git worktree by checking git rev-parse --is-inside-work-tree from inside it fails).
   d. Create symlink: ln -s <target> $TRACKER_DIR
   e. Add .tickets-tracker to .git/info/exclude (same as main path).
   f. Exit 0 — no further init work needed in worktrees (env-id, branch setup etc. all live in the real dir).
3. Main worktree path: existing behavior unchanged (no .git file, so the detect branch is not entered).

Edge cases to handle:
- Main worktree's .tickets-tracker does not exist yet: abort with helpful error ('Run ticket init from the main repo first, then re-run from the worktree').
- Symlink already exists and points to correct target: idempotent exit 0.
- .git/info/exclude already contains .tickets-tracker: do not duplicate entry.

Files to edit: plugins/dso/scripts/ticket-init.sh


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5
- [ ] `ruff check` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] All 5 RED tests from dso-6lhe now pass GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-init.sh 2>&1 | grep -E 'test_ticket_init_creates_symlink_in_worktree.*PASS|test_ticket_init_symlink_points_to_real_dir.*PASS|test_ticket_init_idempotent_when_symlink_exists.*PASS|test_ticket_init_handles_real_dir_before_symlink.*PASS|test_auto_detect_main_worktree_via_git_list.*PASS'
- [ ] ticket-init.sh syntax valid
  Verify: bash -n $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-init.sh
- [ ] When called from a git worktree, .tickets-tracker is created as a symlink
  Verify: bash -c 'MAIN=$(mktemp -d) && WT=$(mktemp -d) && git -C "$MAIN" init -q && git -C "$MAIN" worktree add "$WT/wt" -b test-wt 2>/dev/null; bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-init.sh --silent 2>/dev/null || true; test -L "$WT/wt/.tickets-tracker" && echo PASS || echo SKIP'
- [ ] When main worktree has no .tickets-tracker/, error message directs user to run init from main repo first
  Verify: bash -c 'MAIN=$(mktemp -d) && WT=$(mktemp -d) && git -C "$MAIN" init -q && git -C "$MAIN" worktree add "$WT/wt" -b test-wt2 2>/dev/null; out=$(cd "$WT/wt" && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-init.sh --silent 2>&1); echo "$out" | grep -qi "main repo\|main.*first\|init.*first" && echo PASS || echo "FAIL: expected error about main repo, got: $out"'
