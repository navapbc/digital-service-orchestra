#!/usr/bin/env bash
# Jira API helpers for drift injection tests.
# Requires: JIRA_API_TOKEN, DRIFT_TEST_PROJECT_KEY env vars.
set -euo pipefail

_jira_base="${JIRA_BASE_URL:-https://your-org.atlassian.net}"

jira_create_issue() {
    local summary="$1" issuetype="${2:-Task}"
    curl -s -u ":${JIRA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${_jira_base}/rest/api/3/issue" \
        -d "{\"fields\":{\"project\":{\"key\":\"${DRIFT_TEST_PROJECT_KEY}\"},\"summary\":\"${summary}\",\"issuetype\":{\"name\":\"${issuetype}\"}}}" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d['key'])"
}

jira_set_label() {
    local key="$1" label="$2"
    curl -s -u ":${JIRA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -X PUT "${_jira_base}/rest/api/3/issue/${key}" \
        -d "{\"fields\":{\"labels\":[\"${label}\"]}}" > /dev/null
}

jira_unset_label() {
    local key="$1"
    curl -s -u ":${JIRA_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -X PUT "${_jira_base}/rest/api/3/issue/${key}" \
        -d '{"fields":{"labels":[]}}' > /dev/null
}

jira_read_property() {
    local key="$1" prop="$2"
    curl -s -u ":${JIRA_API_TOKEN}" \
        "${_jira_base}/rest/api/3/issue/${key}/properties/${prop}" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('value',''))"
}

jira_strip_property() {
    local key="$1" prop="$2"
    curl -s -u ":${JIRA_API_TOKEN}" \
        -X DELETE "${_jira_base}/rest/api/3/issue/${key}/properties/${prop}" > /dev/null
}

jira_delete_issue() {
    local key="$1"
    curl -s -u ":${JIRA_API_TOKEN}" \
        -X DELETE "${_jira_base}/rest/api/3/issue/${key}" > /dev/null
}
