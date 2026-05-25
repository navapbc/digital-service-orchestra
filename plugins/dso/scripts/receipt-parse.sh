#!/usr/bin/env bash
# receipt-parse.sh
# Parse and validate a scratch-handoff receipt JSON from stdin.
#
# The receipt-only return contract requires sub-agents to return EXACTLY 3 fields:
#   {"ticket_id":"<id>","key":"<k>","byte_count":<N>}
#
# Any deviation — missing fields, extra fields, or non-JSON input — constitutes a
# contract violation. This script enforces the contract and emits a structured error
# log on violation so orchestrators can halt and surface the error to the human session.
#
# Usage:
#   receipt-parse.sh <site_id> <subagent_name>
#
#   Payload is read from stdin.
#
# Arguments:
#   site_id       Identifies the call site (e.g. "impl-plan:511") for error tracing
#   subagent_name Name of the sub-agent whose return block is being validated
#
# On success (exactly 3 valid fields):
#   Prints "<ticket_id> <key>" (space-separated) to stdout and exits 0.
#
# On failure (any contract violation):
#   Emits structured log line to stderr:
#     RECEIPT_PARSE_ERROR site=<site_id> sub_agent=<name> reason=<text> byte_count=<N>
#   Exits non-zero (exit code 2).
#
# Exit codes:
#   0 — valid receipt; ticket_id and key on stdout
#   1 — usage error (wrong number of arguments)
#   2 — RECEIPT_PARSE_ERROR: contract violation (caller must halt workflow)
#
# Dependencies:
#   jq (required; must be on PATH)
#
# Environment:
#   No environment overrides — this script is intentionally stateless.
#
# See: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/scratch-receipt-contract.md

set -uo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    echo "Usage: receipt-parse.sh <site_id> <subagent_name>" >&2
    echo "  Reads receipt JSON from stdin." >&2
    echo "  site_id       : call-site identifier for error tracing" >&2
    echo "  subagent_name : name of the sub-agent whose return block is validated" >&2
    exit 1
}

if [ $# -ne 2 ]; then
    _usage
fi

SITE_ID="$1"
SUBAGENT_NAME="$2"

# ── Dependency check ──────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "RECEIPT_PARSE_ERROR site=${SITE_ID} sub_agent=${SUBAGENT_NAME} reason=jq_not_found byte_count=0" >&2
    exit 2
fi

# ── Read payload from stdin ───────────────────────────────────────────────────
payload=$(cat)
byte_count=${#payload}

# ── Emit structured error helper ──────────────────────────────────────────────
_receipt_error() {
    local reason="$1"
    printf 'RECEIPT_PARSE_ERROR site=%s sub_agent=%s reason=%s byte_count=%d\n' \
        "$SITE_ID" "$SUBAGENT_NAME" "$reason" "$byte_count" >&2
    exit 2
}

# ── Step 1: Validate JSON parsability ─────────────────────────────────────────
if ! echo "$payload" | jq -e . >/dev/null 2>&1; then
    _receipt_error "not_valid_json"
fi

# ── Step 2: Validate it is a JSON object (not array, string, etc.) ────────────
payload_type=$(echo "$payload" | jq -r 'type')
if [ "$payload_type" != "object" ]; then
    _receipt_error "not_a_json_object:type=${payload_type}"
fi

# ── Step 3: Count keys — must be EXACTLY 3 ───────────────────────────────────
key_count=$(echo "$payload" | jq 'keys | length')
if [ "$key_count" -ne 3 ]; then
    _receipt_error "wrong_field_count:expected=3:actual=${key_count}"
fi

# ── Step 4: Check required fields are present ────────────────────────────────
# We already know there are exactly 3 keys, so if all 3 required keys exist,
# there can be no extras.
ticket_id_present=$(echo "$payload" | jq 'has("ticket_id")')
key_present=$(echo "$payload" | jq 'has("key")')
byte_count_present=$(echo "$payload" | jq 'has("byte_count")')

if [ "$ticket_id_present" != "true" ]; then
    _receipt_error "missing_field:ticket_id"
fi

if [ "$key_present" != "true" ]; then
    _receipt_error "missing_field:key"
fi

if [ "$byte_count_present" != "true" ]; then
    _receipt_error "missing_field:byte_count"
fi

# ── Step 5: Extract values ────────────────────────────────────────────────────
ticket_id=$(echo "$payload" | jq -r '.ticket_id')
scratch_key=$(echo "$payload" | jq -r '.key')

# Validate extracted values are non-null and non-empty strings
if [ -z "$ticket_id" ] || [ "$ticket_id" = "null" ]; then
    _receipt_error "empty_or_null_field:ticket_id"
fi

if [ -z "$scratch_key" ] || [ "$scratch_key" = "null" ]; then
    _receipt_error "empty_or_null_field:key"
fi

# ── Step 6: Success — emit ticket_id and key to stdout ───────────────────────
printf '%s %s\n' "$ticket_id" "$scratch_key"
exit 0
