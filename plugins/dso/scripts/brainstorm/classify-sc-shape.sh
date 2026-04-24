#!/usr/bin/env bash
# classify-sc-shape.sh
# Reads SC text from stdin and writes "pure-code" or "external-outcome" to stdout.
#
# External-outcome signals: deployment/runtime, third-party services,
# external integrations, and infrastructure keywords.
#
# Exit code: always 0

# -e omitted: grep exit code drives the conditional; -e would abort on grep's non-zero no-match return
set -uo pipefail

sc_text=$(cat)

if echo "$sc_text" | grep -Eiq \
    'deployed|accessible at|running in production|hosted at|served from|reachable at|stripe|jira|slack|github|salesforce|twilio|sendgrid|aws|gcp|azure|webhook|configured in|live payments|third-party|3rd party|container|cluster|load balancer|certificate|dns'; then
    echo "external-outcome"
else
    echo "pure-code"
fi
