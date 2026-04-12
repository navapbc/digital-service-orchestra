#!/usr/bin/env bash
# ticket-clarity-check.sh
# SC2 heuristic clarity scorer for DSO tickets.
#
# Evaluates a ticket's clarity by scoring its description across multiple
# dimensions: length, structure (section headers, bullet lists), and
# type-specific content markers.
#
# Usage:
#   ticket-clarity-check.sh <ticket-id>     — fetch ticket via CLI and score it
#   ticket-clarity-check.sh --stdin          — read JSON ticket from stdin (testing mode)
#   ticket-clarity-check.sh --stdin --config <path>  — use custom config file
#
# Output: single JSON object on stdout: {"score": N, "verdict": "pass|fail", "threshold": T}
# Exit codes:
#   0 — pass (score >= threshold)
#   1 — fail (score < threshold)
#   2 — error (invalid input, missing ticket ID, malformed JSON)
#
# Contract: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/ticket-clarity-check-output.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")}"

# ── Argument parsing ──────────────────────────────────────────────────────────
MODE=""          # "ticket_id" or "stdin"
TICKET_ID=""
CONFIG_FILE=""   # optional --config <path>

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stdin)
            MODE="stdin"
            shift
            ;;
        --config)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --config requires a file path argument" >&2
                exit 2
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        --*)
            echo "ERROR: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            if [[ -n "$TICKET_ID" ]]; then
                echo "ERROR: unexpected argument: $1" >&2
                exit 2
            fi
            TICKET_ID="$1"
            MODE="ticket_id"
            shift
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "ERROR: must supply a ticket ID or --stdin" >&2
    exit 2
fi

# ── Read ticket JSON ──────────────────────────────────────────────────────────
TICKET_JSON=""
if [[ "$MODE" == "stdin" ]]; then
    TICKET_JSON="$(cat)"
    if [[ -z "$TICKET_JSON" ]]; then
        echo "ERROR: no JSON received on stdin" >&2
        exit 2
    fi
else
    # Resolve the DSO CLI shim
    DSO_CLI=""
    if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/.claude/scripts/dso" ]]; then
        DSO_CLI="$REPO_ROOT/.claude/scripts/dso"
    fi
    if [[ -z "$DSO_CLI" ]]; then
        echo "ERROR: could not locate .claude/scripts/dso shim" >&2
        exit 2
    fi
    TICKET_JSON="$("$DSO_CLI" ticket show "$TICKET_ID" 2>/dev/null)" || {
        echo "ERROR: failed to retrieve ticket $TICKET_ID" >&2
        exit 2
    }
    if [[ -z "$TICKET_JSON" ]]; then
        echo "ERROR: empty response for ticket $TICKET_ID" >&2
        exit 2
    fi
fi

# ── Parse ticket fields via python3 ──────────────────────────────────────────
_parse_ticket() {
    python3 - "$TICKET_JSON" <<'PYEOF'
import json, sys

try:
    data = json.loads(sys.argv[1])
except (json.JSONDecodeError, ValueError) as e:
    print("ERROR", flush=True)
    sys.exit(1)

ticket_type = data.get("ticket_type", "").strip()
description = data.get("description", "") or ""

print(ticket_type)
print(description)
PYEOF
}

PARSED_OUTPUT="$(_parse_ticket)" || {
    echo "ERROR: malformed ticket JSON" >&2
    exit 2
}

TICKET_TYPE="$(echo "$PARSED_OUTPUT" | head -1)"
DESCRIPTION="$(echo "$PARSED_OUTPUT" | tail -n +2)"

if [[ "$TICKET_TYPE" == "ERROR" ]]; then
    echo "ERROR: could not parse ticket JSON" >&2
    exit 2
fi

# ── Read threshold from config ────────────────────────────────────────────────
# Priority: --config file (ticket_clarity.threshold) > dso-config.conf (clarity_check.pass_threshold)
# Minimum valid threshold: 1

_read_config_key() {
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '[:space:]'
}

THRESHOLD=5  # default

if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: config file not found: $CONFIG_FILE" >&2
        exit 2
    fi
    _override=$(_read_config_key "$CONFIG_FILE" "ticket_clarity.threshold")
    if [[ -n "$_override" ]] && [[ "$_override" =~ ^[0-9]+$ ]]; then
        THRESHOLD="$_override"
    fi
else
    # Try dso-config.conf
    _conf_path=""
    if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/.claude/dso-config.conf" ]]; then
        _conf_path="$REPO_ROOT/.claude/dso-config.conf"
    fi
    if [[ -n "$_conf_path" ]]; then
        _override=$(_read_config_key "$_conf_path" "clarity_check.pass_threshold")
        if [[ -n "$_override" ]] && [[ "$_override" =~ ^[0-9]+$ ]]; then
            THRESHOLD="$_override"
        fi
    fi
fi

# Enforce minimum threshold of 1
if (( THRESHOLD < 1 )); then
    THRESHOLD=1
fi

# ── SC2 Scoring ───────────────────────────────────────────────────────────────
SCORE=$(python3 - "$DESCRIPTION" "$TICKET_TYPE" <<'PYEOF'
import sys, re

description = sys.argv[1]
ticket_type = sys.argv[2]

score = 0

# 1. Section headers (## lines present): +1
if re.search(r'^##\s+\S', description, re.MULTILINE):
    score += 1

# 2. Description length >= 200 chars: +1
desc_len = len(description)
if desc_len >= 200:
    score += 1

# 3. Description length >= 500 chars: +1 additional
if desc_len >= 500:
    score += 1

# 4. Bullet/checkbox lists (lines starting with "- " or "- [ ]"): +1
if re.search(r'^- ', description, re.MULTILINE):
    score += 1

# 5. Type-specific bonuses
if ticket_type == "task":
    # Acceptance Criteria section: +2
    if re.search(r'^##\s+Acceptance Criteria', description, re.MULTILINE | re.IGNORECASE):
        score += 2
    # File paths (anything with / or . suggesting a path like src/foo.py): +1
    if re.search(r'(?:^|\s)[\w./]+/[\w./]+', description, re.MULTILINE):
        score += 1

elif ticket_type == "story":
    # Both Why and What sections present: +2
    has_why = bool(re.search(r'^##\s+Why\b', description, re.MULTILINE | re.IGNORECASE))
    has_what = bool(re.search(r'^##\s+What\b', description, re.MULTILINE | re.IGNORECASE))
    if has_why and has_what:
        score += 2
    # Scope section: +1
    if re.search(r'^##\s+Scope\b', description, re.MULTILINE | re.IGNORECASE):
        score += 1

elif ticket_type == "bug":
    # Reproduction Steps section: +2
    if re.search(r'^##\s+Reproduction Steps', description, re.MULTILINE | re.IGNORECASE):
        score += 2
    # Expected vs actual language: +1
    if re.search(r'expected|actual', description, re.IGNORECASE):
        score += 1

elif ticket_type == "epic":
    # Success Criteria section: +2
    if re.search(r'^##\s+Success Criteria', description, re.MULTILINE | re.IGNORECASE):
        score += 2
    # Context section: +1
    if re.search(r'^##\s+Context\b', description, re.MULTILINE | re.IGNORECASE):
        score += 1

print(score)
PYEOF
)

if [[ -z "$SCORE" ]] || ! [[ "$SCORE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: score computation failed" >&2
    exit 2
fi

# ── Determine verdict and emit JSON ──────────────────────────────────────────
if (( SCORE >= THRESHOLD )); then
    VERDICT="pass"
    EXIT_CODE=0
else
    VERDICT="fail"
    EXIT_CODE=1
fi

python3 -c "import json; print(json.dumps({'score': int('$SCORE'), 'verdict': '$VERDICT', 'threshold': int('$THRESHOLD')}))"

exit $EXIT_CODE
