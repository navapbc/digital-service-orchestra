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

    _SLOT_CORRECTNESS="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-correctness.json"
    _SLOT_VERIFICATION="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-verification.json"
    _SLOT_HYGIENE="${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-hygiene.json"

    # Step 1: dispatch 3 specialist llm-api-call.sh invocations in parallel (& + wait).
    # Each call delegates to llm-api-call.sh; stdout is redirected to the slot file.
    _SPECIALIST_PIDS=()
    bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-correctness.md" \
      "$(printf 'Review this diff:\n\n%s' "$DIFF_CONTENT")" "deep" > "$_SLOT_CORRECTNESS" &
    _SPECIALIST_PIDS+=($!)

    bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-verification.md" \
      "$(printf 'Review this diff:\n\n%s' "$DIFF_CONTENT")" "deep" > "$_SLOT_VERIFICATION" &
    _SPECIALIST_PIDS+=($!)

    bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-hygiene.md" \
      "$(printf 'Review this diff:\n\n%s' "$DIFF_CONTENT")" "deep" > "$_SLOT_HYGIENE" &
    _SPECIALIST_PIDS+=($!)

    for _pid in "${_SPECIALIST_PIDS[@]}"; do wait "$_pid"; done

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

    _ARCH_RESP=$(bash "$(command -v llm-api-call.sh)" "$_PLUGIN_ROOT/agents/code-reviewer-deep-arch.md" \
      "$_ARCH_USER_MSG" "deep")
    FINDINGS_JSON=$(printf '%s' "$_ARCH_RESP" | python3 -c "
import json,sys; t=sys.stdin.read().strip()
if not t: raise ValueError('empty')
json.loads(t); print(t)
" 2>/dev/null) || {
      echo "WARNING: Arch LLM response could not be parsed as reviewer-findings JSON." >&2
      FINDINGS_JSON='{"scores":{"hygiene":"N/A","design":"N/A","maintainability":"N/A","correctness":"N/A","verification":"N/A"},"findings":[],"summary":"Review inconclusive: Arch response could not be parsed."}'
    }

    # FINDINGS_JSON now set; fall through to shared overlay+write+record path.
    ;;
  *) echo "ERROR: Unknown tier: $SELECTED_TIER" >&2; exit 1 ;;
esac

# ── Standard / light tier: llm-api-call.sh → FINDINGS_JSON ───────────────────
# Skipped for deep tier (FINDINGS_JSON already set above by arch synthesis).
if [[ "$SELECTED_TIER" != "deep" ]]; then
LLM_TEXT=$(bash "$(command -v llm-api-call.sh)" "$AGENT_FILE" \
  "$(printf 'Review this diff:\n\n%s' "$DIFF_CONTENT")" "$SELECTED_TIER") || LLM_TEXT=""
FINDINGS_JSON=$(printf '%s' "${LLM_TEXT:-}" | python3 -c "
import json,sys; t=sys.stdin.read().strip()
if not t: raise ValueError('empty')
json.loads(t); print(t)
" 2>/dev/null) || {
  echo "WARNING: LLM response parsing failed. Writing inconclusive review." >&2
  FINDINGS_JSON='{"scores":{"hygiene":"N/A","design":"N/A","maintainability":"N/A","correctness":"N/A","verification":"N/A"},"findings":[],"summary":"Review inconclusive: LLM response could not be parsed as reviewer-findings JSON."}'
}
fi  # end standard/light-only API call block

# ── Overlay dispatch ────────────────────────────────────────────────────────────
# Dispatch parallel overlay llm-api-call.sh calls for each active overlay flag; write each
# reviewer's LLM text to a slot file in WORKFLOW_PLUGIN_ARTIFACTS_DIR.  Serial
# blue-team runs after red-team when security overlay is active.
# Applies to all tiers (deep FINDINGS_JSON carries through from arch synthesis).
_run_overlay_llm() {
  local _agent_file="$1" _slot_file="$2"
  bash "$(command -v llm-api-call.sh)" "$_agent_file" \
    "$(printf 'Review this diff:\n\n%s' "$DIFF_CONTENT")" "deep" > "$_slot_file" || true
}

_OVERLAY_PIDS=()
[[ "$_SEC"  == "true" ]] && {
  _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-security-red-team.md" \
    "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-red.json" &
  _OVERLAY_PIDS+=($!)
}
[[ "$_PERF" == "true" ]] && {
  _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-performance.md" \
    "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-performance.json" &
  _OVERLAY_PIDS+=($!)
}
[[ "$_TQ"   == "true" ]] && {
  _run_overlay_llm "$_PLUGIN_ROOT/agents/code-reviewer-test-quality.md" \
    "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-test-quality.json" &
  _OVERLAY_PIDS+=($!)
}
if [[ ${#_OVERLAY_PIDS[@]} -gt 0 ]]; then
  for _pid in "${_OVERLAY_PIDS[@]}"; do wait "$_pid" || true; done
fi
[[ "$_SEC" == "true" ]] && { _run_overlay_llm \
  "$_PLUGIN_ROOT/agents/code-reviewer-security-blue-team.md" \
  "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings-security-blue.json" || true; }

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

REVIEWER_HASH=$(echo "$FINDINGS_JSON" | bash "$(command -v write-reviewer-findings.sh)" --review-tier "$REVIEW_TIER" --selected-tier "$SELECTED_TIER")

bash "$(command -v record-review.sh)" --reviewer-hash "$REVIEWER_HASH"
REVIEW_STATUS=$(head -1 "${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/review-status" 2>/dev/null || echo "")
if [[ "$REVIEW_STATUS" == "failed" ]]; then
  echo "Review FAILED" >&2
  exit 1
fi
echo "Review passed"
