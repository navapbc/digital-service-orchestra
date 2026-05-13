#!/usr/bin/env bash
# post-defense-to-coderabbit.sh
# Post a threaded defense reply to a CodeRabbit inline review comment.
#
# When the orchestrator decides to DEFEND (not fix) a finding that originated
# from CodeRabbit, this helper posts the defense text as a threaded reply on
# the originating inline comment and appends "@coderabbitai resolve" so
# CodeRabbit acknowledges the defense and marks the thread resolved.
#
# Usage:
#   post-defense-to-coderabbit.sh --pr <pr> --comment-id <id> --defense-text <text> [--repo <owner/repo>]
#   echo "<defense text>" | post-defense-to-coderabbit.sh --pr <pr> --comment-id <id>
#
# Required:
#   --pr <n>            PR number
#   --comment-id <id>   Numeric ID of the CodeRabbit inline review comment
#   --defense-text <s>  Defense rationale (or pipe via stdin)
#
# Optional:
#   --repo <owner/repo>     Defaults to the current repo (gh resolves)
#   --no-resolve            Skip the trailing "@coderabbitai resolve" line
#   --no-author-check       Skip the coderabbitai[bot] author check (for tests)
#
# Exit codes:
#   0 — reply posted successfully
#   2 — argument error
#   3 — comment is not authored by coderabbitai[bot] (refusing to post)
#   4 — GitHub API error
#
# Environment:
#   GH_CMD                  Override the `gh` binary (for tests). Default: gh.

set -uo pipefail

_pr=""
_comment_id=""
_defense_text=""
_repo=""
_add_resolve=1
_check_author=1

_usage() {
  cat >&2 <<'EOF'
usage: post-defense-to-coderabbit.sh --pr <n> --comment-id <id> [--defense-text <s>] [--repo <owner/repo>] [--no-resolve] [--no-author-check]
       (defense text may also be supplied on stdin)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      [[ $# -lt 2 ]] && { echo "--pr requires a value" >&2; _usage; exit 2; }
      _pr="$2"; shift 2 ;;
    --comment-id)
      [[ $# -lt 2 ]] && { echo "--comment-id requires a value" >&2; _usage; exit 2; }
      _comment_id="$2"; shift 2 ;;
    --defense-text)
      [[ $# -lt 2 ]] && { echo "--defense-text requires a value" >&2; _usage; exit 2; }
      _defense_text="$2"; shift 2 ;;
    --repo)
      [[ $# -lt 2 ]] && { echo "--repo requires a value" >&2; _usage; exit 2; }
      _repo="$2"; shift 2 ;;
    --no-resolve) _add_resolve=0; shift ;;
    --no-author-check) _check_author=0; shift ;;
    -h|--help) _usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; _usage; exit 2 ;;
  esac
done

if [[ -z "$_pr" || -z "$_comment_id" ]]; then
  echo "--pr and --comment-id are required" >&2
  _usage
  exit 2
fi

if ! [[ "$_pr" =~ ^[0-9]+$ ]]; then
  echo "--pr must be a positive integer: $_pr" >&2; exit 2
fi
if ! [[ "$_comment_id" =~ ^[0-9]+$ ]]; then
  echo "--comment-id must be a positive integer: $_comment_id" >&2; exit 2
fi

# Read defense text from stdin if not supplied as a flag.
if [[ -z "$_defense_text" ]] && [[ ! -t 0 ]]; then
  _defense_text=$(cat)
fi
if [[ -z "$_defense_text" ]]; then
  echo "defense text is required (via --defense-text or stdin)" >&2
  exit 2
fi

GH="${GH_CMD:-gh}"

# Resolve repo if not supplied.
if [[ -z "$_repo" ]]; then
  _repo=$($GH repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  if [[ -z "$_repo" ]]; then
    echo "unable to resolve repo — pass --repo <owner/repo>" >&2; exit 2
  fi
fi

# Author check — refuse to post unless the comment is from coderabbitai[bot].
# Bypassable via --no-author-check for tests.
if [[ "$_check_author" -eq 1 ]]; then
  _author=$($GH api "repos/${_repo}/pulls/comments/${_comment_id}" --jq .user.login 2>/dev/null || true)
  if [[ -z "$_author" ]]; then
    echo "GitHub API: could not fetch comment ${_comment_id} on ${_repo}" >&2
    exit 4
  fi
  if [[ "$_author" != "coderabbitai[bot]" && "$_author" != "coderabbitai" ]]; then
    echo "comment ${_comment_id} is authored by '${_author}', not coderabbitai[bot]; refusing to post" >&2
    exit 3
  fi
fi

# Build the reply body. Append @coderabbitai resolve as a separate paragraph
# so CodeRabbit's chat parser sees it as a directive rather than inline prose.
_body="$_defense_text"
if [[ "$_add_resolve" -eq 1 ]]; then
  _body="${_body}

@coderabbitai resolve"
fi

# Post the threaded reply.
_response=$(printf '%s' "$_body" | $GH api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "repos/${_repo}/pulls/${_pr}/comments/${_comment_id}/replies" \
  -f body=@- 2>&1) || {
  echo "GitHub API: failed to post reply: $_response" >&2
  exit 4
}

# Surface the reply URL for orchestrator logging.
_reply_url=$(echo "$_response" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('html_url',''))" 2>/dev/null || echo "")
if [[ -n "$_reply_url" ]]; then
  echo "Posted defense reply: $_reply_url"
fi
exit 0
