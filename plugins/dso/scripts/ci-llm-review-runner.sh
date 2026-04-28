#!/usr/bin/env bash
set -euo pipefail

# Do not set CLAUDE_PLUGIN_ROOT in CI env — _PLUGIN_ROOT is self-resolved from BASH_SOURCE
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Append plugin script dirs to PATH so PATH-based mocks in tests take precedence,
# and production scripts are found via the appended dirs when no mock is present.
export PATH="$PATH:$_PLUGIN_ROOT/scripts:$_PLUGIN_ROOT/hooks"

# All downstream scripts use WORKFLOW_PLUGIN_ARTIFACTS_DIR via get_artifacts_dir().
# Export it here so runner + write-reviewer-findings.sh + record-review.sh all share one location.
if [[ -z "${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-}" ]]; then
  WORKFLOW_PLUGIN_ARTIFACTS_DIR=$(mktemp -d /tmp/ci-llm-review.XXXXXX)
  export WORKFLOW_PLUGIN_ARTIFACTS_DIR
fi

OVERLAY_SECURITY=false; OVERLAY_PERFORMANCE=false; OVERLAY_TEST_QUALITY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --overlay-security)     OVERLAY_SECURITY=true; shift ;;
    --overlay-performance)  OVERLAY_PERFORMANCE=true; shift ;;
    --overlay-test-quality) OVERLAY_TEST_QUALITY=true; shift ;;
    *) echo "ERROR: Unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${ANTHROPIC_API_KEY:-}" ]] && { echo "ERROR: ANTHROPIC_API_KEY is required" >&2; exit 1; }

DIFF_CONTENT="$(cat)"  # Caller must pipe: gh pr diff | bash runner.sh

if [[ -z "$(printf '%s' "$DIFF_CONTENT" | tr -d '[:space:]')" ]]; then
  echo "No diff to review, skipping" >&2
  exit 0
fi

CLASSIFIER_JSON=$(printf '%s\n' "$DIFF_CONTENT" | bash "$(command -v review-complexity-classifier.sh)")
SELECTED_TIER=$(printf '%s\n' "$CLASSIFIER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['selected_tier'])")

# Extract overlay flags from classifier output; CLI --overlay-* flags act as OR override.
read -r _SEC _PERF _TQ < <(printf '%s\n' "$CLASSIFIER_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(str(d.get('security_overlay',False)).lower(),
      str(d.get('performance_overlay',False)).lower(),
      str(d.get('test_quality_overlay',False)).lower())")
[[ "$OVERLAY_SECURITY" == "true" ]]     && _SEC=true
[[ "$OVERLAY_PERFORMANCE" == "true" ]]  && _PERF=true
[[ "$OVERLAY_TEST_QUALITY" == "true" ]] && _TQ=true

# Write overlay flags to artifacts dir for downstream overlay dispatch (Story 3 contract).
# Format: KEY=value, one per line, sourced as bash or read line-by-line.
printf 'security_overlay=%s\nperformance_overlay=%s\ntest_quality_overlay=%s\n' \
  "$_SEC" "$_PERF" "$_TQ" > "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/overlay-flags.env"

REVIEW_TIER="$SELECTED_TIER"
case "$SELECTED_TIER" in
  light)    AGENT_FILE="$_PLUGIN_ROOT/agents/code-reviewer-light.md" ;;
  standard) AGENT_FILE="$_PLUGIN_ROOT/agents/code-reviewer-standard.md" ;;
  deep)
    # CI single-runner context: multi-agent deep dispatch not supported.
    # Fall back to standard agent as a single-pass approximation.
    echo "INFO: deep tier selected; using standard agent (multi-agent deep not available in CI)" >&2
    REVIEW_TIER="standard"
    AGENT_FILE="$_PLUGIN_ROOT/agents/code-reviewer-standard.md" ;;
  *) echo "ERROR: Unknown tier: $SELECTED_TIER" >&2; exit 1 ;;
esac
SYSTEM_PROMPT="$(cat "$AGENT_FILE")"

MODEL="${DSO_LLM_MODEL:-claude-sonnet-4-6}"

# Use env vars to avoid quoting hazards for arbitrary agent/diff content.
# Note: no pipe before python3 - <<HEREDOC so the heredoc IS the script input.
REQUEST_JSON=$(DSO_SYSTEM="$SYSTEM_PROMPT" DSO_DIFF="$DIFF_CONTENT" DSO_MODEL="$MODEL" \
  python3 - <<'PYEOF'
import json, os
print(json.dumps({
  'model': os.environ['DSO_MODEL'],
  'max_tokens': 8192,
  'system': os.environ['DSO_SYSTEM'],
  'messages': [{'role': 'user', 'content': 'Review this diff:\n\n' + os.environ['DSO_DIFF']}]
}))
PYEOF
)

API_RESPONSE=$(curl -sf -m 30 --connect-timeout 10 \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  --data-raw "$REQUEST_JSON" \
  "https://api.anthropic.com/v1/messages")

LLM_TEXT=$(printf '%s\n' "$API_RESPONSE" | python3 -c "
import json, sys, re
data = sys.stdin.read()
# Primary: standard JSON parsing
try:
    d = json.loads(data)
    print(d['content'][0]['text'])
    sys.exit(0)
except Exception:
    pass
# Fallback: regex extraction when API response contains literal newlines/unescaped
# content in the text field (non-standard but handles some edge cases in tests/CI).
# Looks for 'text':'<CONTENT>'}] to find the closing quote reliably.
m = re.search(r'\"text\"\s*:\s*\"([\s\S]+?)\"(?=\s*\}\s*\])', data)
if m:
    print(m.group(1))
    sys.exit(0)
print('ERROR: Cannot extract text from API response', file=sys.stderr)
sys.exit(1)
")

# Extract structured reviewer-findings JSON from potential markdown code fence wrapping.
# LLM_TEXT is passed via env var to avoid pipe+heredoc conflict (pipe would override heredoc stdin).
FINDINGS_JSON=$(DSO_LLM_TEXT="$LLM_TEXT" python3 - <<'PYEOF'
import sys, re, json, os
text = os.environ['DSO_LLM_TEXT'].strip()
try:
    json.loads(text)
    print(text)
    sys.exit(0)
except Exception:
    pass
m = re.search(r'```(?:json)?\s*([\s\S]+?)```', text)
if m:
    extracted = m.group(1).strip()
    json.loads(extracted)
    print(extracted)
    sys.exit(0)
print('ERROR: LLM response is not valid reviewer-findings JSON', file=sys.stderr)
sys.exit(1)
PYEOF
)

REVIEWER_HASH=$(echo "$FINDINGS_JSON" | bash "$(command -v write-reviewer-findings.sh)" --review-tier "$REVIEW_TIER" --selected-tier "$SELECTED_TIER")
bash "$(command -v record-review.sh)" --reviewer-hash "$REVIEWER_HASH"
REVIEW_STATUS=$(head -1 "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/review-status" 2>/dev/null || echo "")
if [[ "$REVIEW_STATUS" == "failed" ]]; then
  echo "Review FAILED" >&2
  exit 1
fi
echo "Review passed"
