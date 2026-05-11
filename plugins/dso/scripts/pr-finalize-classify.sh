#!/usr/bin/env bash
# pr-finalize-classify.sh — one-shot PR state classifier for /dso:finalize-pr
#
# Inspects a PR via `gh` and emits a JSON object describing the next action
# the calling agent must take. Single-shot: no loop, no LLM dispatch, no edits.
# The /dso:finalize-pr skill calls this in a loop, performs the indicated
# action between calls, and re-invokes until status == MERGED or escalated.
#
# Usage:  pr-finalize-classify.sh <pr-number>
# Output: JSON object on stdout. See OUTPUT SCHEMA below.
#
# OUTPUT SCHEMA
# -------------
# {
#   "status": "<status-code>",
#   "pr_url": "<https url>",
#   "head_sha": "<sha>",
#   "next_action": "<short description for the agent>",
#   "payload": { ... status-specific }
# }
#
# Status codes:
#   MERGED               PR is merged. Done.
#   CONFLICTING          mergeable=CONFLICTING. Agent must merge main locally and resolve.
#   CHECKS_FAILED        One or more required checks FAILED/CANCELLED/TIMED_OUT.
#                        payload.failing_checks = [{name, conclusion, run_url}]
#   THREADS_UNRESOLVED   Unresolved review threads exist (and checks not failed).
#                        payload.threads = [{id, file, line, body, author}]
#   CHECKS_PENDING       Required checks still running; no failures yet.
#                        payload.pending_count = N
#   READY_TO_MERGE       mergeable=MERGEABLE, all checks passing, no threads, no review block.
#                        Agent should call `gh pr merge` with the project's strategy.
#   BLOCKED_BY_REVIEW    mergeable=MERGEABLE but state=BLOCKED for a non-CI reason (e.g.,
#                        required reviewer hasn't approved). Agent must escalate to user.
#   UNKNOWN              Classifier could not determine state; agent should escalate.

set -uo pipefail

if [[ $# -lt 1 ]]; then
    echo '{"status":"UNKNOWN","next_action":"usage: pr-finalize-classify.sh <pr-number>"}' >&2
    exit 2
fi

PR="$1"

# Resolve owner/repo from gh
_repo_json=$(gh repo view --json owner,name 2>/dev/null) || {
    echo '{"status":"UNKNOWN","next_action":"gh repo view failed; ensure gh is authenticated in this repo"}' >&2
    exit 2
}
OWNER=$(echo "$_repo_json" | python3 -c "import json,sys;print(json.load(sys.stdin)['owner']['login'])")
REPO=$(echo "$_repo_json" | python3 -c "import json,sys;print(json.load(sys.stdin)['name'])")

# Top-level PR state
_pr_json=$(gh pr view "$PR" --json mergeable,mergeStateStatus,state,url,headRefOid,reviewDecision 2>/dev/null) || {
    echo "{\"status\":\"UNKNOWN\",\"next_action\":\"gh pr view $PR failed\"}" >&2
    exit 2
}

read -r PR_URL HEAD_SHA MERGEABLE MERGE_STATE PR_STATE REVIEW_DECISION <<<"$(echo "$_pr_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('url',''), d.get('headRefOid',''), d.get('mergeable',''), d.get('mergeStateStatus',''), d.get('state',''), d.get('reviewDecision','') or 'NONE')
")"

# 1. MERGED → done
if [[ "$PR_STATE" == "MERGED" ]]; then
    python3 -c "
import json
print(json.dumps({'status':'MERGED','pr_url':'$PR_URL','head_sha':'$HEAD_SHA','next_action':'PR is merged. No further action.','payload':{}}))
"
    exit 0
fi

# 2. CONFLICTING → agent must merge main locally + resolve
if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
    python3 -c "
import json
print(json.dumps({
  'status':'CONFLICTING',
  'pr_url':'$PR_URL',
  'head_sha':'$HEAD_SHA',
  'next_action':'Fetch origin/main, merge into branch, resolve conflicts in agent context, commit merge, push.',
  'payload': {}
}))
"
    exit 0
fi

# 3. Failing checks → list them. gh pr checks fields: bucket (pass|pending|fail|skipping),
# state (SUCCESS|IN_PROGRESS|FAILURE|...). Use bucket=fail as the authoritative signal.
_checks_json=$(gh pr checks "$PR" --json name,state,bucket,link 2>/dev/null || echo '[]')
_failing=$(echo "$_checks_json" | python3 -c "
import json, sys
try:
    cs = json.load(sys.stdin)
except Exception:
    cs = []
if not isinstance(cs, list): cs = []
out = []
for c in cs:
    if (c.get('bucket') or '').lower() == 'fail':
        out.append({'name': c.get('name'), 'state': c.get('state',''), 'run_url': c.get('link','')})
print(json.dumps(out))
")
if [[ "$_failing" != "[]" ]]; then
    python3 -c "
import json
failing = json.loads('''$_failing''')
print(json.dumps({
  'status':'CHECKS_FAILED',
  'pr_url':'$PR_URL',
  'head_sha':'$HEAD_SHA',
  'next_action':'Investigate each failing check, fix root cause, commit, push. Use /dso:fix-bug for non-trivial test failures.',
  'payload':{'failing_checks': failing}
}))
"
    exit 0
fi

# 4. Unresolved review threads
# graphql is the only reliable source for thread resolution state
_threads_json=$(gh api graphql -f query="query{repository(owner:\"$OWNER\",name:\"$REPO\"){pullRequest(number:$PR){reviewThreads(first:50){nodes{id isResolved isOutdated comments(first:5){nodes{body path line author{login}}}}}}}}" 2>/dev/null || echo '{}')

_unresolved=$(echo "$_threads_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
nodes = (((d.get('data') or {}).get('repository') or {}).get('pullRequest') or {}).get('reviewThreads', {}).get('nodes', [])
out = []
for t in nodes:
    if t.get('isResolved'): continue
    if t.get('isOutdated'): continue
    cs = (t.get('comments') or {}).get('nodes') or []
    if not cs: continue
    first = cs[0]
    out.append({
      'id': t.get('id'),
      'file': first.get('path'),
      'line': first.get('line'),
      'author': (first.get('author') or {}).get('login'),
      'body': (first.get('body') or '')[:600]
    })
print(json.dumps(out))
")

if [[ "$_unresolved" != "[]" ]]; then
    python3 -c "
import json
threads = json.loads('''$_unresolved''')
print(json.dumps({
  'status':'THREADS_UNRESOLVED',
  'pr_url':'$PR_URL',
  'head_sha':'$HEAD_SHA',
  'next_action':'For each thread: read body+file+line, apply a code fix OR reply+resolve. Push fix commits. Mark threads resolved via gh api once addressed.',
  'payload':{'threads': threads}
}))
"
    exit 0
fi

# 5. Check pending. bucket=pending OR state in {PENDING,IN_PROGRESS,QUEUED,EXPECTED}.
_pending=$(echo "$_checks_json" | python3 -c "
import json, sys
try:
    cs = json.load(sys.stdin)
except Exception:
    cs = []
if not isinstance(cs, list): cs = []
pending = sum(1 for c in cs
              if (c.get('bucket') or '').lower() == 'pending'
              or (c.get('state') or '').upper() in ('PENDING','IN_PROGRESS','QUEUED','EXPECTED'))
print(pending)
")

if [[ "${_pending:-0}" -gt 0 ]]; then
    python3 -c "
import json
print(json.dumps({
  'status':'CHECKS_PENDING',
  'pr_url':'$PR_URL',
  'head_sha':'$HEAD_SHA',
  'next_action':'Wait ~60-120s and re-classify. Do not push speculative changes.',
  'payload':{'pending_count': $_pending}
}))
"
    exit 0
fi

# 6. Mergeable but BLOCKED (likely required-review)
if [[ "$MERGEABLE" == "MERGEABLE" && "$MERGE_STATE" == "BLOCKED" ]]; then
    python3 -c "
import json
print(json.dumps({
  'status':'BLOCKED_BY_REVIEW',
  'pr_url':'$PR_URL',
  'head_sha':'$HEAD_SHA',
  'next_action':'PR is mergeable and green but blocked by branch protection (typically required reviewer). Escalate to user; the agent cannot resolve this autonomously.',
  'payload':{'merge_state': '$MERGE_STATE', 'review_decision': '$REVIEW_DECISION'}
}))
"
    exit 0
fi

# 7. Ready to merge
if [[ "$MERGEABLE" == "MERGEABLE" && ("$MERGE_STATE" == "CLEAN" || "$MERGE_STATE" == "UNSTABLE") ]]; then
    python3 -c "
import json
print(json.dumps({
  'status':'READY_TO_MERGE',
  'pr_url':'$PR_URL',
  'head_sha':'$HEAD_SHA',
  'next_action':'Call gh pr merge with the project merge strategy (default: squash). Verify state=MERGED after.',
  'payload':{'merge_state': '$MERGE_STATE'}
}))
"
    exit 0
fi

# Fallthrough
python3 -c "
import json
print(json.dumps({
  'status':'UNKNOWN',
  'pr_url':'$PR_URL',
  'head_sha':'$HEAD_SHA',
  'next_action':'Classifier did not match any known state. Inspect PR manually.',
  'payload':{'mergeable':'$MERGEABLE','merge_state':'$MERGE_STATE','pr_state':'$PR_STATE'}
}))
"
