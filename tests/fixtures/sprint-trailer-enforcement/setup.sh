#!/usr/bin/env bash
# tests/fixtures/sprint-trailer-enforcement/setup.sh
# Initializes a synthetic git repo simulating the f360-3a5b
# cross-contamination state (bug db71-e078-ec99-4fbf).
#
# Usage:
#   FIXTURE_DIR=$(bash setup.sh)
#   # ... assertions ...
#   rm -rf "$FIXTURE_DIR"
#
# Or pass FIXTURE_DIR as env var to control location.

set -euo pipefail

FIXTURE_DIR="${FIXTURE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/sprint-trailer-fixture.XXXXXX")}"

git init "$FIXTURE_DIR" --initial-branch=main --quiet 2>/dev/null \
    || git init "$FIXTURE_DIR" --quiet 2>/dev/null

(
    cd "$FIXTURE_DIR"
    git config user.email "fixture@test.com"
    git config user.name "Fixture"

    # Base commit (the <base> ref for trailer scans).
    echo "init" > README.md
    git add README.md
    git commit -m "initial commit" --quiet
    git branch base-ref HEAD --quiet \
        || git update-ref refs/heads/base-ref HEAD

    # Three harvest-style commits with NO DSO-Story-Merge trailer.
    # These mimic the Phase F Step 5 per-task harvests that DO land
    # content into the session branch but do NOT carry the story-level
    # trailer.
    for i in 1 2 3; do
        echo "task-$i work" > "task-$i.txt"
        git add "task-$i.txt"
        git commit -m "Merge worktree-agent-fake-task-$i

DSO-Task: task-$i" --quiet
    done
)

# Emit the path for capturing callers.
echo "$FIXTURE_DIR"
