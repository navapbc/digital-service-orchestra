#!/usr/bin/env bash
# scripts/end-session/bypass-surveillance.sh
# Surveillance sweep for session-merge-only bypass hatch usage.
#
# Globs .claude/artifacts/sprint-merge-only-bypass-*.log and
# .claude/artifacts/debug-merge-only-bypass-*.log, counts bypass entries
# (one line per log file), and when the count meets or exceeds
# end_session.bypass_alert_threshold (default: 3) it:
#   (a) emits an integrity-check warning listing bypass reasons to stderr
#   (b) files a follow-up bug ticket via `ticket create` capturing the pattern
#
# Log line format written by check-session-merge-only.sh:
#   DSO_SPRINT_ACTIVE=0 bypass: <ISO8601Z> PID=<pid> REASON=<reason>
#   DSO_DEBUG_ACTIVE=0 bypass: <ISO8601Z> PID=<pid> REASON=<reason>
#
# Usage (invoked by /dso:end-session Step 8b):
#   bash "$PLUGIN_SCRIPTS/end-session/bypass-surveillance.sh"  # shim-exempt: internal orchestration script
#
# Respects env vars (for testing):
#   TICKET_CMD       — override ticket CLI path
#   DSO_ARTIFACTS_DIR — override artifacts directory (default: $REPO_ROOT/.claude/artifacts)
#   BYPASS_ALERT_THRESHOLD — override threshold (falls back to config key)
#
# Exit codes:
#   0 — sweep complete (no bypass, or below threshold, or ticket filed successfully)
#   1 — ticket creation failed (sweep results still printed; non-fatal from caller)

set -uo pipefail

_BYPASS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKET_CMD="${TICKET_CMD:-${_BYPASS_SCRIPT_DIR%/*}/ticket}"

# ── Resolve repo root ─────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "bypass-surveillance: WARN: could not resolve REPO_ROOT — skipping sweep" >&2
    exit 0
fi

# ── Resolve artifacts directory ───────────────────────────────────────────────
ARTIFACTS_DIR="${DSO_ARTIFACTS_DIR:-$REPO_ROOT/.claude/artifacts}"

# ── Resolve threshold ─────────────────────────────────────────────────────────
# Read from config if not already overridden by BYPASS_ALERT_THRESHOLD env var.
if [[ -z "${BYPASS_ALERT_THRESHOLD:-}" ]]; then
    _PLUGIN_SCRIPTS_DIR="$_BYPASS_SCRIPT_DIR/.."
    _cfg_val=$(bash "$_PLUGIN_SCRIPTS_DIR/read-config.sh" end_session.bypass_alert_threshold 2>/dev/null || true)  # shim-exempt: internal orchestration script
    BYPASS_ALERT_THRESHOLD="${_cfg_val:-3}"
fi

# Validate threshold is a positive integer; fall back to default on bad value.
if ! [[ "$BYPASS_ALERT_THRESHOLD" =~ ^[0-9]+$ ]] || [[ "$BYPASS_ALERT_THRESHOLD" -lt 1 ]]; then
    echo "bypass-surveillance: WARN: invalid bypass_alert_threshold '${BYPASS_ALERT_THRESHOLD}' — using default 3" >&2
    BYPASS_ALERT_THRESHOLD=3
fi

# ── Collect bypass log files ──────────────────────────────────────────────────
mapfile -t _sprint_logs < <(ls -1 "$ARTIFACTS_DIR"/sprint-merge-only-bypass-*.log 2>/dev/null || true)
mapfile -t _debug_logs  < <(ls -1 "$ARTIFACTS_DIR"/debug-merge-only-bypass-*.log  2>/dev/null || true)

_all_logs=("${_sprint_logs[@]}" "${_debug_logs[@]}")
_count=${#_all_logs[@]}

if [[ $_count -eq 0 ]]; then
    # No bypass logs — nothing to do.
    exit 0
fi

# ── Parse bypass reasons from log files ──────────────────────────────────────
# Each log file written by check-session-merge-only.sh contains exactly one line.
# Sanitize reason text: strip control characters/newlines and cap at 200 chars to
# prevent log content from breaking ticket descriptions or injecting CLI args.
_reasons=()
for _log in "${_all_logs[@]}"; do
    [[ -f "$_log" ]] || continue
    _line=$(head -1 "$_log" 2>/dev/null || true)
    if [[ -n "$_line" ]]; then
        # Extract REASON= field from "DSO_*=0 bypass: <ts> PID=<pid> REASON=<reason>"
        _raw_reason=$(echo "$_line" | sed 's/.*REASON=//' 2>/dev/null || echo "(no reason recorded)")
        # Sanitize: strip control characters and newlines, then truncate to 200 chars
        _reason=$(printf '%s' "$_raw_reason" | tr -d '\000-\037\177' | cut -c1-200)
        [[ -z "$_reason" ]] && _reason="(no reason recorded)"
        _reasons+=("$_reason")
    fi
done

# ── Check threshold ───────────────────────────────────────────────────────────
if [[ $_count -lt "$BYPASS_ALERT_THRESHOLD" ]]; then
    # Below threshold — log count informally but do not alert.
    echo "bypass-surveillance: ${_count} bypass invocation(s) recorded (threshold: ${BYPASS_ALERT_THRESHOLD}) — below alert threshold." >&2
    # Archive logs so they are not re-counted on the next run.
    _archive_dir="${ARTIFACTS_DIR}/bypass-processed"
    mkdir -p "$_archive_dir" 2>/dev/null || true
    for _log in "${_all_logs[@]}"; do
        [[ -f "$_log" ]] && mv "$_log" "$_archive_dir/" 2>/dev/null || true
    done
    exit 0
fi

# ── Threshold met or exceeded — emit integrity warning ───────────────────────
echo "" >&2
echo "┌─────────────────────────────────────────────────────────────────────┐" >&2
echo "│ INTEGRITY WARNING: session-merge-only bypass hatch used ${_count} time(s) │" >&2
echo "└─────────────────────────────────────────────────────────────────────┘" >&2
echo "" >&2
echo "Bypass reasons recorded:" >&2
for i in "${!_reasons[@]}"; do
    echo "  $((i+1)). ${_reasons[$i]}" >&2
done
echo "" >&2
echo "Threshold: ${BYPASS_ALERT_THRESHOLD}. Artifacts in: ${ARTIFACTS_DIR}" >&2
echo "" >&2

# ── File a follow-up bug ticket ───────────────────────────────────────────────
_reasons_md=""
for i in "${!_reasons[@]}"; do
    _reasons_md+="$((i+1)). ${_reasons[$i]}"$'\n'
done

_description="## Incident Overview

* **Scenario Type:** Architectural Bypass Abuse
* **Detected by:** /dso:end-session bypass-surveillance Step 8b

### Expected Behavior

Session-merge-only bypass hatch (DSO_SPRINT_ACTIVE=0 / DSO_DEBUG_ACTIVE=0) should be used sparingly — only when a sub-branch merge is genuinely infeasible. High usage across a single session indicates the story-branch invariant was systematically bypassed.

### Actual Behavior

${_count} bypass invocation(s) were recorded during this session (threshold: ${BYPASS_ALERT_THRESHOLD}).

### Bypass Reasons Recorded

${_reasons_md}
### Log Files

$(printf '%s\n' "${_all_logs[@]}")

### Recommended Follow-Up

Review whether the bypassed commits were LLM-reviewed. If any bypass was used to avoid the review gate, initiate a retroactive review of the affected commits."

_ticket_out=$(
    "$TICKET_CMD" create bug \
        "[end-session]: Session-merge-only bypass hatch used ${_count} times -> Possible systematic bypass of story-branch invariant" \
        --priority 2 \
        -d "$_description" \
        2>&1
)
_ticket_exit=$?

if [[ $_ticket_exit -ne 0 ]]; then
    echo "bypass-surveillance: ERROR: failed to file follow-up bug ticket (exit ${_ticket_exit})" >&2
    echo "bypass-surveillance: ticket create output: ${_ticket_out}" >&2
    # Archive logs even on ticket-filing failure to avoid re-counting on next run.
    _archive_dir="${ARTIFACTS_DIR}/bypass-processed"
    mkdir -p "$_archive_dir" 2>/dev/null || true
    for _log in "${_all_logs[@]}"; do
        [[ -f "$_log" ]] && mv "$_log" "$_archive_dir/" 2>/dev/null || true
    done
    exit 1
fi

_new_ticket_id=$(echo "$_ticket_out" | tail -1)
echo "bypass-surveillance: INTEGRITY ALERT — ${_count} bypass invocations exceeded threshold ${BYPASS_ALERT_THRESHOLD}. Follow-up ticket filed: ${_new_ticket_id}" >&2

# ── Archive processed logs (preserve audit trail, prevent re-counting) ────────
_archive_dir="${ARTIFACTS_DIR}/bypass-processed"
mkdir -p "$_archive_dir" 2>/dev/null || true
for _log in "${_all_logs[@]}"; do
    [[ -f "$_log" ]] && mv "$_log" "$_archive_dir/" 2>/dev/null || true
done

exit 0
