#!/usr/bin/env bash
# validate-pil-handoff.sh
# Validates a PREPLANNING_CONTEXT PIL payload against the required field contract.
#
# Usage:
#   echo "$PIL_JSON" | bash validate-pil-handoff.sh
#   bash validate-pil-handoff.sh --pil-file=<path>
#
# Required fields (schema_version 1+):
#   schema_version  — integer >= 1
#   generatedAt     — non-empty string
#   epicId          — non-empty string
#
# Optional fields: all others are permitted (open-world / forward-compat)
#
# Exit codes:
#   0 — payload is valid
#   1 — validation failed; JSON error object written to stderr
#
# Contract: docs/contracts/pil-handoff.md

set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
_PIL_FILE=""
for _arg in "$@"; do
    case "$_arg" in
        --pil-file=*)
            _PIL_FILE="${_arg#--pil-file=}"
            ;;
        *)
            printf '{"error":"pil_validation_error","message":"Unknown argument: %s"}\n' "$_arg" >&2
            exit 1
            ;;
    esac
done

# ── Read payload ──────────────────────────────────────────────────────────────
_PIL_JSON=""
if [[ -n "$_PIL_FILE" ]]; then
    if [[ ! -f "$_PIL_FILE" ]]; then
        printf '{"error":"pil_validation_error","message":"File not found: %s"}\n' "$_PIL_FILE" >&2
        exit 1
    fi
    _PIL_JSON=$(cat "$_PIL_FILE")
else
    _PIL_JSON=$(cat -)
fi

if [[ -z "$_PIL_JSON" ]]; then
    printf '{"error":"pil_validation_error","message":"Empty PIL payload"}\n' >&2
    exit 1
fi

# ── Check jq availability ─────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    printf '{"error":"pil_validation_error","message":"jq not available — cannot validate PIL payload"}\n' >&2
    exit 1
fi

# ── Validate JSON parseability ────────────────────────────────────────────────
if ! echo "$_PIL_JSON" | jq empty 2>/dev/null; then
    printf '{"error":"pil_validation_error","message":"PIL payload is not valid JSON"}\n' >&2
    exit 1
fi

# ── Validate required fields ──────────────────────────────────────────────────
_ERRORS=()

# schema_version: must be present and an integer >= 1
_SCHEMA_VER=$(echo "$_PIL_JSON" | jq -r '.schema_version // "MISSING"')
if [[ "$_SCHEMA_VER" == "MISSING" || "$_SCHEMA_VER" == "null" ]]; then
    _ERRORS+=("schema_version is required but missing")
else
    # Must be an integer
    if ! echo "$_PIL_JSON" | jq -e '.schema_version | type == "number"' >/dev/null 2>&1; then
        _ERRORS+=("schema_version must be an integer, got: $_SCHEMA_VER")
    elif [[ $(echo "$_PIL_JSON" | jq '.schema_version < 1') == "true" ]]; then
        _ERRORS+=("schema_version must be >= 1, got: $_SCHEMA_VER")
    fi
fi

# generatedAt: must be present and a non-empty string
_GENERATED_AT=$(echo "$_PIL_JSON" | jq -r '.generatedAt // "MISSING"')
if [[ "$_GENERATED_AT" == "MISSING" || "$_GENERATED_AT" == "null" ]]; then
    _ERRORS+=("generatedAt is required but missing")
elif [[ -z "$_GENERATED_AT" ]]; then
    _ERRORS+=("generatedAt must be a non-empty string")
fi

# epicId: must be present and a non-empty string
_EPIC_ID=$(echo "$_PIL_JSON" | jq -r '.epicId // "MISSING"')
if [[ "$_EPIC_ID" == "MISSING" || "$_EPIC_ID" == "null" ]]; then
    _ERRORS+=("epicId is required but missing")
elif [[ -z "$_EPIC_ID" ]]; then
    _ERRORS+=("epicId must be a non-empty string")
fi

# ── Emit result ───────────────────────────────────────────────────────────────
if [[ ${#_ERRORS[@]} -eq 0 ]]; then
    exit 0
fi

# Build JSON error array of messages
_ERR_JSON="["
_FIRST=1
for _msg in "${_ERRORS[@]}"; do
    if [[ "$_FIRST" -eq 1 ]]; then
        _FIRST=0
    else
        _ERR_JSON+=","
    fi
    _ERR_JSON+=$(printf '"%s"' "$_msg" | jq -Rs .)
done
_ERR_JSON+="]"

printf '{"error":"pil_validation_error","schema_version":"%s","generatedAt":"%s","epicId":"%s","messages":%s}\n' \
    "$_SCHEMA_VER" "$_GENERATED_AT" "$_EPIC_ID" "$_ERR_JSON" >&2
exit 1
