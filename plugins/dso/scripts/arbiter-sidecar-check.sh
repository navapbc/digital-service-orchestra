#!/usr/bin/env bash
# Usage: arbiter-sidecar-check.sh <sidecar_path> <head_sha>
# Exits 0 if no BLOCK ruling for current SHA; exits 1 (with rationales on stderr) if any BLOCK found.
# Exits 1 (fail-closed) on malformed JSON.
set -eu

sidecar="$1"
head_sha="$2"

python3 - "$sidecar" "$head_sha" <<'PY' || exit 1
import json, sys
sidecar, head_sha = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(sidecar))
except Exception as e:
    print(f"WARNING: arbiter-rulings.json malformed: {e}", file=sys.stderr)
    sys.exit(1)
sidecar_sha = data.get("commit_sha", "")
if sidecar_sha != head_sha:
    sys.exit(0)  # different SHA - ignore
blocks = [r for r in data.get("rulings", []) if r.get("ruling") == "BLOCK"]
if not blocks:
    sys.exit(0)
print("", file=sys.stderr)
print(f"BLOCKED: arbiter ruled BLOCK on {len(blocks)} finding(s) for commit {head_sha[:12]}", file=sys.stderr)
for r in blocks:
    print(f"  - {r.get('rationale','(no rationale)')}", file=sys.stderr)
sys.exit(1)
PY
