#!/usr/bin/env bash
# check-test-index-duplicates.sh
# Pre-commit guard: .test-index must contain at most one line per source-file key.
#
# Why: worktree merges can concatenate independent .test-index edits from multiple
# branches. Without deduplication, a single source file accumulates N copies of
# its association line, inflating the count measured by test-gate thresholds and
# the associated-test batch runner (bug 6dd3-8d54: preplanning/SKILL.md had
# 18 duplicate lines → 377 tests measured vs. 25 unique tests).
#
# Behavior: when duplicate keys are found, union the test associations in place
# (preserving first-occurrence order of both keys and tests) and — if the file
# was staged — re-stage it. This is idempotent, loss-free (union never drops a
# test entry), and deterministic, so auto-fixing is safe.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
    exit 0  # not in a git repo — nothing to check
fi

INDEX_FILE="$REPO_ROOT/.test-index"
if [[ ! -f "$INDEX_FILE" ]]; then
    exit 0  # file absent — nothing to check
fi

# Fast path: no duplicates → exit 0 without rewriting the file.
_dups=$(awk -F: '/^[^#]/ && NF>=2 { print $1 }' "$INDEX_FILE" | sort | uniq -d)
if [[ -z "$_dups" ]]; then
    exit 0
fi

# Check whether the file is staged, so we know whether to re-stage after union.
_was_staged=0
if git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | grep -qx ".test-index"; then
    _was_staged=1
fi

# Auto-union duplicates in place. Explicit exit-code check because the hook runs
# under `set -uo pipefail` (not `-e`) — a silent python3 failure would otherwise
# let the script print "auto-unioned" and re-stage the unchanged file.
if ! python3 - "$INDEX_FILE" <<'PY'
import sys
from collections import OrderedDict

path = sys.argv[1]
header = []
entries = OrderedDict()  # key -> list of test entries (dedup preserving order)
in_header = True

with open(path) as f:
    for raw in f.read().splitlines():
        if in_header and (raw.startswith("#") or not raw.strip()):
            header.append(raw)
            continue
        in_header = False
        if not raw.strip() or raw.startswith("#") or ":" not in raw:
            continue
        key, _, rhs = raw.partition(":")
        key = key.strip()
        bucket = entries.setdefault(key, [])
        for t in (x.strip() for x in rhs.split(",")):
            if t and t not in bucket:
                bucket.append(t)

with open(path, "w") as f:
    for h in header:
        f.write(h + "\n")
    for k, ts in entries.items():
        f.write(f"{k}:{','.join(ts)}\n")
PY
then
    echo "ERROR: .test-index deduplication failed — leaving file untouched." >&2
    exit 1
fi

# Summarize what changed.
echo "NOTE: .test-index had duplicate source-file keys — auto-unioned in place." >&2
_fixed_count=0
while IFS= read -r key; do
    _fixed_count=$((_fixed_count + 1))
    printf "  %s\n" "$key" >&2
done <<< "$_dups"

if [[ $_was_staged -eq 1 ]]; then
    git -C "$REPO_ROOT" add .test-index
    echo "Re-staged .test-index with deduplicated content." >&2
else
    echo "Note: .test-index was not staged; the deduplicated file is left in the working tree." >&2
fi

exit 0
