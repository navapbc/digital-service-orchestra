#!/usr/bin/env bash
# Jira API helpers for drift injection tests.
# Requires: JIRA_API_TOKEN, JIRA_USER, DRIFT_TEST_PROJECT_KEY env vars.
set -euo pipefail

_jira_base="${JIRA_BASE_URL:-https://your-org.atlassian.net}"
_jira_auth="${JIRA_USER:-}:${JIRA_API_TOKEN}"

jira_create_issue() {
    local summary="$1" issuetype="${2:-Task}"
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({'fields': {'project': {'key': sys.argv[1]}, 'summary': sys.argv[2], 'issuetype': {'name': sys.argv[3]}}}))
" "${DRIFT_TEST_PROJECT_KEY}" "$summary" "$issuetype")
    curl -s -u "${_jira_auth}" \
        -H "Content-Type: application/json" \
        "${_jira_base}/rest/api/3/issue" \
        -d "$payload" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d['key'])"
}

jira_set_label() {
    local key="$1" label="$2"
    local payload
    payload=$(python3 -c "import json, sys; print(json.dumps({'fields': {'labels': [sys.argv[1]]}}))" "$label")
    curl -s -u "${_jira_auth}" \
        -H "Content-Type: application/json" \
        -X PUT "${_jira_base}/rest/api/3/issue/${key}" \
        -d "$payload" > /dev/null
}

jira_unset_label() {
    local key="$1"
    curl -s -u "${_jira_auth}" \
        -H "Content-Type: application/json" \
        -X PUT "${_jira_base}/rest/api/3/issue/${key}" \
        -d '{"fields":{"labels":[]}}' > /dev/null
}

jira_read_property() {
    local key="$1" prop="$2"
    curl -s -u "${_jira_auth}" \
        "${_jira_base}/rest/api/3/issue/${key}/properties/${prop}" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('value',''))"
}

jira_strip_property() {
    local key="$1" prop="$2"
    curl -s -u "${_jira_auth}" \
        -X DELETE "${_jira_base}/rest/api/3/issue/${key}/properties/${prop}" > /dev/null
}

jira_delete_issue() {
    local key="$1"
    curl -s -u "${_jira_auth}" \
        -X DELETE "${_jira_base}/rest/api/3/issue/${key}" > /dev/null
}
