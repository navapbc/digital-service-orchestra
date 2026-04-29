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

# Merge with any pre-existing overlay flags (OR semantics: upstream pipeline may have set flags).
if [[ -f "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/overlay-flags.env" ]]; then
  _prev_sec=$(grep '^security_overlay='     "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/overlay-flags.env" | cut -d= -f2 || true)
  _prev_perf=$(grep '^performance_overlay=' "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/overlay-flags.env" | cut -d= -f2 || true)
  _prev_tq=$(grep '^test_quality_overlay='  "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/overlay-flags.env" | cut -d= -f2 || true)
  [[ "$_prev_sec"  == "true" ]] && _SEC=true
  [[ "$_prev_perf" == "true" ]] && _PERF=true
  [[ "$_prev_tq"   == "true" ]] && _TQ=true
fi

# Write overlay flags to artifacts dir for downstream overlay dispatch (Story 3 contract).
# Format: KEY=value, one per line, sourced as bash or read line-by-line.
printf 'security_overlay=%s\nperformance_overlay=%s\ntest_quality_overlay=%s\n' \
  "$_SEC" "$_PERF" "$_TQ" > "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/overlay-flags.env"

REVIEW_TIER="$SELECTED_TIER"
case "$SELECTED_TIER" in
  light)    AGENT_FILE="$_PLUGIN_ROOT/agents/code-reviewer-light.md" ;;
  standard) AGENT_FILE="$_PLUGIN_ROOT/agents/code-reviewer-standard.md" ;;
  deep)
    REVIEW_TIER="deep"
    MODEL="${DSO_LLM_MODEL:-claude-sonnet-4-6}"

    _SLOT_CORRECTNESS="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-correctness.json"
    _SLOT_VERIFICATION="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-verification.json"
    _SLOT_HYGIENE="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-hygiene.json"

    # Helper: build API request JSON for a specialist agent
    _build_specialist_request() {
      local _agent_file="$1"
      local _sys
      _sys="$(cat "$_agent_file")"
      DSO_SYSTEM="$_sys" DSO_DIFF="$DIFF_CONTENT" DSO_MODEL="$MODEL" \
        python3 - <<'PYEOF'
import json, os
print(json.dumps({
  'model': os.environ['DSO_MODEL'],
  'max_tokens': 8192,
  'system': os.environ['DSO_SYSTEM'],
  'messages': [{'role': 'user', 'content': 'Review this diff:\n\n' + os.environ['DSO_DIFF']}]
}))
PYEOF
    }

    # Step 1: dispatch 3 specialist curl calls sequentially.
    # Each call fires the API request; the specialist agent (or mock) is responsible for
    # writing its slot file. In production this would be a full agent sub-process; in CI
    # tests the mock curl writes the slot file as a side-effect.
    _REQ_C=$(_build_specialist_request "$_PLUGIN_ROOT/agents/code-reviewer-deep-correctness.md")
    curl -sf -m 30 --retry 3 --retry-delay 5 --connect-timeout 10 \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      --data-raw "$_REQ_C" \
      "https://api.anthropic.com/v1/messages" > /dev/null

    _REQ_V=$(_build_specialist_request "$_PLUGIN_ROOT/agents/code-reviewer-deep-verification.md")
    curl -sf -m 30 --retry 3 --retry-delay 5 --connect-timeout 10 \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      --data-raw "$_REQ_V" \
      "https://api.anthropic.com/v1/messages" > /dev/null

    _REQ_H=$(_build_specialist_request "$_PLUGIN_ROOT/agents/code-reviewer-deep-hygiene.md")
    curl -sf -m 30 --retry 3 --retry-delay 5 --connect-timeout 10 \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      --data-raw "$_REQ_H" \
      "https://api.anthropic.com/v1/messages" > /dev/null

    # Step 2: validate all slot files exist and contain valid JSON (fail-closed)
    for _slot in "$_SLOT_CORRECTNESS" "$_SLOT_VERIFICATION" "$_SLOT_HYGIENE"; do
      if [[ ! -f "$_slot" ]]; then
        echo "ERROR: deep-tier slot file missing: $_slot" >&2
        exit 1
      fi
      if ! python3 -c "import json,sys; json.load(open('$_slot'))" 2>/dev/null; then
        echo "ERROR: deep-tier slot file contains invalid JSON: $_slot" >&2
        exit 1
      fi
    done

    # Step 3: dispatch arch agent with slot file contents for synthesis
    _SLOT_C_JSON=$(cat "$_SLOT_CORRECTNESS")
    _SLOT_V_JSON=$(cat "$_SLOT_VERIFICATION")
    _SLOT_H_JSON=$(cat "$_SLOT_HYGIENE")
    _ARCH_USER_MSG="Synthesize these specialist reviews into a unified reviewer-findings JSON.

Correctness specialist findings:
${_SLOT_C_JSON}

Verification specialist findings:
${_SLOT_V_JSON}

Hygiene/Design/Maintainability specialist findings:
${_SLOT_H_JSON}

Diff under review:
${DIFF_CONTENT}"

    _ARCH_SYS="$(cat "$_PLUGIN_ROOT/agents/code-reviewer-deep-arch.md")"
    _ARCH_REQ=$(DSO_SYSTEM="$_ARCH_SYS" DSO_MODEL="$MODEL" DSO_ARCH_MSG="$_ARCH_USER_MSG" \
      python3 - <<'PYEOF'
import json, os
print(json.dumps({
  'model': os.environ['DSO_MODEL'],
  'max_tokens': 8192,
  'system': os.environ['DSO_SYSTEM'],
  'messages': [{'role': 'user', 'content': os.environ['DSO_ARCH_MSG']}]
}))
PYEOF
)
    _ARCH_RESP=$(curl -sf -m 30 --retry 3 --retry-delay 5 --connect-timeout 10 \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      --data-raw "$_ARCH_REQ" \
      "https://api.anthropic.com/v1/messages")

    _ARCH_TEXT=$(printf '%s\n' "$_ARCH_RESP" | python3 -c "
import json, sys, re
data = sys.stdin.read()
try:
    d = json.loads(data)
    print(d['content'][0]['text'])
    sys.exit(0)
except Exception:
    pass
m = re.search(r'\"text\"\s*:\s*\"([\s\S]+?)\"(?=\s*\}\s*\])', data)
if m:
    print(m.group(1))
    sys.exit(0)
print('ERROR: Cannot extract text from arch API response', file=sys.stderr)
sys.exit(1)
")

    FINDINGS_JSON=$(DSO_LLM_TEXT="$_ARCH_TEXT" python3 - <<'PYEOF'
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
print('ERROR: Arch LLM response is not valid reviewer-findings JSON', file=sys.stderr)
sys.exit(1)
PYEOF
)

    # FINDINGS_JSON now set; fall through to shared overlay+write+record path.
    ;;
  *) echo "ERROR: Unknown tier: $SELECTED_TIER" >&2; exit 1 ;;
esac

# ── Standard / light tier: API call → FINDINGS_JSON ───────────────────────────
# Skipped for deep tier (FINDINGS_JSON already set above by arch synthesis).
if [[ "$SELECTED_TIER" != "deep" ]]; then
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
fi  # end standard/light-only API call block

# ── Overlay dispatch ────────────────────────────────────────────────────────────
# Dispatch parallel overlay curl calls for each active overlay flag; write each
# reviewer's LLM text to a slot file in WORKFLOW_PLUGIN_ARTIFACTS_DIR.  Serial
# blue-team runs after red-team when security overlay is active.
# Applies to all tiers (deep FINDINGS_JSON carries through from arch synthesis).
_run_overlay_curl() {
  local _agent_file="$1" _slot_file="$2"
  local _sys _req _resp
  _sys="$(cat "$_agent_file")"
  _req=$(DSO_SYSTEM="$_sys" DSO_DIFF="$DIFF_CONTENT" DSO_MODEL="$MODEL" \
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
  _resp=$(curl -sf -m 30 --retry 3 --retry-delay 5 --connect-timeout 10 \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    --data-raw "$_req" \
    "https://api.anthropic.com/v1/messages")
  # Extract text from API response, then strip markdown fences to get bare JSON.
  # Overlay agents may wrap their JSON output in ```json...``` fences.
  DSO_OVERLAY_RESP="$_resp" python3 - <<'PYEOF' > "$_slot_file"
import json, sys, re, os
data = os.environ['DSO_OVERLAY_RESP']
# Extract text content from Anthropic API response envelope
text = None
try:
    d = json.loads(data)
    text = d['content'][0]['text']
except Exception:
    pass
if text is None:
    m = re.search(r'"text"\s*:\s*"([\s\S]+?)"(?=\s*\}\s*\])', data)
    if m:
        text = m.group(1)
if text is None:
    print('ERROR: Cannot extract overlay text from API response', file=sys.stderr)
    sys.exit(1)
# Strip markdown fences; overlay agents may return ```json...```
text = text.strip()
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
print('ERROR: Overlay LLM response is not valid reviewer-findings JSON', file=sys.stderr)
sys.exit(1)
PYEOF
}

_OVERLAY_PIDS=()
[[ "$_SEC"  == "true" ]] && {
  _run_overlay_curl "$_PLUGIN_ROOT/agents/code-reviewer-security-red-team.md" \
    "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-red.json" &
  _OVERLAY_PIDS+=($!)
}
[[ "$_PERF" == "true" ]] && {
  _run_overlay_curl "$_PLUGIN_ROOT/agents/code-reviewer-performance.md" \
    "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-performance.json" &
  _OVERLAY_PIDS+=($!)
}
[[ "$_TQ"   == "true" ]] && {
  _run_overlay_curl "$_PLUGIN_ROOT/agents/code-reviewer-test-quality.md" \
    "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-test-quality.json" &
  _OVERLAY_PIDS+=($!)
}
if [[ ${#_OVERLAY_PIDS[@]} -gt 0 ]]; then
  for _pid in "${_OVERLAY_PIDS[@]}"; do wait "$_pid"; done
fi
[[ "$_SEC" == "true" ]] && _run_overlay_curl \
  "$_PLUGIN_ROOT/agents/code-reviewer-security-blue-team.md" \
  "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-blue.json"

# ── Overlay merge ───────────────────────────────────────────────────────────────
# Collect non-empty overlay slot files and merge their findings arrays + scores
# (min per dimension, conservative) into FINDINGS_JSON before writing canonical
# reviewer-findings.json.  Overlay findings are additive; scores only decrease.
_OVERLAY_SLOTS=()
[[ "$_SEC"  == "true" ]] && {
  [[ -s "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-red.json" ]] && \
    _OVERLAY_SLOTS+=("${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-red.json")
  [[ -s "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-blue.json" ]] && \
    _OVERLAY_SLOTS+=("${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-blue.json")
}
[[ "$_PERF" == "true" ]] && \
  [[ -s "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-performance.json" ]] && \
    _OVERLAY_SLOTS+=("${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-performance.json")
[[ "$_TQ"   == "true" ]] && \
  [[ -s "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-test-quality.json" ]] && \
    _OVERLAY_SLOTS+=("${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-test-quality.json")

if [[ ${#_OVERLAY_SLOTS[@]} -gt 0 ]]; then
  FINDINGS_JSON=$(DSO_TIER_JSON="$FINDINGS_JSON" python3 - "${_OVERLAY_SLOTS[@]}" <<'PYEOF'
import json, sys, os

tier = json.loads(os.environ['DSO_TIER_JSON'])
merged_findings = list(tier.get('findings', []))
merged_scores   = dict(tier.get('scores', {}))

for slot_path in sys.argv[1:]:
    try:
        with open(slot_path) as fh:
            overlay = json.load(fh)
    except Exception:
        continue  # skip unreadable/invalid slot files (fail-open)
    merged_findings.extend(overlay.get('findings', []))
    for dim, val in overlay.get('scores', {}).items():
        if isinstance(val, (int, float)) and isinstance(merged_scores.get(dim), (int, float)):
            merged_scores[dim] = min(merged_scores[dim], val)
        elif isinstance(val, (int, float)) and dim not in merged_scores:
            merged_scores[dim] = val

result = dict(tier)
result['findings'] = merged_findings
result['scores']   = merged_scores
print(json.dumps(result))
PYEOF
  )
fi

REVIEWER_HASH=$(echo "$FINDINGS_JSON" | bash "$(command -v write-reviewer-findings.sh)" --review-tier "$REVIEW_TIER" --selected-tier "$SELECTED_TIER")

bash "$(command -v record-review.sh)" --reviewer-hash "$REVIEWER_HASH"
REVIEW_STATUS=$(head -1 "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/review-status" 2>/dev/null || echo "")
if [[ "$REVIEW_STATUS" == "failed" ]]; then
  echo "Review FAILED" >&2
  exit 1
fi
echo "Review passed"
