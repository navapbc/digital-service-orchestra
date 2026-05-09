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

# ── _check_non_runnable_test_targets <index_file> ─────────────────────────────
# Scans test targets (RHS of each entry) for known non-runnable extensions.
# A test target with .yaml, .yml, .json, .md, .conf, or .txt cannot be executed
# as bash or python and indicates a misconfiguration (e.g. a semgrep rules file
# accidentally registered as a test). Prints offending entries; exits 0 when clean.
# (bug f86e-6f23)
_check_non_runnable_test_targets() {
    local _idx_file="$1"
    python3 -c "
import sys, re

NON_RUNNABLE = {'.yaml', '.yml', '.json', '.md', '.conf', '.txt'}

path = sys.argv[1]
offenders = []

with open(path) as f:
    for lineno, raw in enumerate(f.read().splitlines(), 1):
        if not raw.strip() or raw.startswith('#') or ':' not in raw:
            continue
        _, _, rhs = raw.partition(':')
        for t in rhs.split(','):
            t = t.strip()
            if not t:
                continue
            # Strip RED marker suffix to get the raw file path.
            base = re.sub(r'\s+\[.*\]$', '', t).strip()
            ext = '.' + base.rsplit('.', 1)[-1] if '.' in base else ''
            if ext in NON_RUNNABLE:
                offenders.append(f'  line {lineno}: {base!r} (extension {ext!r} is not runnable)')

if offenders:
    print('\n'.join(offenders))
" "$_idx_file" 2>/dev/null
}

_non_runnable=$(_check_non_runnable_test_targets "$INDEX_FILE")
if [[ -n "$_non_runnable" ]]; then
    echo "ERROR: .test-index has test targets with non-runnable extensions (bug f86e-6f23)." >&2
    echo "These files cannot be executed as bash or python tests and indicate a misconfiguration." >&2
    echo "Remove or replace the following entries:" >&2
    echo "$_non_runnable" >&2
    exit 1
fi

# ── _check_cross_key_conflicts <index_file> ────────────────────────────────────
# Scans <index_file> for test files that appear under multiple source-key lines
# each with a different RED marker (bug 804a-84c7). Prints a human-readable
# conflict report to stdout; prints nothing and exits 0 when clean.
# Uses python3 -c to avoid heredoc-inside-$() bash parse warnings.
_check_cross_key_conflicts() {
    local _idx_file="$1"
    python3 -c "
import sys, re
from collections import defaultdict

path = sys.argv[1]
seen = defaultdict(list)

with open(path) as f:
    for raw in f.read().splitlines():
        if not raw.strip() or raw.startswith('#') or ':' not in raw:
            continue
        source_key, _, rhs = raw.partition(':')
        source_key = source_key.strip()
        for t in rhs.split(','):
            t = t.strip()
            if not t:
                continue
            m = re.match(r'^(.*[^\s])\s+\[([^\]]+)\]\$', t)
            if m:
                test_file = m.group(1).strip()
                marker = m.group(2)
                seen[test_file].append((source_key, marker))

conflicts = []
for test_file, entries in seen.items():
    if len(entries) > 1:
        # Only a conflict when markers DIFFER — same marker under multiple source
        # keys is intentional (both triggers run the same test, no ambiguity).
        unique_markers = {mk for _, mk in entries}
        if len(unique_markers) > 1:
            conflicts.append(f'  {test_file}:')
            for sk, mk in entries:
                conflicts.append(f'    source={sk} marker=[{mk}]')

if conflicts:
    print('\n'.join(conflicts))
" "$_idx_file" 2>/dev/null
}

# Fast path: no duplicates → check for cross-source-key marker conflicts (bug 804a-84c7),
# then exit 0 without rewriting the file.
# Check for both source-key duplicates and within-line marker-only duplicates.
_dups=$(awk -F: '/^[^#]/ && NF>=2 { print $1 }' "$INDEX_FILE" | sort | uniq -d)
# python3 failure must NOT silently shortcut to exit 0 — capture the exit code
# explicitly and fall through to the slow auto-union path on detector error,
# which has its own explicit python3 error handling.
_marker_dups_exit=0
_marker_dups=$(awk '/^[^#].*:/' "$INDEX_FILE" | python3 -c "
import sys, re
for line in sys.stdin:
    line = line.rstrip()
    if ':' not in line:
        continue
    _, _, rhs = line.partition(':')
    seen = set()
    for t in rhs.split(','):
        t = t.strip()
        if not t:
            continue
        base = re.sub(r'\s+\[.*\]$', '', t)
        if base in seen:
            print(line)
            break
        seen.add(base)
" 2>/dev/null) || _marker_dups_exit=$?
if [[ -z "$_dups" && -z "$_marker_dups" && "$_marker_dups_exit" -eq 0 ]]; then
    # No source-key or within-line dups — but still check for cross-source-key
    # RED marker conflicts (bug 804a-84c7). These don't get auto-fixed; they
    # require the agent to consolidate entries manually.
    _fast_cross_conflicts=$(_check_cross_key_conflicts "$INDEX_FILE" 2>/dev/null) || true
    if [[ -n "$_fast_cross_conflicts" ]]; then
        echo "ERROR: .test-index has cross-source-key RED marker conflicts (bug 804a-84c7)." >&2
        echo "The bash-runner uses last-entry-wins, so only the last marker is active." >&2
        echo "Consolidate each test file's RED marker to a single source-key line:" >&2
        echo "$_fast_cross_conflicts" >&2
        exit 1
    fi
    exit 0
fi

# Auto-union duplicates in place. Explicit exit-code check because the hook runs
# under `set -uo pipefail` (not `-e`) — a silent python3 failure would otherwise
# let the script print "auto-unioned" and re-stage the unchanged file.
if ! python3 - "$INDEX_FILE" <<'PY'
import sys, re
from collections import OrderedDict

path = sys.argv[1]
header = []
# entries: source_key -> OrderedDict of base_test_path -> full test entry (with first marker)
entries = OrderedDict()
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
        bucket = entries.setdefault(key, OrderedDict())
        for t in (x.strip() for x in rhs.split(",")):
            if not t:
                continue
            # Normalize: strip the RED marker suffix for dedup keying, keep first occurrence.
            base = re.sub(r'\s+\[.*\]$', '', t).strip()
            if base not in bucket:
                bucket[base] = t  # preserve original (with its marker) on first occurrence

with open(path, "w") as f:
    for h in header:
        f.write(h + "\n")
    for k, bucket in entries.items():
        f.write(f"{k}:{','.join(bucket.values())}\n")
PY
then
    echo "ERROR: .test-index deduplication failed — leaving file untouched." >&2
    exit 1
fi

# Summarize what changed.
if [[ -n "$_dups" ]]; then
    echo "NOTE: .test-index had duplicate source-file keys — auto-unioned in place." >&2
    while IFS= read -r key; do
        printf "  %s\n" "$key" >&2
    done <<< "$_dups"
fi
if [[ -n "$_marker_dups" ]]; then
    echo "NOTE: .test-index had marker-only duplicate test entries — collapsed to first marker." >&2
fi

# ── Post-union cross-source-key marker conflict check (bug 804a-84c7) ─────────
# After union, a test file may still appear in multiple source-key lines each
# with a different RED marker. The bash-runner uses last-entry-wins semantics,
# so only the last marker survives — silently breaking earlier RED zones.
# Detect this and exit 1 so the misconfiguration is caught before CI.
_cross_key_conflicts=$(_check_cross_key_conflicts "$INDEX_FILE" 2>/dev/null) || true
if [[ -n "$_cross_key_conflicts" ]]; then
    echo "ERROR: .test-index has cross-source-key RED marker conflicts (bug 804a-84c7)." >&2
    echo "The bash-runner uses last-entry-wins, so only the last marker is active." >&2
    echo "Consolidate each test file's RED marker to a single source-key line:" >&2
    echo "$_cross_key_conflicts" >&2
    exit 1
fi

# Always auto-stage so the commit proceeds in one step without requiring a manual
# git add (bug e0be-5826). This is safe because the union is deterministic and
# idempotent — staging the fixed content can never silently swallow user edits.
git -C "$REPO_ROOT" add .test-index
echo "Auto-staged .test-index with deduplicated content." >&2

exit 0
