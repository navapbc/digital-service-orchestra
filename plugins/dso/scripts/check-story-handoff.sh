#!/usr/bin/env bash
# check-story-handoff.sh
#
# Machine check: reads predecessor story verifier verdict and halts successor
# dispatch when the verdict is not PASS.
#
# Usage:
#   check-story-handoff.sh --predecessor-story-id=<id> [--verifier-json=<path>]
#
# When --verifier-json is provided: reads from that file directly.
# When only --predecessor-story-id is given: runs `dso ticket show <id>` and
# parses the VERIFICATION_RESULT comment from the ticket's comments array.
#
# Exit codes:
#   0  P1 == "PASS"  (schema_version=2)
#      OR overall_verdict == "PASS"  (schema_version<2 backward-compat shim)
#   1  P1 == "FAIL", "BLOCKED", or "INCONCLUSIVE"
#      Writes JSON to stderr: {"error":"handoff_blocked","predecessor_story":"...","verdict":"...","reason":"..."}
#   2  File absent, malformed JSON, P1 field absent on schema_version=2 payload,
#      ticket not found, or missing required argument
#
# Reads: verifier JSON (schema_version=2, P1 field) with backward-compat for
#        schema_version<2 overall_verdict.
#
# Contract: predecessor verifier verdict gate for sprint Phase E dispatch.

set -uo pipefail

# ── Parse arguments ───────────────────────────────────────────────────────────

_predecessor_story_id=""
_verifier_json_path=""

for arg in "$@"; do
    case "$arg" in
        --predecessor-story-id=*)
            _predecessor_story_id="${arg#--predecessor-story-id=}"
            ;;
        --verifier-json=*)
            _verifier_json_path="${arg#--verifier-json=}"
            ;;
        *)
            echo "check-story-handoff: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$_predecessor_story_id" ]]; then
    echo "check-story-handoff: --predecessor-story-id=<id> is required" >&2
    exit 2
fi

# ── Obtain JSON input ─────────────────────────────────────────────────────────

_json_input=""

if [[ -n "$_verifier_json_path" ]]; then
    # Explicit file path provided — read from it
    if [[ ! -f "$_verifier_json_path" ]]; then
        echo "check-story-handoff: file not found: $_verifier_json_path" >&2
        exit 2
    fi
    _json_input=$(cat "$_verifier_json_path")
else
    # Discover from ticket show: look for VERIFICATION_RESULT in comments array
    if ! command -v python3 >/dev/null 2>&1; then
        echo "check-story-handoff: python3 not found; cannot parse ticket JSON" >&2
        exit 2
    fi

    # Resolve DSO shim — find ticket CLI via CLAUDE_PLUGIN_ROOT or repo root
    _dso_shim=""
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        _repo_root="$(cd "$CLAUDE_PLUGIN_ROOT/../.." && pwd 2>/dev/null || echo "")"
    else
        # CLAUDE_PLUGIN_ROOT unset (script invoked outside the plugin loader): fall back to git.
        _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    fi
    if [[ -n "$_repo_root" ]] && [[ -f "$_repo_root/.claude/scripts/dso" ]]; then
        _dso_shim="$_repo_root/.claude/scripts/dso"
    fi

    if [[ -z "$_dso_shim" ]]; then
        echo "check-story-handoff: could not locate dso shim; provide --verifier-json instead" >&2
        exit 2
    fi

    _ticket_json=$("$_dso_shim" ticket show "$_predecessor_story_id" 2>/dev/null) || {
        echo "check-story-handoff: ticket not found: $_predecessor_story_id" >&2
        exit 2
    }

    # Extract the VERIFICATION_RESULT comment from the ticket's comments array
    _json_input=$(python3 -c "
import sys, json
try:
    ticket = json.loads('''$_ticket_json'''.replace('\\\\', '\\\\\\\\'))
except Exception:
    sys.stderr.write('check-story-handoff: failed to parse ticket JSON\n')
    sys.exit(2)

comments = ticket.get('comments', [])
for c in reversed(comments):
    body = c.get('body', '') if isinstance(c, dict) else str(c)
    if 'VERIFICATION_RESULT' in body:
        # Extract the JSON block after VERIFICATION_RESULT marker
        import re
        m = re.search(r'VERIFICATION_RESULT\s*[:\s]*(\{.*\})', body, re.DOTALL)
        if m:
            print(m.group(1))
            sys.exit(0)

sys.stderr.write('check-story-handoff: no VERIFICATION_RESULT comment found for ticket $_predecessor_story_id\n')
sys.exit(2)
" 2>&1)
    _py_rc=$?
    if [[ $_py_rc -ne 0 ]]; then
        printf '%s\n' "$_json_input" >&2
        exit 2
    fi
fi

# ── Parse verdict fields from JSON ────────────────────────────────────────────

if ! command -v python3 >/dev/null 2>&1; then
    echo "check-story-handoff: python3 not found; cannot parse JSON" >&2
    exit 2
fi

_parse_result=$(printf '%s' "$_json_input" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.stderr.write('check-story-handoff: malformed JSON input\n')
    sys.exit(2)
sv = str(data.get('schema_version', 0))
p1 = data.get('P1', '')
ov = data.get('overall_verdict', '')
print('\t'.join([sv, p1, ov]))
" 2>&1)
_py_rc=$?
if [[ $_py_rc -ne 0 ]]; then
    printf '%s\n' "$_parse_result" >&2
    exit 2
fi

_schema_version=$(printf '%s' "$_parse_result" | cut -f1)
_p1_value=$(printf '%s' "$_parse_result" | cut -f2)
_overall_verdict=$(printf '%s' "$_parse_result" | cut -f3)

# ── Schema version routing ────────────────────────────────────────────────────

_sv_int=0
if [[ "$_schema_version" =~ ^[0-9]+$ ]]; then
    _sv_int="$_schema_version"
fi

_emit_blocked_error() {
    local verdict="$1"
    printf '{"error":"handoff_blocked","predecessor_story":"%s","verdict":"%s","reason":"non-PASS predecessor verdict blocks successor dispatch"}\n' \
        "$_predecessor_story_id" "$verdict" >&2
}

if [[ "$_sv_int" -ge 2 ]]; then
    # schema_version=2: route on P1 typed-enum
    case "$_p1_value" in
        PASS)
            exit 0
            ;;
        FAIL|BLOCKED|INCONCLUSIVE)
            _emit_blocked_error "$_p1_value"
            exit 1
            ;;
        "")
            echo "check-story-handoff: P1 field absent in schema_version=2 JSON input" >&2
            exit 2
            ;;
        *)
            echo "check-story-handoff: unrecognized P1 value: $_p1_value" >&2
            exit 2
            ;;
    esac
else
    # schema_version<2 backward-compat: fall back to overall_verdict
    echo "check-story-handoff: WARNING: schema_version=${_schema_version} (legacy); falling back to overall_verdict" >&2
    case "$_overall_verdict" in
        PASS)
            exit 0
            ;;
        FAIL|PENDING|SKIPPED|BLOCKED|INCONCLUSIVE)
            _emit_blocked_error "$_overall_verdict"
            exit 1
            ;;
        "")
            echo "check-story-handoff: overall_verdict absent in legacy JSON input" >&2
            exit 2
            ;;
        *)
            echo "check-story-handoff: unrecognized overall_verdict: $_overall_verdict" >&2
            exit 2
            ;;
    esac
fi
