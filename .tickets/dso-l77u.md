---
id: dso-l77u
status: open
deps: [dso-smsg]
links: []
created: 2026-03-21T16:09:46Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-p1y3
---
# Implement canonical path resolution in write_commit_event (ticket-lib.sh)

Add realpath/canonical path resolution to write_commit_event in ticket-lib.sh so that flock and all git operations use the real path even when .tickets-tracker is a symlink.

TDD Requirement: Depends on dso-smsg (RED tests). Implement until both failing tests from dso-smsg pass GREEN.

Implementation steps:
In write_commit_event(), after the line:
  local tracker_dir="$repo_root/.tickets-tracker"

Add canonical path resolution:
  # Resolve symlink to canonical real path to ensure flock consistency across
  # symlink and real-path callers.
  if [ -L "$tracker_dir" ]; then
      tracker_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$tracker_dir")
  fi

This ensures:
- lock_file ($tracker_dir/.ticket-write.lock) uses the real path
- staging_temp mktemp uses the real directory
- git -C $tracker_dir operations run in the real directory
- All callers (whether they resolve via symlink or real path) compete on the same flock

The change is backward compatible: when tracker_dir is already a real directory (no symlink), the [ -L ] guard is false and behavior is unchanged.

Files to edit: plugins/dso/scripts/ticket-lib.sh


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | tail -5
- [ ] `ruff check` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] Both RED tests from dso-smsg now pass GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-lib.sh 2>&1 | grep -E 'test_write_commit_event_resolves_symlink_to_real_path.*PASS|test_write_commit_event_flock_on_canonical_path.*PASS'
- [ ] ticket-lib.sh: tracker_dir resolved via realpath when .tickets-tracker is a symlink
  Verify: grep -q 'os.path.realpath\|python3.*realpath' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-lib.sh
- [ ] Existing write_commit_event tests still pass (backward compat)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-lib.sh 2>&1 | grep -v 'canonical\|symlink' | grep -q PASS
