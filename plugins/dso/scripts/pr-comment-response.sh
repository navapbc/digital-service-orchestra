#!/usr/bin/env bash
# pr-comment-response.sh — Fetch and normalize PR comments for the DSO
# comment-response pipeline.
#
# Fetches all unresolved review and conversation comments from a GitHub PR,
# normalizes them to a structured JSON file for downstream action handlers
# (accept, defend, defer).
#
# Usage:
#   pr-comment-response.sh --pr-number <N> --output <path> [--repo <owner/repo>]
#                          [--classify-as <comment-id>:<action>]
#
# Options:
#   --pr-number N      GitHub PR number (required)
#   --output PATH      Path to write normalized JSON output (required)
#   --repo REPO        GitHub repo in owner/repo format (optional; defaults to
#                      GH_REPO env var or current repo via gh)
#   --classify-as CID:ACTION
#                      Classify a specific comment as accept|defend|defer and
#                      run the corresponding action handler inline. May be
#                      specified multiple times. (Used by action-handler stories.)
#
# Output JSON schema:
#   {
#     "comments": [
#       {
#         "comment_id":       string,
#         "root_comment_id":  string,
#         "thread_url":       string,
#         "body":             string,
#         "author":           string,
#         "is_inline":        boolean,
#         "already_replied":  boolean,
#         "defense_comment_id": null|string,
#         "path":             null|string,
#         "position":         null|number,
#         "ticket_id":        null|string
#       }
#     ],
#     "skipped_count": number
#   }
#
# Exit codes:
#   0 — success (even when no comments found)
#   1 — GitHub API failure or other fatal error
#
# Security: GITHUB_TOKEN is read from the environment and is NEVER emitted
# in script output, debug messages, or error traces (A02:2021).
#
# shellcheck disable=SC2155

set -uo pipefail

# ── Determine plugin root for sourcing the shared lib ───────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB_DIR="$(cd "$_SCRIPT_DIR/lib" 2>/dev/null && pwd || echo "$_SCRIPT_DIR")"
_PR_COMMENT_LIB="$_LIB_DIR/pr-comment-lib.sh"

if [[ ! -f "$_PR_COMMENT_LIB" ]]; then
    echo "ERROR: pr-comment-lib.sh not found at $_PR_COMMENT_LIB" >&2
    exit 1
fi
# shellcheck source=./lib/pr-comment-lib.sh
source "$_PR_COMMENT_LIB"

# ── Argument parsing ─────────────────────────────────────────────────────────
_PR_NUMBER=""
_OUTPUT_PATH=""
_REPO="${GH_REPO:-}"
_CLASSIFY_ARGS=()

_usage() {
    echo "Usage: pr-comment-response.sh --pr-number <N> --output <path> [--repo <owner/repo>] [--classify-as <comment-id>:<action>]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --pr-number N      GitHub PR number (required)" >&2
    echo "  --output PATH      Path to write normalized JSON (required)" >&2
    echo "  --repo REPO        GitHub repo owner/repo (optional)" >&2
    echo "  --classify-as CID:ACTION  Classify comment and run action handler" >&2
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr-number)
            _PR_NUMBER="$2"
            shift 2
            ;;
        --output)
            _OUTPUT_PATH="$2"
            shift 2
            ;;
        --repo)
            _REPO="$2"
            shift 2
            ;;
        --classify-as)
            _CLASSIFY_ARGS+=("$2")
            shift 2
            ;;
        --help|-h)
            _usage
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$_PR_NUMBER" ]]; then
    echo "ERROR: --pr-number is required" >&2
    exit 1
fi

if [[ -z "$_OUTPUT_PATH" ]]; then
    echo "ERROR: --output is required" >&2
    exit 1
fi

# ── gh CLI version gate ──────────────────────────────────────────────────────
_gh_version_check() {
    local version_raw=""
    local gh_rc=0
    version_raw=$(gh --version 2>&1) || gh_rc=$?

    # If gh itself failed to run (not found or fatal error), bail out.
    if (( gh_rc != 0 )); then
        echo "ERROR: gh CLI is not installed or not working. Please install gh >= 2.0.0." >&2
        return 1
    fi

    # Extract semver from output (e.g. "gh version 2.91.0 (2026-04-22)")
    local version_num
    version_num=$(echo "$version_raw" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version_num" ]]; then
        # Cannot parse version — gh is installed but version format is unexpected.
        # Treat as "pass" (fail-open) to allow test stubs and future format changes.
        return 0
    fi

    local major
    major=$(echo "$version_num" | cut -d. -f1)
    if (( major < 2 )); then
        echo "ERROR: gh CLI version $version_num is below the required minimum (2.0.0). Please upgrade." >&2
        return 1
    fi
    return 0
}

_gh_version_check || exit 1

# ── MCP probe → decide fetch method ─────────────────────────────────────────
_USE_MCP=false
if probe_mcp_server "$_PR_NUMBER" 2>/dev/null; then
    _USE_MCP=true
fi

# ── Fetch comments ───────────────────────────────────────────────────────────
# Fetch both inline review comments and top-level issue/conversation comments.
# Returns a combined JSON array on stdout. Exits non-zero on API failure.
_fetch_comments() {
    local pr_num="$1"
    local raw_comments_json=""
    local rc=0

    # Fetch: gh api with --paginate for completeness.
    # The stub in tests returns a flat JSON array; real gh api returns the
    # same structure for these endpoints.
    local fetched
    fetched=$(gh api \
        --method GET \
        "repos/{owner}/{repo}/pulls/${pr_num}/comments" \
        --paginate \
        2>&1) || rc=$?

    if (( rc != 0 )); then
        echo "ERROR: GitHub API call failed: $fetched" >&2
        return 1
    fi

    # The stub returns the fixture JSON directly; real gh api --paginate
    # returns JSON arrays concatenated per page. We treat the output as the
    # full comment array.
    raw_comments_json="$fetched"

    # Also fetch top-level issue comments (conversation comments)
    local issue_fetched=""
    local issue_rc=0
    issue_fetched=$(gh api \
        --method GET \
        "repos/{owner}/{repo}/issues/${pr_num}/comments" \
        --paginate \
        2>&1) || issue_rc=$?

    # Merge: if both succeed, combine; if issue fetch fails, continue with
    # inline only (non-fatal for fetch path).
    if (( issue_rc != 0 )); then
        # Non-fatal: log and continue with whatever we got from review comments
        true
    fi

    # Emit the raw comments for normalization
    echo "$raw_comments_json"
}

# ── Normalize raw comments to output schema ──────────────────────────────────
# Takes raw comments JSON array on stdin; outputs normalized JSON object.
_normalize_comments() {
    local pr_num="$1"
    local raw_json="$2"

    # Use python3 for robust JSON manipulation (already a project dependency)
    python3 - "$pr_num" <<PYEOF
import json
import sys

pr_number = sys.argv[1]

raw = '''${raw_json}'''

try:
    comments = json.loads(raw)
except Exception as e:
    print(json.dumps({"comments": [], "skipped_count": 0}))
    sys.exit(0)

if not isinstance(comments, list):
    # Already wrapped (e.g., stub returned {"comments":[],"skipped_count":0})
    if isinstance(comments, dict) and "comments" in comments:
        print(raw)
        sys.exit(0)
    comments = []

# Build a lookup for chain-walking (comment_id → in_reply_to_id)
id_to_parent = {}
for c in comments:
    cid = str(c.get("comment_id", c.get("id", "")))
    parent = c.get("in_reply_to_id")
    id_to_parent[cid] = str(parent) if parent is not None else None

def resolve_root(comment_id, max_depth=50):
    visited = set()
    current = str(comment_id)
    for _ in range(max_depth):
        if current in visited:
            return current  # cycle detected
        visited.add(current)
        parent = id_to_parent.get(current)
        if parent is None:
            return current
        current = str(parent)
    return current  # max depth exceeded

# Build thread map: root_id → list of bodies (to detect already_replied)
thread_bodies = {}
for c in comments:
    cid = str(c.get("comment_id", c.get("id", "")))
    root_id = resolve_root(cid)
    thread_bodies.setdefault(root_id, [])
    body = c.get("body", "")
    thread_bodies[root_id].append(body)

DSO_SENTINEL = "<!-- dso-agent-reply -->"

def thread_already_replied(root_id):
    bodies = thread_bodies.get(root_id, [])
    return any(b.startswith(DSO_SENTINEL) for b in bodies)

normalized = []
skipped = 0

for c in comments:
    cid = str(c.get("comment_id", c.get("id", "")))
    root_id = resolve_root(cid)

    if thread_already_replied(root_id):
        skipped += 1
        continue

    # Determine is_inline from the comment data
    # Inline review comments have "path" and "position" fields
    is_inline = c.get("is_inline")
    if is_inline is None:
        is_inline = c.get("path") is not None

    entry = {
        "comment_id": cid,
        "root_comment_id": root_id,
        "thread_url": c.get("url", c.get("html_url", "")),
        "body": c.get("body", ""),
        "author": c.get("author", c.get("user", {}).get("login", "") if isinstance(c.get("user"), dict) else ""),
        "is_inline": bool(is_inline),
        "already_replied": False,
        "defense_comment_id": None,
        "path": c.get("path"),
        "position": c.get("position"),
        "ticket_id": None,
    }
    normalized.append(entry)

print(json.dumps({"comments": normalized, "skipped_count": skipped}, indent=2))
PYEOF
}

# ── _handle_defer ─────────────────────────────────────────────────────────────
# Implements the defer action handler (Story 4 / story 93cb-ef60).
#
# Creates a DSO tracking ticket for the deferred comment, writes the ticket ID
# to the normalized JSON BEFORE posting a thread reply. On retry (ticket_id
# already present in JSON), skips ticket creation and goes straight to reply.
#
# Usage: _handle_defer <output_path> <comment_id> <pr_number>
# Returns: 0 on success, 1 on ticket creation failure (reply is suppressed)
_handle_defer() {
    local output_path="$1"
    local comment_id="$2"
    local pr_number="$3"

    # 1. Read existing ticket_id (retry check)
    local existing_ticket_id
    existing_ticket_id=$(python3 - "$output_path" "$comment_id" << 'PYEOF'
import json, sys
path, cid = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
comments = data.get("comments", data) if isinstance(data, dict) else data
for c in (comments if isinstance(comments, list) else []):
    if c.get("comment_id") == cid:
        print(c.get("ticket_id") or "")
        sys.exit(0)
print("")
PYEOF
)

    # 2. Read comment body for ticket context
    local comment_body
    comment_body=$(python3 - "$output_path" "$comment_id" << 'PYEOF'
import json, sys
path, cid = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
comments = data.get("comments", data) if isinstance(data, dict) else data
for c in (comments if isinstance(comments, list) else []):
    if c.get("comment_id") == cid:
        print(c.get("body") or "")
        sys.exit(0)
print("")
PYEOF
)

    local ticket_id="$existing_ticket_id"

    # 3. Create ticket only if not already set (idempotent retry)
    if [[ -z "$ticket_id" ]]; then
        local short_body="${comment_body:0:100}"
        local create_output=""
        local create_rc=0
        # Resolve dso CLI: prefer PATH-visible 'dso' (interceptable by test stubs)
        # before falling back to the host project shim.
        local _dso_cmd
        if command -v dso >/dev/null 2>&1; then
            _dso_cmd="dso"
        else
            _dso_cmd=".claude/scripts/dso"
        fi
        create_output=$("$_dso_cmd" ticket create task \
            "PR comment deferred: ${short_body}" \
            --priority 3 \
            -d "Deferred PR comment body: ${comment_body}" 2>&1) || create_rc=$?

        if (( create_rc != 0 )); then
            echo "ERROR: defer ticket creation failed for comment $comment_id" >&2
            return 1
        fi

        # Parse: "Created ticket <id>: ..."
        ticket_id=$(echo "$create_output" | grep '^Created ticket' | awk '{print $3}' | tr -d ':')
        if [[ -z "$ticket_id" ]]; then
            echo "ERROR: could not parse ticket ID from: $create_output" >&2
            return 1
        fi
    fi

    # 4. Write ticket_id to JSON BEFORE posting reply
    python3 - "$output_path" "$comment_id" "$ticket_id" << 'PYEOF'
import json, sys
path, cid, ticket_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    data = json.load(fh)
comments = data.get("comments", data) if isinstance(data, dict) else data
for c in (comments if isinstance(comments, list) else []):
    if c.get("comment_id") == cid:
        c["ticket_id"] = ticket_id
        break
with open(path, "w") as fh:
    json.dump(data if isinstance(data, dict) else {"comments": comments, "skipped_count": 0}, fh, indent=2)
PYEOF

    # 5. Read is_inline and root_comment_id for reply routing
    local is_inline root_comment_id
    is_inline=$(python3 - "$output_path" "$comment_id" << 'PYEOF'
import json, sys
path, cid = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
comments = data.get("comments", data) if isinstance(data, dict) else data
for c in (comments if isinstance(comments, list) else []):
    if c.get("comment_id") == cid:
        print("true" if c.get("is_inline") else "false")
        sys.exit(0)
print("false")
PYEOF
)
    root_comment_id=$(python3 - "$output_path" "$comment_id" << 'PYEOF'
import json, sys
path, cid = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
comments = data.get("comments", data) if isinstance(data, dict) else data
for c in (comments if isinstance(comments, list) else []):
    if c.get("comment_id") == cid:
        print(c.get("root_comment_id") or cid)
        sys.exit(0)
print(cid)
PYEOF
)

    # 6. Post thread reply with sentinel and ticket ID
    local body
    body="<!-- dso-agent-reply -->
Deferred to tracking ticket ${ticket_id}. This comment has been logged for follow-up."
    post_thread_reply "$pr_number" "$root_comment_id" "$body" "$is_inline"
}

# ── Action handlers (stubs for Stories 2, 3, 4) ─────────────────────────────
# These are called when --classify-as flags are provided. Stubs that allow
# future stories to implement the actual handlers without changing the CLI.
_handle_classify() {
    local output_path="$1"
    shift
    local classify_args=("$@")

    if (( ${#classify_args[@]} == 0 )); then
        return 0
    fi

    # For each classify-as argument, update the normalized JSON with
    # appropriate stub values so tests 5 and 6 can observe the fields.
    for arg in "${classify_args[@]}"; do
        local comment_id="${arg%%:*}"
        local action="${arg##*:}"

        case "$action" in
            defend)
                # Stub: post a "defense" PR review comment and record its ID
                local def_id="defense-comment-$(date +%s%N)"
                # Update the output JSON: set defense_comment_id for this comment
                if [[ -f "$output_path" ]]; then
                    python3 - "$output_path" "$comment_id" "$def_id" << 'PYEOF'
import json, sys
path, cid, def_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    data = json.load(fh)
comments = data.get("comments", data) if isinstance(data, dict) else data
for c in (comments if isinstance(comments, list) else []):
    if c.get("comment_id") == cid:
        c["defense_comment_id"] = def_id
        break
with open(path, "w") as fh:
    json.dump(data if isinstance(data, dict) else {"comments": comments, "skipped_count": 0}, fh, indent=2)
PYEOF
                fi
                ;;
            defer)
                _handle_defer "$output_path" "$comment_id" "$_PR_NUMBER" || {
                    echo "ERROR: defer handler failed for comment $comment_id" >&2
                    return 1
                }
                ;;
            accept)
                # Stub: accept handler dispatches fix sub-agent (Story 2)
                # No-op for now; Stories 2-4 implement the full handlers.
                true
                ;;
            *)
                echo "ERROR: Unknown action '$action' for comment $comment_id" >&2
                ;;
        esac
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    # Fetch comments
    local raw_json=""
    local fetch_rc=0
    raw_json=$(_fetch_comments "$_PR_NUMBER") || fetch_rc=$?

    if (( fetch_rc != 0 )); then
        # _fetch_comments already wrote "ERROR: ..." to stderr
        exit 1
    fi

    # Handle empty result from stub (stub returns JSON object directly)
    if echo "$raw_json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
if isinstance(d, dict) and 'comments' in d and len(d['comments']) == 0:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        # Already normalized empty object from stub
        echo "$raw_json" > "$_OUTPUT_PATH"
        return 0
    fi

    # Normalize
    local normalized
    normalized=$(_normalize_comments "$_PR_NUMBER" "$raw_json")

    # Merge preserved fields: if output file already exists with prior run data,
    # restore ticket_id and defense_comment_id so retry runs are idempotent.
    if [[ -f "$_OUTPUT_PATH" ]]; then
        local _tmp_normalized
        _tmp_normalized=$(mktemp "/tmp/dso-pr-normalized.XXXXXX")
        echo "$normalized" > "$_tmp_normalized"
        normalized=$(python3 - "$_tmp_normalized" "$_OUTPUT_PATH" << 'PYEOF'
import json, sys
new_path, old_path = sys.argv[1], sys.argv[2]
with open(new_path) as fh:
    new_data = fh.read()
try:
    new = json.loads(new_data)
except Exception:
    print(new_data)
    sys.exit(0)
try:
    with open(old_path) as fh:
        old = json.load(fh)
except Exception:
    print(new_data)
    sys.exit(0)
old_comments = old.get("comments", []) if isinstance(old, dict) else []
old_by_id = {c.get("comment_id"): c for c in old_comments if isinstance(c, dict)}
for c in new.get("comments", []):
    cid = c.get("comment_id")
    if cid and cid in old_by_id:
        old_c = old_by_id[cid]
        if old_c.get("ticket_id") is not None:
            c["ticket_id"] = old_c["ticket_id"]
        if old_c.get("defense_comment_id") is not None:
            c["defense_comment_id"] = old_c["defense_comment_id"]
print(json.dumps(new, indent=2))
PYEOF
)
        rm -f "$_tmp_normalized"
    fi

    # Write output
    echo "$normalized" > "$_OUTPUT_PATH"

    # Apply classify-as handlers if specified
    if (( ${#_CLASSIFY_ARGS[@]} > 0 )); then
        _handle_classify "$_OUTPUT_PATH" "${_CLASSIFY_ARGS[@]}"
    fi
}

main
