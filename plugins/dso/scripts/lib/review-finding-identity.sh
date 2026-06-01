#!/usr/bin/env bash
# review-finding-identity.sh — W2c: CI-side finding identity (no pr_number).
#
# CS-12: the only content-stable finding identity, `cited_lines_fingerprint`, is
# computed by the Tracker store but never read by runner.py, not written by the
# GitHub backend, AND folds `pr_number` into the hash (so a sub-PR defense and an
# integration finding can never match). This builds a MINIMAL, pr_number-free
# identity usable on the CI integration path for convergence/credit detection.
#
# Identity = sha256 over the finding's CITED HUNK location (sorted cited_lines).
# Cited lines (file:line) are stable across re-wordings of the description, which
# is exactly what convergence detection needs (the same location flagged again).
# Deliberately excludes pr_number, title, and description prose.

# compute_finding_ids <findings.json>
#   Echoes one hex finding-id per finding (skips findings with no cited_lines).
compute_finding_ids() {
    local findings="$1"
    [[ -f "$findings" ]] || return 0
    python3 -c "
import json, sys, hashlib
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
findings = d.get('findings', []) if isinstance(d, dict) else (d if isinstance(d, list) else [])
for f in findings:
    if not isinstance(f, dict):
        continue
    cited = f.get('cited_lines') or []
    if not isinstance(cited, list) or not cited:
        continue
    # Canonical: sorted, stripped cited-line refs joined by newline. NO pr_number,
    # NO title/description (those reword across cycles).
    canon = '\n'.join(sorted(str(c).strip() for c in cited if str(c).strip()))
    if not canon:
        continue
    print(hashlib.sha256(canon.encode()).hexdigest())
" "$findings"
}
