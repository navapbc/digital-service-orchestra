#!/usr/bin/env bash
# llm-api-call.sh — Provider-agnostic LLM helper for the DSO CI pipeline.
#
# Usage:
#   llm-api-call.sh <system-prompt-file> <user-message> <tier> [<config-file>]
#
# Arguments:
#   system-prompt-file  — path to agent markdown file (system prompt)
#   user-message        — string content for the LLM to process
#   tier                — "light" | "standard" | "deep" (resolved via model.<tier> config key)
#   config-file         — optional; defaults to .claude/dso-config.conf at repo root
#
# Environment:
#   ANTHROPIC_API_KEY   — required when model.provider=anthropic
#   OPENAI_API_KEY      — required when model.provider=openai
#
# Output: normalized LLM response text on stdout (markdown fences stripped if present)
# Errors: diagnostic line on stderr, non-zero exit

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 3 ]]; then
    echo "Usage: llm-api-call.sh <system-prompt-file> <user-message> <tier> [<config-file>]" >&2
    exit 1
fi

SYSTEM_PROMPT_FILE="$1"
USER_MESSAGE="$2"
TIER="$3"
CONFIG_FILE="${4:-$(git rev-parse --show-toplevel 2>/dev/null)/.claude/dso-config.conf}"

# ── Validate system prompt file ───────────────────────────────────────────────
if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
    echo "ERROR: system-prompt-file not found: $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi

# ── Config resolution ─────────────────────────────────────────────────────────
PROVIDER=""
MODEL_ID=""
if [[ -f "$CONFIG_FILE" ]]; then
    PROVIDER=$(grep "^model.provider=" "$CONFIG_FILE" | cut -d= -f2- | head -1)
    MODEL_ID=$(grep "^model.${TIER}=" "$CONFIG_FILE" | cut -d= -f2- | head -1)
fi
PROVIDER="${PROVIDER:-anthropic}"

if [[ -z "$MODEL_ID" ]]; then
    echo "ERROR: model.${TIER} not found in config: $CONFIG_FILE" >&2
    exit 1
fi

# ── API key validation ────────────────────────────────────────────────────────
if [[ "$PROVIDER" == "anthropic" ]]; then
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        echo "ERROR: ANTHROPIC_API_KEY is required" >&2
        exit 1
    fi
elif [[ "$PROVIDER" == "openai" ]]; then
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        echo "ERROR: OPENAI_API_KEY is required" >&2
        exit 1
    fi
else
    echo "ERROR: Unknown provider: $PROVIDER (expected 'anthropic' or 'openai')" >&2
    exit 1
fi

# ── Read system prompt ────────────────────────────────────────────────────────
SYSTEM_PROMPT="$(cat "$SYSTEM_PROMPT_FILE")"

# ── CI-mode constraint appended to system prompt ─────────────────────────────
# Agent files are designed for Claude Code interactive tool use. When called
# via direct API (no tool definitions), the model would otherwise generate fake
# tool-call XML instead of clean JSON. This suffix overrides that behavior.
CI_MODE_SUFFIX="

CI-PIPELINE CONSTRAINT: This invocation is via direct API call — tool use is NOT available.
Do NOT attempt Bash, Read, or write-reviewer-findings.sh calls.
Your ENTIRE response MUST be a single valid JSON object conforming to the
reviewer-findings schema described above. No prose, no markdown fences, no tool calls."

SYSTEM_PROMPT="${SYSTEM_PROMPT}${CI_MODE_SUFFIX}"

# ── Build request body ────────────────────────────────────────────────────────
# Use environment variables to safely pass values into python3 (avoids shell injection
# in the heredoc and handles special characters in system prompt and user message).
_MSG_TMP=$(mktemp /tmp/llm-api-call-msg.XXXXXX)
_REQUEST_TMP=$(mktemp /tmp/llm-api-call-req.XXXXXX)
_RESPONSE_TMP=$(mktemp /tmp/llm-api-call-resp.XXXXXX)
# shellcheck disable=SC2064
trap "rm -f '$_MSG_TMP' '$_REQUEST_TMP' '$_RESPONSE_TMP'" EXIT
if [[ "$USER_MESSAGE" == @* ]]; then
    cat "${USER_MESSAGE#@}" > "$_MSG_TMP"
else
    printf '%s' "$USER_MESSAGE" > "$_MSG_TMP"
fi

DSO_SYSTEM="$SYSTEM_PROMPT" DSO_MSG_FILE="$_MSG_TMP" \
    DSO_PROVIDER="$PROVIDER" DSO_MODEL="$MODEL_ID" \
    DSO_CI="${GITHUB_ACTIONS:-}" python3 - <<'PYEOF' > "$_REQUEST_TMP"
import json, os
with open(os.environ['DSO_MSG_FILE']) as f:
    user_message = f.read()
if os.environ.get('DSO_CI'):
    user_message = 'REVIEW_CONTEXT: ci\n' + user_message
system_prompt = os.environ['DSO_SYSTEM']
provider = os.environ['DSO_PROVIDER']
model_id = os.environ['DSO_MODEL']

if provider == "anthropic":
    body = {
        "model": model_id,
        "max_tokens": 4096,
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_message}]
    }
else:
    body = {
        "model": model_id,
        "max_completion_tokens": 4096,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message}
        ]
    }
print(json.dumps(body))
PYEOF

# ── Execute curl and handle errors ────────────────────────────────────────────
# Use --data-binary @file to avoid MAX_ARG_STRLEN (128KB) per-argument limit on
# Linux when the diff + system prompt produce a large JSON request body.

_CURL_EXIT=0
_CURL_CONFIG_TMP="$(mktemp /tmp/llm-curl-cfg.XXXXXX)"
if [[ "$PROVIDER" == "anthropic" ]]; then
    printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\nheader = "content-type: application/json"\n' \
        "$ANTHROPIC_API_KEY" > "$_CURL_CONFIG_TMP"
    curl -s --fail-with-body --connect-timeout 10 --max-time 120 \
        --config "$_CURL_CONFIG_TMP" \
        --data-binary "@${_REQUEST_TMP}" \
        "https://api.anthropic.com/v1/messages" > "$_RESPONSE_TMP" 2>/dev/null || _CURL_EXIT=$?
else
    printf 'header = "Authorization: Bearer %s"\nheader = "content-type: application/json"\n' \
        "$OPENAI_API_KEY" > "$_CURL_CONFIG_TMP"
    curl -s --fail-with-body --connect-timeout 10 --max-time 120 \
        --config "$_CURL_CONFIG_TMP" \
        --data-binary "@${_REQUEST_TMP}" \
        "https://api.openai.com/v1/chat/completions" > "$_RESPONSE_TMP" 2>/dev/null || _CURL_EXIT=$?
fi
rm -f "$_CURL_CONFIG_TMP"

if [[ "$_CURL_EXIT" -ne 0 ]]; then
    # Extract error text from response body if available
    _ERROR_TEXT=""
    if [[ -s "$_RESPONSE_TMP" ]]; then
        _ERROR_TEXT=$(DSO_RESP_TMP="$_RESPONSE_TMP" python3 -c "
import json, os
try:
    with open(os.environ['DSO_RESP_TMP']) as f:
        d = json.load(f)
    msg = d.get('error', {})
    if isinstance(msg, dict):
        msg = msg.get('message', 'unknown error')
    print(msg)
except Exception:
    print('unknown error')
" 2>/dev/null || echo "unknown error")
    else
        _ERROR_TEXT="curl exit ${_CURL_EXIT}"
    fi
    echo "$PROVIDER $TIER $MODEL_ID $_ERROR_TEXT" >&2
    rm -f "$_RESPONSE_TMP"
    exit "$_CURL_EXIT"
fi

_RAW_RESPONSE="$(cat "$_RESPONSE_TMP")"
rm -f "$_RESPONSE_TMP"

# ── Normalize response envelope ───────────────────────────────────────────────
# Use python3 for extraction: handles both well-formed JSON and responses with
# literal (unescaped) newlines in the text field that would fail strict jq parsing.
if [[ "$PROVIDER" == "anthropic" ]]; then
    _LLM_TEXT=$(DSO_RAW_RESP="$_RAW_RESPONSE" python3 - <<'PYEOF'
import json, sys, re, os
data = os.environ['DSO_RAW_RESP']
# Primary: standard JSON parsing
try:
    d = json.loads(data)
    print(d['content'][0]['text'], end='')
    sys.exit(0)
except Exception:
    pass
# Fallback: regex extraction for responses with literal newlines in text field
m = re.search(r'"text"\s*:\s*"([\s\S]+?)"(?=\s*\}\s*\])', data)
if m:
    # Unescape all standard JSON string escape sequences using json.loads on the
    # extracted fragment (wrap in quotes so json.loads treats it as a JSON string)
    raw = m.group(1)
    try:
        text = json.loads('"' + raw + '"')
        print(text, end='')
        sys.exit(0)
    except Exception:
        pass
    # Last-resort: minimal unescape for well-formed responses with only basic escapes
    text = raw.replace('\\"', '"').replace('\\n', '\n').replace('\\t', '\t').replace('\\\\', '\\')
    print(text, end='')
    sys.exit(0)
print('ERROR: Cannot extract text from Anthropic API response', file=sys.stderr)
sys.exit(1)
PYEOF
)
else
    _LLM_TEXT=$(DSO_RAW_RESP="$_RAW_RESPONSE" python3 - <<'PYEOF'
import json, sys, os
data = os.environ['DSO_RAW_RESP']
try:
    d = json.loads(data)
    print(d['choices'][0]['message']['content'], end='')
    sys.exit(0)
except Exception:
    pass
print('ERROR: Cannot extract content from OpenAI API response', file=sys.stderr)
sys.exit(1)
PYEOF
)
fi

# ── Strip markdown fences ─────────────────────────────────────────────────────
printf '%s' "$_LLM_TEXT" | python3 -c "
import sys, re
t = sys.stdin.read()
m = re.match(r'^[ \t]*\`\`\`(?:json)?\s*\n(.*?)\n\s*\`\`\`\s*$', t, re.DOTALL)
if m:
    print(m.group(1))
else:
    print(t, end='')
"
