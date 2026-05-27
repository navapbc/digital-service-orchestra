#!/usr/bin/env bash
# classify-sc-type.sh — Deterministic SC classifier.
#
# Takes SC text on stdin (or as argument), outputs "behavioral" or "structural".
# No LLM judgment — pure verb-list matching.
#
# Decision procedure:
#   1. Action verb from curated list → behavioral
#   2. State/existence verb from curated list → structural
#   3. Neither → behavioral (default: cost of unnecessary behavioral test < cost of missed stub)
#
# Usage:
#   echo "Users can export rules as Rego" | bash classify-sc-type.sh
#   bash classify-sc-type.sh "Users can export rules as Rego"
set -uo pipefail

if [ $# -ge 1 ]; then
    SC_TEXT="$*"
elif [ ! -t 0 ]; then
    SC_TEXT=$(cat)
else
    echo "Usage: classify-sc-type.sh <sc-text>" >&2
    echo "   or: echo '<sc-text>' | classify-sc-type.sh" >&2
    exit 1
fi

if [ -z "$SC_TEXT" ]; then
    echo "behavioral"
    exit 0
fi

SC_LOWER=$(printf '%s' "$SC_TEXT" | tr '[:upper:]' '[:lower:]')

ACTION_VERBS="exports|creates|returns|handles|processes|rejects|validates|sends|receives|transforms|converts|dispatches|routes|applies|executes|runs|produces|generates|invokes|fires|triggers|accepts|authenticates|authorizes|encrypts|decrypts|parses|renders|computes|calculates|fetches|uploads|downloads|deletes|updates|inserts|queries|filters|sorts|merges|splits|connects|disconnects|publishes|subscribes|logs|records|notifies|alerts|schedules|retries|redirects|forwards|imports"

STATE_VERBS="\bexists\b|is configured|is present|is defined|is documented|is absent|is enabled|is disabled|\bis set\b|is installed|is available|is registered|is listed|is included|is excluded|\bhas a \b|\bhas an \b|\bhas the \b|\bcontains\b|\bincludes\b"

if printf '%s' "$SC_LOWER" | grep -qwE "$ACTION_VERBS"; then
    echo "behavioral"
elif printf '%s' "$SC_LOWER" | grep -qE "$STATE_VERBS"; then
    echo "structural"
else
    echo "behavioral"
fi
