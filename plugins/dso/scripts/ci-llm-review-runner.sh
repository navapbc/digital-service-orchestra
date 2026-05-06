#!/usr/bin/env bash
set -euo pipefail

# Do not set CLAUDE_PLUGIN_ROOT in CI env — _PLUGIN_ROOT is self-resolved from BASH_SOURCE
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

_resolve_plugin_root() {
  local _scripts_dir _plugin_dir _marker_path
  _scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _plugin_dir="${_scripts_dir%/scripts}"
  _marker_path="$_plugin_dir/.dso-source-of-truth"
  if [[ -f "$_marker_path" ]]; then
    # Expose the BASH_SOURCE-resolved scripts dir so callers can add it to PATH.
    # Used when CLAUDE_PLUGIN_ROOT overrides _PLUGIN_ROOT (worktree/install mismatch).
    _BASH_SOURCE_SCRIPTS_DIR="$_scripts_dir"
    return 0
  fi
  if [[ -z "${DSO_ASSETS_DIR:-}" ]]; then
    echo "ERROR: DSO_ASSETS_DIR must be set for host-project CI (marker file not found)" >&2
    return 1
  fi
  _PLUGIN_ROOT="$DSO_ASSETS_DIR"
}
_resolve_plugin_root || exit 1

# Append plugin script dirs to PATH so PATH-based mocks in tests take precedence,
# and production scripts are found via the appended dirs when no mock is present.
# Also append the BASH_SOURCE-resolved scripts dir (may differ from _PLUGIN_ROOT/scripts
# when CLAUDE_PLUGIN_ROOT is set to a different install, e.g., in worktree sessions).
_extra_path=""
[[ -n "${_BASH_SOURCE_SCRIPTS_DIR:-}" && "$_BASH_SOURCE_SCRIPTS_DIR" != "$_PLUGIN_ROOT/scripts" ]] && \
  _extra_path=":$_BASH_SOURCE_SCRIPTS_DIR"
export PATH="$PATH:$_PLUGIN_ROOT/scripts:$_PLUGIN_ROOT/hooks${_extra_path}"

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


DIFF_CONTENT="$(cat)"  # Caller must pipe: gh pr diff | bash runner.sh

if [[ -z "$(printf '%s' "$DIFF_CONTENT" | tr -d '[:space:]')" ]]; then
  echo "No diff to review, skipping" >&2
  exit 0
fi

# Write diff message to temp files to avoid ARG_MAX limits on large diffs.
_DIFF_TMP=$(mktemp /tmp/ci-review-diff.XXXXXX)
_ARCH_TMP=$(mktemp /tmp/ci-review-arch-msg.XXXXXX)
# shellcheck disable=SC2064
trap "rm -f '$_DIFF_TMP' '$_ARCH_TMP'" EXIT
printf 'Review this diff:\n\n%s' "$DIFF_CONTENT" > "$_DIFF_TMP"

CLASSIFIER_JSON=$(printf '%s\n' "$DIFF_CONTENT" | bash "$(command -v review-complexity-classifier.sh)")
SELECTED_TIER=$(printf '%s\n' "$CLASSIFIER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['selected_tier'])")
SIZE_ACTION=$(printf '%s\n' "$CLASSIFIER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('size_action','none'))")
# size_action=upgrade overrides selected_tier upward to deep regardless of classifier score.
[[ "$SIZE_ACTION" == "upgrade" ]] && SELECTED_TIER="deep"
# size_action=warn is informational only; emit message to stderr but do not change tier.
[[ "$SIZE_ACTION" == "warn" ]] && echo "SIZE_WARNING: diff exceeds warn threshold — review proceeds at ${SELECTED_TIER} tier" >&2

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

# ── Overlay helper (hoisted to file scope; used by all tier branches) ─────────
_run_overlay_llm() {
  local _agent_file="$1" _slot_file="$2"
  bash "$(command -v llm-api-call.sh)" "$_agent_file" \
    "@${_DIFF_TMP}" "deep" > "$_slot_file" || true
}

# ── JSON extraction helper (hoisted; used by slot normalization and retry) ─────
# Scans LLM output for the best reviewer-findings JSON dict, stripping fences.
# Preference order: (1) dict with 'findings' key (top-level container),
# (2) dict with 'summary' key, (3) any valid dict.
# Prose braces ({text}) are not valid JSON; raw_decode skips them naturally.
# Prints the extracted JSON to stdout; exits 1 when no dict is found.
_extract_json_from_llm_text() {
  python3 -c "
import json, sys
t = sys.stdin.read().strip()
if not t:
    sys.exit(1)
t2 = t.lstrip('\`')
if t2.startswith('json'):
    t2 = t2[4:]
t2 = t2.strip()
dec = json.JSONDecoder()
pos = 0
best = None      # best candidate seen so far
best_score = 0   # 3=has findings, 2=has summary, 1=any dict
while pos < len(t2):
    i = t2.find('{', pos)
    if i < 0:
        break
    try:
        obj, end = dec.raw_decode(t2, i)
        if isinstance(obj, dict):
            score = 1
            if 'summary' in obj:
                score = 2
            if 'findings' in obj:
                score = 3
            if score > best_score:
                best = obj
                best_score = score
            if best_score == 3:
                break  # perfect match — no need to scan further
        # Advance past the parsed object so we never rewind into already-
        # consumed text. Using i+1 caused non-deterministic best-match
        # selection on inputs containing nested or sibling objects.
        pos = end
    except json.JSONDecodeError:
        pos = i + 1
if best is None:
    sys.exit(1)
print(json.dumps(best))
" 2>/dev/null
}

REVIEW_TIER="$SELECTED_TIER"
case "$SELECTED_TIER" in
  light|standard)
    AGENT_FILE="$_PLUGIN_ROOT/agents/code-reviewer-${SELECTED_TIER}.md"
    _TIER_SLOT="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-tier-raw.json"
    _ALL_PIDS=()

    # Launch tier and overlays concurrently.
    bash "$(command -v llm-api-call.sh)" "$AGENT_FILE" \
      "@${_DIFF_TMP}" "$SELECTED_TIER" > "$_TIER_SLOT" &
    _ALL_PIDS+=($!)

    [[ "$_SEC"  == "true" ]] && {
      _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-security-red-team.md" \
        "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-red.json" &
      _ALL_PIDS+=($!)
    }
    [[ "$_PERF" == "true" ]] && {
      _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-performance.md" \
        "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-performance.json" &
      _ALL_PIDS+=($!)
    }
    [[ "$_TQ"   == "true" ]] && {
      _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-test-quality.md" \
        "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-test-quality.json" &
      _ALL_PIDS+=($!)
    }

    for _pid in "${_ALL_PIDS[@]}"; do wait "$_pid" || true; done

    # Security blue-team runs serially after red-team slot is populated.
    [[ "$_SEC" == "true" ]] && {
      _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-security-blue-team.md" \
        "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-blue.json" || true
    }

    LLM_TEXT=$(cat "$_TIER_SLOT")
    FINDINGS_JSON=$(printf '%s' "${LLM_TEXT:-}" | python3 -c "
import json,sys; t=sys.stdin.read().strip()
if not t: raise ValueError('empty')
json.loads(t); print(t)
" 2>/dev/null) || {
      echo "WARNING: LLM response parsing failed. Writing inconclusive review." >&2
      FINDINGS_JSON='{"scores":{"hygiene":"N/A","design":"N/A","maintainability":"N/A","correctness":"N/A","verification":"N/A"},"findings":[],"summary":"Review inconclusive: LLM response could not be parsed as reviewer-findings JSON."}'
    }
    ;;
  deep)
    REVIEW_TIER="deep"

    _SLOT_CORRECTNESS="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-correctness.json"
    _SLOT_VERIFICATION="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-verification.json"
    _SLOT_HYGIENE="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-hygiene.json"

    # Launch 3 specialists and all overlays concurrently; single wait for all.
    _ALL_DEEP_PIDS=()
    bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-correctness.md" \
      "@${_DIFF_TMP}" "deep" > "$_SLOT_CORRECTNESS" &
    _ALL_DEEP_PIDS+=($!)

    bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-verification.md" \
      "@${_DIFF_TMP}" "deep" > "$_SLOT_VERIFICATION" &
    _ALL_DEEP_PIDS+=($!)

    bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-hygiene.md" \
      "@${_DIFF_TMP}" "deep" > "$_SLOT_HYGIENE" &
    _ALL_DEEP_PIDS+=($!)

    [[ "$_SEC"  == "true" ]] && {
      _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-security-red-team.md" \
        "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-red.json" &
      _ALL_DEEP_PIDS+=($!)
    }
    [[ "$_PERF" == "true" ]] && {
      _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-performance.md" \
        "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-performance.json" &
      _ALL_DEEP_PIDS+=($!)
    }
    [[ "$_TQ"   == "true" ]] && {
      _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-test-quality.md" \
        "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-test-quality.json" &
      _ALL_DEEP_PIDS+=($!)
    }

    # All are fired concurrently; wait for ALL before arch synthesis.
    for _pid in "${_ALL_DEEP_PIDS[@]}"; do wait "$_pid" || true; done

    # Security blue-team runs serially after red-team slot is populated.
    [[ "$_SEC" == "true" ]] && {
      _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-security-blue-team.md" \
        "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-blue.json" || true
    }

    # Normalize specialist slot files: extract first valid JSON object (handles LLM
    # responses with surrounding prose), then validate (fail-closed).
    for _slot in "$_SLOT_CORRECTNESS" "$_SLOT_VERIFICATION" "$_SLOT_HYGIENE"; do
      if [[ ! -f "$_slot" ]]; then
        echo "ERROR: deep-tier slot file missing: $_slot" >&2
        exit 1
      fi
      _slot_normalized=$(cat "$_slot" | _extract_json_from_llm_text) || true
      if [[ -n "$_slot_normalized" ]]; then
        printf '%s\n' "$_slot_normalized" > "$_slot"
      fi
      if ! python3 -c "import json,sys; json.load(open('$_slot'))" 2>/dev/null; then
        echo "ERROR: deep-tier slot file contains invalid JSON: $_slot" >&2
        exit 1
      fi
    done

    # Arch synthesis uses specialist slot files.
    _SLOT_C_JSON=$(cat "$_SLOT_CORRECTNESS")
    _SLOT_V_JSON=$(cat "$_SLOT_VERIFICATION")
    _SLOT_H_JSON=$(cat "$_SLOT_HYGIENE")
    _ARCH_USER_MSG="Synthesize these specialist reviews into a unified reviewer-findings JSON.

=== SONNET-A FINDINGS (correctness) ===
${_SLOT_C_JSON}

=== SONNET-B FINDINGS (verification) ===
${_SLOT_V_JSON}

=== SONNET-C FINDINGS (hygiene/design) ===
${_SLOT_H_JSON}

Diff under review:
${DIFF_CONTENT}"
    printf '%s' "$_ARCH_USER_MSG" > "$_ARCH_TMP"

    _ARCH_RESP=$(bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-arch.md" \
      "@${_ARCH_TMP}" "deep")
    FINDINGS_JSON=$(printf '%s' "$_ARCH_RESP" | _extract_json_from_llm_text) || {
      echo "WARNING: Arch LLM response could not be parsed as reviewer-findings JSON." >&2
      FINDINGS_JSON='{"scores":{"hygiene":"N/A","design":"N/A","maintainability":"N/A","correctness":"N/A","verification":"N/A"},"findings":[],"summary":"Review inconclusive: Arch response could not be parsed."}'
    }
    ;;
  *) echo "ERROR: Unknown tier: $SELECTED_TIER" >&2; exit 1 ;;
esac

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
        elif isinstance(val, (int, float)) and not isinstance(merged_scores.get(dim), (int, float)):
            # Replace N/A (or absent) with overlay's numeric score so a critical
            # overlay finding propagates even when the main tier was inconclusive.
            merged_scores[dim] = val

result = dict(tier)
result['findings'] = merged_findings
result['scores']   = merged_scores
print(json.dumps(result))
PYEOF
  )
fi

_VALIDATION_ERR_TMP=$(mktemp /tmp/ci-review-validation.XXXXXX)
_WRITE_RC=0
REVIEWER_HASH=$(echo "$FINDINGS_JSON" | bash "$(command -v write-reviewer-findings.sh)" --review-tier "$REVIEW_TIER" --selected-tier "$SELECTED_TIER" 2>"$_VALIDATION_ERR_TMP") || _WRITE_RC=$?

# Always surface validation errors so CI logs show the actual schema problem.
if [[ "$_WRITE_RC" -ne 0 ]]; then
  _VALIDATION_ERRORS=$(cat "$_VALIDATION_ERR_TMP" 2>/dev/null || true)
  echo "Schema validation failed:" >&2
  echo "$_VALIDATION_ERRORS" >&2
fi

# Single-shot retry with validation errors prepended to the user message.
# Covers both light/standard (via AGENT_FILE) and deep-tier (via _ARCH_TMP).
if [[ "$_WRITE_RC" -ne 0 ]]; then
  _RETRY_SUFFIX=$(printf '\n\nPREVIOUS ATTEMPT SCHEMA ERRORS — fix these in your JSON response:\n%s' "${_VALIDATION_ERRORS:-}")

  if [[ -n "${AGENT_FILE:-}" ]]; then
    # Light/standard: retry with diff + validation errors
    echo "Schema validation failed — retrying light/standard with validation errors in prompt" >&2
    _RETRY_TMP=$(mktemp /tmp/ci-review-retry.XXXXXX)
    printf '%s%s' "$DIFF_CONTENT" "$_RETRY_SUFFIX" > "$_RETRY_TMP"
    _RETRY_TEXT=$(bash "$(command -v llm-api-call.sh)" "$AGENT_FILE" \
      "@${_RETRY_TMP}" "$REVIEW_TIER" 2>/dev/null || true)
    rm -f "$_RETRY_TMP"
    _RETRY_JSON=$(printf '%s' "${_RETRY_TEXT:-}" | _extract_json_from_llm_text) || true
  elif [[ -n "${_ARCH_TMP:-}" && -f "${_ARCH_TMP:-/dev/null}" ]]; then
    # Deep-tier: retry arch synthesis with validation errors appended to its user message
    echo "Schema validation failed — retrying deep-tier arch with validation errors in prompt" >&2
    _RETRY_ARCH_TMP=$(mktemp /tmp/ci-review-arch-retry.XXXXXX)
    cat "$_ARCH_TMP" > "$_RETRY_ARCH_TMP"
    printf '%s' "$_RETRY_SUFFIX" >> "$_RETRY_ARCH_TMP"
    _RETRY_TEXT=$(bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-arch.md" \
      "@${_RETRY_ARCH_TMP}" "deep" 2>/dev/null || true)
    rm -f "$_RETRY_ARCH_TMP"
    _RETRY_JSON=$(printf '%s' "${_RETRY_TEXT:-}" | _extract_json_from_llm_text) || true
  fi

  if [[ -n "${_RETRY_JSON:-}" ]]; then
    _RETRY_HASH=""
    _RETRY_WRITE_RC=0
    _RETRY_HASH=$(echo "$_RETRY_JSON" | bash "$(command -v write-reviewer-findings.sh)" --review-tier "$REVIEW_TIER" --selected-tier "$SELECTED_TIER" 2>/dev/null) || _RETRY_WRITE_RC=$?
    if [[ "$_RETRY_WRITE_RC" -eq 0 && -n "$_RETRY_HASH" ]]; then
      REVIEWER_HASH="$_RETRY_HASH"
      FINDINGS_JSON="$_RETRY_JSON"
      _WRITE_RC=0
    fi
  fi
fi
rm -f "$_VALIDATION_ERR_TMP"

# Warn (non-blocking) when all findings are synthetic — no real review content was produced.
# This can happen when a fail-open design masks LLM parse failures (bug e840-327f).
if printf '%s' "$FINDINGS_JSON" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
findings = d.get('findings', [])
if not findings:
    sys.exit(0)
synthetic = {'specialist_error', 'fallback_exhausted'}
if findings and all(f.get('type','') in synthetic for f in findings):
    print('WARNING: all {} finding(s) are synthetic (fallback_exhausted/specialist_error) — real review content is absent; LLM may have returned unparseable output'.format(len(findings)), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
" 2>&1; then
    : # real findings present — no warning needed
fi

bash "$(command -v record-review.sh)" --reviewer-hash "${REVIEWER_HASH:-}"
REVIEW_STATUS=$(head -1 "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/review-status" 2>/dev/null || echo "")

# Always log the reviewer findings so CI output is actionable for agents and humans.
_findings_file="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings.json"
if [[ -f "$_findings_file" ]]; then
  echo ""
  echo "=== LLM Reviewer Findings ==="
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    summary = d.get('summary', '(no summary)')
    findings = d.get('findings', [])
    print('Summary:', summary)
    print('Findings:', len(findings))
    for i, f in enumerate(findings, 1):
        sev = f.get('severity', '?')
        cat = f.get('category', '?')
        desc = f.get('description', '')[:200]
        ffile = f.get('file', '')
        print(f'  [{i}] {sev.upper()} ({cat}): {desc}', flush=True)
        if ffile:
            print(f'       file: {ffile}', flush=True)
except Exception as e:
    print('(could not parse findings:', e, ')')
" "$_findings_file" 2>/dev/null || true
  echo "=== End LLM Reviewer Findings ==="
  echo ""
fi

if [[ "$REVIEW_STATUS" == "failed" ]]; then
  echo "Review FAILED" >&2
  exit 1
fi
echo "Review passed"
