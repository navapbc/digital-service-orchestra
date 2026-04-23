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
# (preserving first-occurrence order of both keys and tests), auto-stage .test-index
# (so the commit proceeds in one step without a second git add), and exit 0.
# This is idempotent, loss-free (union never drops a test entry), and deterministic,
# so auto-fixing is safe. (bug e0be-5826: previously the hook only re-staged the
# file when it was already staged, forcing a second manual git add in merge scenarios.)

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

# Always auto-stage so the commit proceeds in one step without requiring a manual
# git add (bug e0be-5826). This is safe because the union is deterministic and
# idempotent — staging the fixed content can never silently swallow user edits.
git -C "$REPO_ROOT" add .test-index
echo "Auto-staged .test-index with deduplicated content." >&2

exit 0
