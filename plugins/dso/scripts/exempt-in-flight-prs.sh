#!/usr/bin/env bash
# exempt-in-flight-prs.sh
# Apply migration-grace label to all open PRs and log exemptions.
#
# Usage: bash exempt-in-flight-prs.sh
#
# Behavior:
#   1. Lists all open PRs via: gh pr list --state open --json number,headRefName,headRefOid
#   2. For each PR, checks if migration-grace label is already present.
#   3. If not present, applies label via: gh pr edit <num> --add-label migration-grace
#   4. Appends an exemption record to docs/migration-exemptions/sub-pr-cutover.jsonl
#      (idempotent: appends every run, but skips gh pr edit if label already present).
#
# Exit codes:
#   0 — success (all PRs processed)
#   1 — error (gh command failed or JSON parsing failed)

set -uo pipefail

LABEL="migration-grace"
EXEMPTING_RULE="in-flight-pr-sub-pr-cutover"
LOG_DIR="docs/migration-exemptions"
LOG_FILE="${LOG_DIR}/sub-pr-cutover.jsonl"

# List open PRs: returns JSON array of objects with number, headRefName, headRefOid
_pr_list_json="$(gh pr list --state open --json number,headRefName,headRefOid 2>&1)"
_list_rc=$?
if [[ "$_list_rc" -ne 0 ]]; then
    printf "ERROR: gh pr list failed (exit %d): %s\n" "$_list_rc" "$_pr_list_json" >&2
    exit 1
fi

# If no open PRs, nothing to do
if [[ "$_pr_list_json" == "[]" || -z "$_pr_list_json" ]]; then
    exit 0
fi

# Parse PR numbers, SHAs from JSON using shell — no jq dependency required.
# The JSON is an array like: [{"number":101,"headRefName":"...","headRefOid":"abc123"},...]
# Extract each PR's number and sha via simple pattern matching.
_parse_prs() {
    local json="$1"
    # Strip surrounding array brackets and split on object boundaries
    # Each object: {"number":NNN,"headRefName":"...","headRefOid":"SHA"}
    # Output format: NUMBER SHA (one per line)
    local tmp="${json#[}"
    tmp="${tmp%]}"
    # Split on },{
    local IFS_SAVE="$IFS"
    IFS='}' read -r -a _objects <<< "$tmp"
    IFS="$IFS_SAVE"
    for _obj in "${_objects[@]}"; do
        # Skip empty/delimiter fragments
        [[ "$_obj" =~ \"number\":([0-9]+) ]] || continue
        local _num="${BASH_REMATCH[1]}"
        local _sha=""
        if [[ "$_obj" =~ \"headRefOid\":\"([^\"]+)\" ]]; then
            _sha="${BASH_REMATCH[1]}"
        fi
        printf "%s %s\n" "$_num" "$_sha"
    done
}

# Check if a PR already has the migration-grace label.
# Returns 0 if label present, 1 if not.
_has_label() {
    local pr_num="$1"
    local labels_json
    labels_json="$(gh pr view "$pr_num" --json labels 2>&1)"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        printf "WARN: gh pr view %s --json labels failed (exit %d)\n" "$pr_num" "$rc" >&2
        return 1
    fi
    # labels_json is array like: [{"name":"migration-grace"},...]
    if [[ "$labels_json" == *"\"$LABEL\""* ]]; then
        return 0
    fi
    return 1
}

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Process each PR
while IFS=' ' read -r _pr_num _pr_sha; do
    [[ -z "$_pr_num" ]] && continue

    # Idempotency check: skip if label already present
    if _has_label "$_pr_num"; then
        printf "INFO: PR %s already has label %s — skipping\n" "$_pr_num" "$LABEL"
    else
        # Apply label
        gh pr edit "$_pr_num" --add-label "$LABEL"
        printf "INFO: Applied label %s to PR %s\n" "$LABEL" "$_pr_num"
    fi

    # Append exemption log entry (always, for audit trail)
    _timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"pr_number":%s,"sha":"%s","timestamp":"%s","exempting_rule":"%s"}\n' \
        "$_pr_num" "$_pr_sha" "$_timestamp" "$EXEMPTING_RULE" >> "$LOG_FILE"

done < <(_parse_prs "$_pr_list_json")

exit 0
