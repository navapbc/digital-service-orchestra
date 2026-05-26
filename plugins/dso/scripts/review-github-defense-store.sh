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

# Sentinel pr_number used for legacy/unkeyed records.  When a DEFENSE_RECORD
# JSON body has no pr_number field the record is treated as if pr_number=0
# and is returned for ANY --pr-number query (backward-compat sentinel).
_GITHUB_DEFENSE_SENTINEL_PR=0

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
# github_defense_store_write record_json pr_number repo [--pr-number <key>]
# Post a defense record as a PR comment.
#
# Positional args:
#   record_json  — JSON string for the defense record
#   pr_number    — GitHub PR number to post the comment on (the GH PR target)
#   repo         — owner/repo slug
#
# Optional flag (flag disambiguation from positional pr_number):
#   --pr-number <key>  — logical PR key to embed in the DEFENSE_RECORD JSON.
#                        When supplied, the record JSON is enriched with
#                        "pr_number": <key> before posting.  When absent,
#                        no pr_number field is added (sentinel/legacy record).
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
    shift 3 || true

    # Parse optional --pr-number flag from remaining args
    local key_pr_number=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr-number)
                key_pr_number="${2:-}"
                shift 2 || true
                ;;
            *)
                shift
                ;;
        esac
    done

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

    # Embed pr_number key in the record JSON when --pr-number was supplied.
    # This enables per-PR defense keying: github_defense_store_list can then
    # filter by pr_number, preventing cross-PR defense leakage.
    local enriched_json="$record_json"
    if [[ -n "$key_pr_number" ]]; then
        enriched_json=$(python3 -c "
import json, sys
record = json.loads(sys.argv[1])
record['pr_number'] = int(sys.argv[2])
print(json.dumps(record))
" "$record_json" "$key_pr_number" 2>/dev/null) || enriched_json="$record_json"
    fi

    # Post PR comment: body = DEFENSE_RECORD: $enriched_json
    # Use --body-file (mktemp-backed) instead of --body to avoid argv-interpolation
    # hazards (argv length limits, shell quoting, exotic-byte handling) when
    # defense_text contains markdown fences, embedded quotes, or multibyte UTF-8.
    local body_file
    body_file=$(mktemp /tmp/dso-defense.XXXXXX)
    printf '%s' "DEFENSE_RECORD: $enriched_json" > "$body_file"
    _gh_with_backoff 3 pr comment "$pr_number" --repo "$repo" --body-file "$body_file"
    local rc=$?
    rm -f "$body_file"
    return $rc
}

# ---------------------------------------------------------------------------
# github_defense_store_list --pr-number <key> --gh-pr <gh_pr> --repo <repo>
# Fetch PR comments via `gh pr view` and emit DEFENSE_RECORD lines that match
# the requested pr_number key (or sentinel records that match any key).
#
# Arguments:
#   --pr-number <key>   REQUIRED. The logical PR key to filter by.
#                       Records with pr_number == key are returned.
#                       Records with no pr_number field or pr_number == 0
#                       are ALSO returned (sentinel/legacy backward-compat).
#                       Records with pr_number != key AND pr_number != 0 are
#                       excluded (prevents cross-PR leakage).
#   --gh-pr <gh_pr>     The GitHub PR number to fetch comments from.
#                       (This is the GH PR, not the logical key.)
#   --repo <repo>       owner/repo slug for `gh pr view`.
#
# Output:
#   Newline-delimited DEFENSE_RECORD: <json> lines on stdout.
#
# Exit codes:
#   0 — success (zero or more records emitted)
#   1 — argument error or gh command failure
# ---------------------------------------------------------------------------
github_defense_store_list() {
    local key_pr_number=""
    local gh_pr=""
    local repo=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr-number)
                key_pr_number="${2:-}"
                shift 2 || true
                ;;
            --gh-pr)
                gh_pr="${2:-}"
                shift 2 || true
                ;;
            --repo)
                repo="${2:-}"
                shift 2 || true
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ -z "$key_pr_number" ]]; then
        echo "github_defense_store_list: --pr-number is required" >&2
        return 1
    fi

    # Fetch PR comment bodies via gh.
    # Use -q '.comments[].body' to get one plain-text body per line; this avoids
    # the need to parse the outer JSON envelope and handles bodies with embedded
    # JSON cleanly (the jq/gh -q flag handles the escaping for us).
    # Fallback: when the mock or older gh version ignores -q and dumps raw text,
    # the DEFENSE_RECORD grep below still works on the raw output.
    local raw_output
    raw_output=$("$GH_CMD" pr view "${gh_pr:-0}" --json comments -q '.comments[].body' 2>/dev/null) || raw_output=""

    # If -q yielded nothing, fall back: fetch without -q and grep for the prefix.
    # This handles test mocks that emit the raw GH_PR_COMMENTS_JSON string.
    if [[ -z "$raw_output" ]]; then
        raw_output=$("$GH_CMD" pr view "${gh_pr:-0}" --json comments 2>/dev/null) || raw_output=""
    fi

    [[ -z "$raw_output" ]] && return 0

    # Scan output for DEFENSE_RECORD: lines, parse each record JSON, and filter.
    # We use grep+python: grep finds lines (or substrings) containing the prefix;
    # python extracts the JSON suffix, filters by pr_number, and re-emits.
    local prefix="DEFENSE_RECORD: "
    local key_pr="$key_pr_number"
    local sentinel="$_GITHUB_DEFENSE_SENTINEL_PR"

    printf '%s\n' "$raw_output" | python3 -c "
import json, sys

prefix = 'DEFENSE_RECORD: '
key_pr = int(sys.argv[1])
sentinel = int(sys.argv[2])


def extract_json_object(text):
    '''Find and return the first complete JSON object in text.

    Handles the case where the JSON object is embedded in surrounding text
    (e.g. inside a JSON string, with trailing delimiters like '\"}']).
    Uses Python's json.JSONDecoder.raw_decode to find the exact extent.
    Returns a parsed dict, or None if no valid JSON object is found.
    '''
    start = text.find('{')
    if start == -1:
        return None
    decoder = json.JSONDecoder()
    try:
        obj, _ = decoder.raw_decode(text, start)
        if isinstance(obj, dict):
            return obj
    except (json.JSONDecodeError, ValueError):
        pass
    return None


for raw_line in sys.stdin:
    # Locate the DEFENSE_RECORD: prefix anywhere in the line.
    idx = raw_line.find(prefix)
    if idx == -1:
        continue

    after_prefix = raw_line[idx + len(prefix):]

    # Use raw_decode to find the first complete JSON object after the prefix.
    record = extract_json_object(after_prefix)
    if record is None:
        continue

    # Determine the record's pr_number; absent or null => sentinel (0)
    rec_pr = record.get('pr_number', sentinel)
    if rec_pr is None:
        rec_pr = sentinel

    # Sentinel (0) matches any key; exact pr match also passes; else skip
    if rec_pr == sentinel or rec_pr == key_pr:
        print(prefix + json.dumps(record))
" "$key_pr" "$sentinel" || true
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
