#!/usr/bin/env bash
# check-a34c-closure.sh — Closure gate for epic a34c-b345-1e63-4ae3
#
# Emits a P1 typed-enum JSON verdict (schema_version 2) to stdout.
# Consumable by check-verifier-verdict.sh:
#   .claude/scripts/dso check-a34c-closure.sh | .claude/scripts/dso check-verifier-verdict.sh
#
# Exit codes:
#   0 — P1 == PASS
#   1 — P1 == FAIL

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

EPIC_ID="a34c-b345-1e63-4ae3"

readonly ALLOWED_CHANNELS="tests review-llm review-human production user-report internal-dogfood other"

# ── Check 1: at least one sprint bug with a valid detected_by:<channel> tag ──

check1_status="PASS"
check1_message=""
check1_detail=""

bug_list_output=""
if bug_list_output="$("$REPO_ROOT/.claude/scripts/dso" ticket list --type=bug --parent="$EPIC_ID" 2>/dev/null)"; then
    :
else
    # Non-zero exit — treat as empty list (ticket CLI may return non-zero on empty)
    bug_list_output="[]"
fi

# Count bugs carrying a valid detected_by:<channel> tag
valid_count=$(python3 -c "
import sys, json
allowed = {'tests', 'review-llm', 'review-human', 'production',
           'user-report', 'internal-dogfood', 'other'}
try:
    tickets = json.loads(sys.argv[1] or '[]')
except (json.JSONDecodeError, ValueError):
    tickets = []
count = 0
for t in tickets:
    tags = t.get('tags') or []
    for tag in tags:
        if tag.startswith('detected_by:') and tag[len('detected_by:'):] in allowed:
            count += 1
            break
print(count)
" "$bug_list_output"
)

if [[ -z "$valid_count" ]]; then
    valid_count=0
fi

if [[ "$valid_count" -ge 1 ]]; then
    check1_status="PASS"
    check1_message="At least one a34c sprint bug carries a valid detected_by:<channel> tag (found: ${valid_count})"
    check1_detail="bugs_with_valid_detected_by=${valid_count}"
else
    check1_status="FAIL"
    check1_message="No a34c sprint bug carries a valid detected_by:<channel> tag from the seven allowed values: ${ALLOWED_CHANNELS}"
    check1_detail="bugs_with_valid_detected_by=0; file at least one bug via /dso:create-bug with a detected_by:<channel> tag"
fi

# ── Check 2: calibration-report.sh monthly --fixture returns non-empty channel section ──

check2_status="PASS"
check2_message=""
check2_detail=""

CALIBRATION_REPORT="$SCRIPT_DIR/calibration-report.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/a34c-sprint-bugs"

if [[ ! -f "$CALIBRATION_REPORT" ]]; then
    check2_status="FAIL"
    check2_message="calibration-report.sh not found at $CALIBRATION_REPORT — Milestone 2 script must be created before epic close"
    check2_detail="missing_script=${CALIBRATION_REPORT}"
elif [[ ! -x "$CALIBRATION_REPORT" ]]; then
    check2_status="FAIL"
    check2_message="calibration-report.sh exists but is not executable (run: chmod +x ${CALIBRATION_REPORT})"
    check2_detail="non_executable=${CALIBRATION_REPORT}"
else
    calibration_stdout=""
    calibration_exit=0
    # Capture stdout only; discard stderr to prevent false-positive channel matches
    calibration_stdout=$("$CALIBRATION_REPORT" monthly --fixture "$FIXTURE_DIR" 2>/dev/null) || calibration_exit=$?

    if [[ "$calibration_exit" -ne 0 ]]; then
        check2_status="FAIL"
        check2_message="calibration-report.sh monthly --fixture returned exit ${calibration_exit}"
        check2_detail="exit_code=${calibration_exit}"
    else
        # Must contain at least one bugs-by-channel entry (a line with a channel name and count)
        channel_line_count=$(printf '%s' "$calibration_stdout" | grep -cE "(tests|review-llm|review-human|production|user-report|internal-dogfood|other)" 2>/dev/null || true)
        if [[ "$channel_line_count" -ge 1 ]]; then
            check2_status="PASS"
            check2_message="calibration-report.sh monthly --fixture returned exit 0 with non-empty bugs-by-channel section (${channel_line_count} channel line(s))"
            check2_detail="channel_lines=${channel_line_count}"
        else
            check2_status="FAIL"
            check2_message="calibration-report.sh monthly --fixture returned exit 0 but output contains no channel breakdown lines"
            check2_detail="channel_lines=0"
        fi
    fi
fi

# ── Compute overall P1 verdict ────────────────────────────────────────────────

if [[ "$check1_status" == "PASS" && "$check2_status" == "PASS" ]]; then
    overall_p1="PASS"
    overall_verdict="All closure checks passed: sprint bugs carry detected_by attribution and calibration-report.sh monthly fixture returns a valid channel breakdown"
else
    overall_p1="FAIL"
    failing_checks=()
    [[ "$check1_status" == "FAIL" ]] && failing_checks+=("check_1")
    [[ "$check2_status" == "FAIL" ]] && failing_checks+=("check_2")
    overall_verdict="Closure blocked: ${failing_checks[*]} failed — see checks array for details"
fi

# ── Emit JSON verdict ─────────────────────────────────────────────────────────
# Pass all dynamic values as positional args to prevent shell metachar injection
# into Python string literals when output contains quotes or backslashes.

python3 - \
    "$overall_p1" "$overall_verdict" \
    "$check1_status" "$check1_message" "$check1_detail" \
    "$check2_status" "$check2_message" "$check2_detail" \
    <<'PYEOF'
import json, sys
a = sys.argv[1:]
result = {
    "schema_version": 2,
    "P1": a[0],
    "verdict": a[1],
    "checks": [
        {
            "id": "detected_by_tag_present",
            "description": "At least one a34c sprint bug carries a valid detected_by:<channel> tag",
            "status": a[2],
            "message": a[3],
            "detail": a[4]
        },
        {
            "id": "calibration_report_monthly_fixture",
            "description": "calibration-report.sh monthly --fixture returns exit 0 with non-empty bugs-by-channel section",
            "status": a[5],
            "message": a[6],
            "detail": a[7]
        }
    ]
}
print(json.dumps(result, indent=2))
PYEOF

if [[ "$overall_p1" == "PASS" ]]; then
    exit 0
else
    exit 1
fi
