#!/usr/bin/env bash
# Jira API helpers for drift injection tests.
# Requires: JIRA_API_TOKEN, JIRA_USER, JIRA_BASE_URL, DRIFT_TEST_PROJECT_KEY env vars.
set -euo pipefail

# Fix 3: JIRA_BASE_URL is required — no placeholder default.
# Caller (inject-and-heal.sh) validates both before sourcing this file.
_jira_base="${JIRA_BASE_URL}"
_jira_auth="${JIRA_USER}:${JIRA_API_TOKEN}"

# Fix 5: helper to execute a curl call, capture HTTP status, and fail loudly on 4xx/5xx.
_jira_curl() {
    local http_status body tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/jira-api.XXXXXX")
    # Write body to tmpfile; print status on last line via -w
    local errfile
    errfile=$(mktemp "${TMPDIR:-/tmp}/jira-api-err.XXXXXX")
    if ! body=$(curl -s --fail-with-body -w "\n%{http_code}" -u "${_jira_auth}" "$@" 2>"$errfile"); then
        # --fail-with-body causes non-zero exit on 4xx/5xx; body still captured
        http_status=$(tail -n1 <<< "$body" 2>/dev/null || echo "???")
        body=$(head -n-1 <<< "$body" 2>/dev/null || echo "")
        echo "JIRA API error (HTTP ${http_status}): ${body}" >&2
        rm -f "$tmpfile" "$errfile"
        return 1
    fi
    http_status=$(tail -n1 <<< "$body")
    body=$(head -n-1 <<< "$body")
    rm -f "$tmpfile" "$errfile"
    printf '%s' "$body"
}

jira_create_issue() {
    local summary="$1" issuetype="${2:-Task}"
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({'fields': {'project': {'key': sys.argv[1]}, 'summary': sys.argv[2], 'issuetype': {'name': sys.argv[3]}}}))
" "${DRIFT_TEST_PROJECT_KEY}" "$summary" "$issuetype")
    _jira_curl \
        -H "Content-Type: application/json" \
        "${_jira_base}/rest/api/3/issue" \
        -d "$payload" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d['key'])"
}

jira_set_label() {
    local key="$1" label="$2"
    local payload
    payload=$(python3 -c "import json, sys; print(json.dumps({'fields': {'labels': [sys.argv[1]]}}))" "$label")
    _jira_curl \
        -H "Content-Type: application/json" \
        -X PUT "${_jira_base}/rest/api/3/issue/${key}" \
        -d "$payload" > /dev/null
}

jira_unset_label() {
    local key="$1"
    _jira_curl \
        -H "Content-Type: application/json" \
        -X PUT "${_jira_base}/rest/api/3/issue/${key}" \
        -d '{"fields":{"labels":[]}}' > /dev/null
}

jira_read_property() {
    local key="$1" prop="$2"
    _jira_curl \
        "${_jira_base}/rest/api/3/issue/${key}/properties/${prop}" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('value',''))"
}

jira_strip_property() {
    local key="$1" prop="$2"
    _jira_curl \
        -X DELETE "${_jira_base}/rest/api/3/issue/${key}/properties/${prop}" > /dev/null
}

jira_delete_issue() {
    local key="$1"
    _jira_curl \
        -X DELETE "${_jira_base}/rest/api/3/issue/${key}" > /dev/null
}
