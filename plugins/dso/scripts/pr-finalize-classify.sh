#!/usr/bin/env bash
# pr-finalize-classify.sh — one-shot PR state classifier for PR-FINALIZE-WORKFLOW.md
#
# Inspects a PR via `gh` and emits a JSON object describing the next action
# the calling agent must take. Single-shot: no loop, no LLM dispatch, no edits.
# The agent calls this in a loop, performs the indicated action between calls,
# and re-invokes until status == MERGED or escalated.
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
#                        payload.failing_checks = [{name, state, run_url}]
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

# Emit a JSON UNKNOWN status to stdout and exit non-zero.
# Args: $1 = next_action message.
_emit_unknown() {
    local _msg="${1:-classifier failed}"
    NEXT_ACTION="$_msg" python3 -c "
import json, os
print(json.dumps({'status':'UNKNOWN','pr_url':'','head_sha':'','next_action':os.environ['NEXT_ACTION'],'payload':{}}))
"
    exit 2
}

if [[ $# -lt 1 ]]; then
    _emit_unknown "usage: pr-finalize-classify.sh <pr-number>"
fi

PR="$1"

# PR number must be numeric. Prevents GraphQL/shell injection via the argument.
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
    _emit_unknown "PR number must be a positive integer; got: $PR"
fi

# Resolve owner/repo from gh
_repo_json=$(gh repo view --json owner,name 2>/dev/null) || _emit_unknown "gh repo view failed; ensure gh is authenticated in this repo"

OWNER=$(REPO_JSON="$_repo_json" python3 -c "
import json, os, sys
try:
    d = json.loads(os.environ['REPO_JSON'])
    print(d['owner']['login'])
except Exception:
    print('')
") || true
REPO=$(REPO_JSON="$_repo_json" python3 -c "
import json, os, sys
try:
    d = json.loads(os.environ['REPO_JSON'])
    print(d['name'])
except Exception:
    print('')
") || true
if [[ -z "$OWNER" || -z "$REPO" ]]; then
    _emit_unknown "gh repo view returned unparseable response"
fi
# OWNER/REPO will be embedded in a GraphQL query string below. GitHub repo
# names are restricted to [A-Za-z0-9._-] so injection via the API is not
# possible if gh returned valid data; defensively assert anyway.
if ! [[ "$OWNER" =~ ^[A-Za-z0-9._-]+$ && "$REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    _emit_unknown "gh repo view returned implausible owner/repo: $OWNER/$REPO"
fi

# Top-level PR state
_pr_json=$(gh pr view "$PR" --json mergeable,mergeStateStatus,state,url,headRefOid,reviewDecision 2>/dev/null) || _emit_unknown "gh pr view $PR failed"

# Parse PR view in a single Python call (avoids spawning python 4x).
# Output: 6 tab-separated fields.
_pr_parsed=$(PR_JSON="$_pr_json" python3 -c "
import json, os, sys
try:
    d = json.loads(os.environ['PR_JSON'])
    print('\t'.join([
        d.get('url',''),
        d.get('headRefOid',''),
        d.get('mergeable',''),
        d.get('mergeStateStatus',''),
        d.get('state',''),
        d.get('reviewDecision','') or 'NONE',
    ]))
except Exception as e:
    print('PARSE_FAIL\t' + str(e), file=sys.stderr)
    sys.exit(1)
") || _emit_unknown "gh pr view returned unparseable JSON"
IFS=$'\t' read -r PR_URL HEAD_SHA MERGEABLE MERGE_STATE PR_STATE REVIEW_DECISION <<<"$_pr_parsed"

# Helper: emit a status JSON to stdout. Calls into python with the payload
# passed via env var so reviewer-controlled content cannot inject into the
# python source. STATUS, NEXT_ACTION, PAYLOAD_JSON are env vars consumed below.
_emit_status() {
    local _status="$1"
    local _next="$2"
    # NOTE: do not use ${3:-{}} — bash misparses the brace expansion and
    # appends a stray } to the value, producing invalid JSON.
    local _payload_json
    if [[ -z "${3:-}" ]]; then _payload_json='{}'; else _payload_json="$3"; fi
    STATUS="$_status" \
    NEXT_ACTION="$_next" \
    PAYLOAD_JSON="$_payload_json" \
    PR_URL="$PR_URL" \
    HEAD_SHA="$HEAD_SHA" \
    python3 -c "
import json, os, sys
try:
    payload = json.loads(os.environ.get('PAYLOAD_JSON','{}'))
except Exception:
    payload = {}
print(json.dumps({
    'status': os.environ['STATUS'],
    'pr_url': os.environ['PR_URL'],
    'head_sha': os.environ['HEAD_SHA'],
    'next_action': os.environ['NEXT_ACTION'],
    'payload': payload,
}))
"
    exit 0
}

# 1. MERGED → done
if [[ "$PR_STATE" == "MERGED" ]]; then
    _emit_status "MERGED" "PR is merged. No further action."
fi

# 2. CONFLICTING → agent must merge main locally + resolve
if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
    _emit_status "CONFLICTING" "Fetch origin/main, merge into branch, resolve conflicts in agent context, commit merge, push."
fi

# 3. Failing checks → list them. gh pr checks fields: bucket (pass|pending|fail|skipping),
# state (SUCCESS|IN_PROGRESS|FAILURE|...). Use bucket=fail as the authoritative signal.
_checks_json=$(gh pr checks "$PR" --json name,state,bucket,link 2>/dev/null || echo '[]')
_failing=$(CHECKS_JSON="$_checks_json" python3 -c "
import json, os, sys
try:
    cs = json.loads(os.environ['CHECKS_JSON'])
except Exception:
    cs = []
if not isinstance(cs, list):
    cs = []
out = []
for c in cs:
    if (c.get('bucket') or '').lower() == 'fail':
        out.append({'name': c.get('name'), 'state': c.get('state',''), 'run_url': c.get('link','')})
print(json.dumps(out))
") || _failing='[]'

if [[ "$_failing" != "[]" ]]; then
    PAYLOAD=$(FAILING="$_failing" python3 -c "
import json, os
print(json.dumps({'failing_checks': json.loads(os.environ['FAILING'])}))
")
    _emit_status "CHECKS_FAILED" "Investigate each failing check, fix root cause, commit, push. Use /dso:fix-bug for non-trivial test failures." "$PAYLOAD"
fi

# 4. Unresolved review threads. graphql is the only reliable source for thread resolution state.
# OWNER/REPO/PR are validated above; safe to embed in the query. Reviewer-supplied
# thread bodies are surfaced as JSON content (never shell-interpolated).
_threads_json=$(gh api graphql -f query="query{repository(owner:\"$OWNER\",name:\"$REPO\"){pullRequest(number:$PR){reviewThreads(first:50){nodes{id isResolved isOutdated comments(first:5){nodes{body path line author{login}}}}}}}}" 2>/dev/null || echo '{}')

# Check for GraphQL errors before treating empty thread list as authoritative.
_threads_status=$(THREADS_JSON="$_threads_json" python3 -c "
import json, os, sys
try:
    d = json.loads(os.environ['THREADS_JSON'])
except Exception:
    print('PARSE_FAIL')
    sys.exit(0)
if 'errors' in d and d['errors']:
    print('GRAPHQL_ERROR')
    sys.exit(0)
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
print('OK\t' + json.dumps(out))
")
if [[ "$_threads_status" == "PARSE_FAIL" || "$_threads_status" == "GRAPHQL_ERROR" ]]; then
    # Surface the failure as UNKNOWN rather than silently treating it as
    # "no threads" — graphql errors must not let the caller declare ready-to-merge.
    _emit_unknown "graphql thread query returned an error or unparseable response; cannot determine thread state"
fi
_unresolved="${_threads_status#OK$'\t'}"

if [[ "$_unresolved" != "[]" ]]; then
    PAYLOAD=$(THREADS="$_unresolved" python3 -c "
import json, os
print(json.dumps({'threads': json.loads(os.environ['THREADS'])}))
")
    _emit_status "THREADS_UNRESOLVED" "For each thread: read body+file+line, apply a code fix OR reply+resolve. Push fix commits. Mark threads resolved via gh api once addressed." "$PAYLOAD"
fi

# 5. Check pending. bucket=pending OR state in {PENDING,IN_PROGRESS,QUEUED,EXPECTED}.
_pending=$(CHECKS_JSON="$_checks_json" python3 -c "
import json, os, sys
try:
    cs = json.loads(os.environ['CHECKS_JSON'])
except Exception:
    cs = []
if not isinstance(cs, list):
    cs = []
pending = sum(1 for c in cs
              if (c.get('bucket') or '').lower() == 'pending'
              or (c.get('state') or '').upper() in ('PENDING','IN_PROGRESS','QUEUED','EXPECTED'))
print(pending)
") || _pending=0

if [[ "${_pending:-0}" -gt 0 ]]; then
    PAYLOAD=$(PENDING="$_pending" python3 -c "
import json, os
print(json.dumps({'pending_count': int(os.environ['PENDING'])}))
")
    _emit_status "CHECKS_PENDING" "Wait ~60-120s and re-classify. Do not push speculative changes." "$PAYLOAD"
fi

# 6. Mergeable but BLOCKED (likely required-review)
if [[ "$MERGEABLE" == "MERGEABLE" && "$MERGE_STATE" == "BLOCKED" ]]; then
    PAYLOAD=$(MS="$MERGE_STATE" RD="$REVIEW_DECISION" python3 -c "
import json, os
print(json.dumps({'merge_state': os.environ['MS'], 'review_decision': os.environ['RD']}))
")
    _emit_status "BLOCKED_BY_REVIEW" "PR is mergeable and green but blocked by branch protection (typically required reviewer). Escalate to user; the agent cannot resolve this autonomously." "$PAYLOAD"
fi

# 7. Ready to merge
if [[ "$MERGEABLE" == "MERGEABLE" && ("$MERGE_STATE" == "CLEAN" || "$MERGE_STATE" == "UNSTABLE") ]]; then
    PAYLOAD=$(MS="$MERGE_STATE" python3 -c "
import json, os
print(json.dumps({'merge_state': os.environ['MS']}))
")
    _emit_status "READY_TO_MERGE" "Call gh pr merge with the project merge strategy (default: squash). Verify state=MERGED after." "$PAYLOAD"
fi

# Fallthrough
PAYLOAD=$(M="$MERGEABLE" MS="$MERGE_STATE" PS="$PR_STATE" python3 -c "
import json, os
print(json.dumps({'mergeable': os.environ['M'], 'merge_state': os.environ['MS'], 'pr_state': os.environ['PS']}))
")
_emit_status "UNKNOWN" "Classifier did not match any known state. Inspect PR manually." "$PAYLOAD"
