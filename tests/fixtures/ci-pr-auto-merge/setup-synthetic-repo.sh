#!/usr/bin/env bash
# tests/fixtures/ci-pr-auto-merge/setup-synthetic-repo.sh
#
# Creates a synthetic git repo that mimics a ci-pr session branch where
# story PRs were auto-merged by GitHub (no DSO-Story-Merge trailers).
#
# Usage:
#   setup-synthetic-repo.sh <dest-dir> <epic-id> <story-count>
#
# Outputs:
#   <dest-dir>/remote/   — bare remote repo (origin)
#   <dest-dir>/session/  — shallow-ish clone with N "Merge pull request" commits
#                          on a branch named "worktree-test"
#
# Environment:
#   SYNTHETIC_BASE_REF   — base branch name (default: main)
#   SYNTHETIC_HEAD_REF   — session branch name (default: worktree-test)

set -uo pipefail

DEST="${1:?Usage: setup-synthetic-repo.sh <dest> <epic-id> <story-count>}"
EPIC="${2:?}"
N="${3:?}"
BASE_REF="${SYNTHETIC_BASE_REF:-main}"
HEAD_REF="${SYNTHETIC_HEAD_REF:-worktree-test}"

# Create bare remote
REMOTE_DIR="$DEST/remote"
mkdir -p "$REMOTE_DIR"
git -C "$REMOTE_DIR" init --bare -q
git -C "$REMOTE_DIR" symbolic-ref HEAD "refs/heads/$BASE_REF"

# Create a temp workspace to populate the remote
WORKSPACE=$(mktemp -d "${TMPDIR:-/tmp}/synth-repo-ws.XXXXXX")
trap 'rm -rf "$WORKSPACE"' EXIT

git -C "$WORKSPACE" init -q -b "$BASE_REF"
git -C "$WORKSPACE" config user.email "test@test.local"
git -C "$WORKSPACE" config user.name "Test"
echo "# root" > "$WORKSPACE/README.md"
git -C "$WORKSPACE" add README.md
git -C "$WORKSPACE" commit -q -m "root commit"

# Push main to remote
git -C "$WORKSPACE" remote add origin "$REMOTE_DIR"
git -C "$WORKSPACE" push -q origin "$BASE_REF"

# Create session branch
git -C "$WORKSPACE" checkout -q -b "$HEAD_REF"

# Add N "Merge pull request" commits (no DSO-Story-Merge trailers)
for i in $(seq 1 "$N"); do
    STORY_ID="s${i}"
    SHA_FAKE="$(printf '%040x' $((RANDOM * RANDOM + i)))"
    # Touch a file so the commit is non-empty
    echo "story $i" > "$WORKSPACE/story-${EPIC}-${STORY_ID}.txt"
    git -C "$WORKSPACE" add "story-${EPIC}-${STORY_ID}.txt"
    # Subject line that matches: "Merge pull request ... story/<epic>/<id>"
    git -C "$WORKSPACE" commit -q -m "Merge pull request #${i} from story/${EPIC}/${STORY_ID}"
done

# Push session branch to remote
git -C "$WORKSPACE" push -q origin "$HEAD_REF"

# Clone into session/  (simulate a shallow CI clone)
SESSION_DIR="$DEST/session"
git clone -q --no-local "$REMOTE_DIR" "$SESSION_DIR"
git -C "$SESSION_DIR" config user.email "test@test.local"
git -C "$SESSION_DIR" config user.name "Test"
git -C "$SESSION_DIR" checkout -q "$HEAD_REF"
git -C "$SESSION_DIR" fetch -q origin "$BASE_REF"

echo "synthetic repo ready at $DEST (base=$BASE_REF, head=$HEAD_REF, n=$N)"
