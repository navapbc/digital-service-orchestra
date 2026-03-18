#!/usr/bin/env bash
# hooks/pre-push-sentinel-check.sh
# Pre-push hook: blocks git push if .checkpoint-needs-review is tracked in HEAD.
#
# .checkpoint-needs-review is written during pre-compaction auto-saves to signal
# that the code was committed without review. It must be cleared by running /dso:commit
# (which invokes the review workflow and stages the sentinel as a deletion) before
# the branch can be pushed to origin.
#
# Invoked by pre-commit at the push stage.

set -uo pipefail

# REVIEW-DEFENSE: pre-commit does not forward git's stdin to hook entry commands
# at the push stage — push refs are consumed internally and never piped to hooks.
# HEAD-based check is correct for this sentinel's lifecycle: the pre-compact hook
# only ever writes .checkpoint-needs-review to HEAD at the moment of compaction.
# Any ref being pushed that is not HEAD (e.g. git push origin HEAD~3:feature)
# would be an older commit that predates the sentinel write and can never contain
# a freshly-written sentinel. Clearing via /dso:commit always produces a new HEAD
# without the sentinel before any subsequent push can be attempted.
if git cat-file -e "HEAD:.checkpoint-needs-review" 2>/dev/null; then
    cat >&2 <<'MSG'

Push blocked: .checkpoint-needs-review exists in HEAD.
This commit was auto-saved during context compaction and has not been reviewed.

Recovery:
  1. git reset --soft HEAD~1
  2. git rm --cached .checkpoint-needs-review && rm -f .checkpoint-needs-review
  3. Run /dso:commit from Step 1  (tests -> review -> proper commit)
  4. git push

MSG
    exit 1
fi

exit 0
