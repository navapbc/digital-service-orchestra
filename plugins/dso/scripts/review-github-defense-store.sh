#!/usr/bin/env bash
# review-github-defense-store.sh
# Source-able bash library: GitHubPRDefenseStore — mirrors defense records to
# GitHub PR comments via `gh pr comment`.
#
# Usage:
#   source review-github-defense-store.sh
#
# Injectable for tests:
#   GH_CMD          — gh binary (default: gh)
#   GITHUB_FORK_PR  — set to 1 to enable fork-PR no-op mode

# Default gh command — injectable via GH_CMD for tests
GH_CMD="${GH_CMD:-gh}"

# ---------------------------------------------------------------------------
# _gh_with_backoff max_attempts gh_args...
# Calls $GH_CMD with exponential backoff on non-zero exit.
# Backoff: 2s, 4s, 8s (base 2) between retries.
# Returns 0 on success, 1 after max_attempts exhausted.
# ---------------------------------------------------------------------------
_gh_with_backoff() {
    local max_attempts="$1"
    shift

    local attempt=1
    local delay=2

    while [[ "$attempt" -le "$max_attempts" ]]; do
        if "$GH_CMD" "$@"; then
            return 0
        fi

        if [[ "$attempt" -lt "$max_attempts" ]]; then
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi

        (( attempt++ )) || true
    done

    return 1
}

# ---------------------------------------------------------------------------
# github_defense_store_write record_json pr_number repo
# Post a defense record as a PR comment.
#
# Guards:
#   - Fork PR (GITHUB_FORK_PR=1): no-op, returns 0 silently
#   - ticket_id=UNBOUND in record_json: error on stderr, returns 1
#   - defense_text > 4096 chars: error on stderr, returns 1
# ---------------------------------------------------------------------------
github_defense_store_write() {
    local record_json="$1"
    local pr_number="$2"
    local repo="$3"

    # Fork-PR no-op: silently return 0 without calling gh
    if [[ "${GITHUB_FORK_PR:-}" == "1" ]]; then
        return 0
    fi

    # Ticket-binding check: reject UNBOUND ticket_id
    local ticket_id
    ticket_id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ticket_id',''))" "$record_json" 2>/dev/null) || true
    if [[ "$ticket_id" == "UNBOUND" ]]; then
        echo "ticket-binding required" >&2
        return 1
    fi

    # Defense text cap: reject if defense_text field > 4096 chars
    local defense_text
    defense_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('defense_text',''))" "$record_json" 2>/dev/null) || true
    if [[ ${#defense_text} -gt 4096 ]]; then
        echo "defense_text exceeds 4096 characters" >&2
        return 1
    fi

    # Post PR comment: body = DEFENSE_RECORD: $record_json
    _gh_with_backoff 3 pr comment "$pr_number" --repo "$repo" --body "DEFENSE_RECORD: $record_json"
}

# ---------------------------------------------------------------------------
# review_mirror_defenses_to_pr pr_number repo
# Reads stdin line by line; for each line starting with "DEFENSE_RECORD: ",
# strips the prefix to get JSON and posts it via github_defense_store_write.
# Skips records where ticket_id=UNBOUND.
# Fork-PR no-op: returns 0 silently when GITHUB_FORK_PR=1.
# ---------------------------------------------------------------------------
review_mirror_defenses_to_pr() {
    local pr_number="${1:-}"
    local repo="${2:-}"

    # Fork-PR no-op
    if [[ "${GITHUB_FORK_PR:-}" == "1" ]]; then
        return 0
    fi

    local prefix="DEFENSE_RECORD: "
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "${prefix}"* ]]; then
            local json="${line#"$prefix"}"

            # Skip UNBOUND records
            local ticket_id
            ticket_id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ticket_id',''))" "$json" 2>/dev/null) || true
            if [[ "$ticket_id" == "UNBOUND" ]]; then
                continue
            fi

            github_defense_store_write "$json" "$pr_number" "$repo"
        fi
    done
}
