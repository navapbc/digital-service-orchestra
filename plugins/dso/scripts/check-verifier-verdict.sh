#!/usr/bin/env bash
# check-verifier-verdict.sh
#
# Read a completion-verifier JSON payload and exit based on the P1 typed-enum field.
# Implements backward-compat: when schema_version < 2 (or absent), falls back to
# overall_verdict with a deprecation warning on stderr.
#
# Usage:
#   echo '{"P1": "PASS"}' | bash check-verifier-verdict.sh
#   bash check-verifier-verdict.sh path/to/verifier-output.json
#
# Exit codes:
#   0  P1 == "PASS"  (schema_version=2)
#      OR overall_verdict == "PASS" (schema_version<2 backward-compat)
#   1  P1 == "FAIL", "BLOCKED", "INCONCLUSIVE", or unrecognized P1 value (schema_version=2;
#         unrecognized values are treated as BLOCKED per contract — safe-default gate-block)
#      OR overall_verdict == "FAIL" / "PENDING" / "SKIPPED"  (schema_version<2)
#   2  P1 field absent on schema_version=2 payload, JSON malformed, or no input provided
#
# Outputs nothing to stdout on exit 0 or 1.
# Outputs an error message to stderr on exit 2.
# Outputs a deprecation warning to stderr when using backward-compat path.
#
# Contract: docs/contracts/verifier-verdict.md (relative to plugin root)

set -uo pipefail

# ── Read input ────────────────────────────────────────────────────────────────

if [[ $# -ge 1 ]]; then
    # Positional argument: file path
    input_source="$1"
    if [[ ! -f "$input_source" ]]; then
        echo "check-verifier-verdict: file not found: $input_source" >&2
        exit 2
    fi
    json_input=$(cat "$input_source")
elif [[ ! -t 0 ]]; then
    # stdin is a pipe or redirect
    json_input=$(cat)
else
    echo "check-verifier-verdict: no input provided (pipe JSON or pass a file path)" >&2
    exit 2
fi

# ── Parse fields via python3 ──────────────────────────────────────────────────

if ! command -v python3 >/dev/null 2>&1; then
    echo "check-verifier-verdict: python3 not found; cannot parse JSON" >&2
    exit 2
fi

# Outputs: "<schema_version>\t<p1_value>\t<overall_verdict>" (tab-separated)
# schema_version defaults to "0" when absent.
parse_result=$(printf '%s' "$json_input" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.stderr.write('check-verifier-verdict: malformed JSON input\n')
    sys.exit(2)
sv = str(data.get('schema_version', 0))
p1 = data.get('P1', '')
ov = data.get('overall_verdict', '')
print('\t'.join([sv, p1, ov]))
" 2>&1)
py_rc=$?
if [[ $py_rc -ne 0 ]]; then
    # python3 wrote error to stderr via 2>&1 capture; relay it
    printf '%s\n' "$parse_result" >&2
    exit 2
fi

schema_version=$(printf '%s' "$parse_result" | cut -f1)
p1_value=$(printf '%s' "$parse_result" | cut -f2)
overall_verdict=$(printf '%s' "$parse_result" | cut -f3)

# ── Schema version gate ───────────────────────────────────────────────────────

# Treat non-integer or absent schema_version as 0 for comparison
sv_int=0
if [[ "$schema_version" =~ ^[0-9]+$ ]]; then
    sv_int="$schema_version"
fi

if [[ "$sv_int" -ge 2 ]]; then
    # ── schema_version=2: route on P1 typed-enum ─────────────────────────────
    case "$p1_value" in
        PASS)
            exit 0
            ;;
        FAIL|BLOCKED|INCONCLUSIVE|EVIDENCE_PENDING)
            exit 1
            ;;
        "")
            # P1 field absent on a schema_version=2 payload — non-conformant
            echo "check-verifier-verdict: P1 field absent in schema_version=2 JSON input" >&2
            exit 2
            ;;
        *)
            # Unrecognized P1 value — per contract (verifier-verdict.md), treat as BLOCKED with warning.
            # Safe-default: gate-block on values we don't recognize rather than fail open.
            echo "check-verifier-verdict: WARNING: unrecognized P1 verdict '$p1_value'; treating as BLOCKED" >&2
            exit 1
            ;;
    esac
else
    # ── schema_version<2 backward-compat: fall back to overall_verdict ────────
    # Consumer migrated to schema_version=2 (S1b); this path handles legacy v1 payloads.
    echo "check-verifier-verdict: WARNING: schema_version=${schema_version} (legacy); falling back to overall_verdict" >&2
    case "$overall_verdict" in
        PASS)
            exit 0
            ;;
        FAIL|PENDING|SKIPPED)
            exit 1
            ;;
        "")
            echo "check-verifier-verdict: overall_verdict absent in legacy JSON input" >&2
            exit 2
            ;;
        *)
            echo "check-verifier-verdict: unrecognized overall_verdict: $overall_verdict" >&2
            exit 2
            ;;
    esac
fi
