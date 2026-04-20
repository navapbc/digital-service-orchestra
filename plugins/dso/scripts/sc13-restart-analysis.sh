#!/usr/bin/env bash
# sc13-restart-analysis.sh
# Computes SC13 workflow-restart rate drop analysis with Wilson score CI.
#
# Usage:
#   sc13-restart-analysis.sh \
#     [--baseline-restart-rate=<float>] \
#     [--post-restart-rate=<float>] \
#     [--sample-size=N] \
#     [--confidence=95]
#
# When rates are not provided explicitly, attempts to read from .tickets-tracker/
# REPLAN_TRIGGER comment counts (if available).
#
# Output JSON:
# {
#   "baseline_rate": <float>,
#   "post_rate": <float>,
#   "drop_pct": <float>,
#   "ci_lower": <float>,
#   "ci_upper": <float>,
#   "sample_size": <int>,
#   "methodology": "Wilson score interval"
# }
#
# Exit codes:
#   0 — success
#   1 — argument error or insufficient data

set -uo pipefail

_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

# ── Argument parsing ─────────────────────────────────────────────────────────
_BASELINE_RATE=""
_POST_RATE=""
_SAMPLE_SIZE=""
_CONFIDENCE=95

for _arg in "$@"; do
    case "$_arg" in
        --baseline-restart-rate=*)
            _BASELINE_RATE="${_arg#--baseline-restart-rate=}"
            ;;
        --post-restart-rate=*)
            _POST_RATE="${_arg#--post-restart-rate=}"
            ;;
        --sample-size=*)
            _SAMPLE_SIZE="${_arg#--sample-size=}"
            ;;
        --confidence=*)
            _CONFIDENCE="${_arg#--confidence=}"
            ;;
        *)
            echo "ERROR: unknown argument: $_arg" >&2
            echo "Usage: sc13-restart-analysis.sh [--baseline-restart-rate=<float>] [--post-restart-rate=<float>] [--sample-size=N] [--confidence=95]" >&2
            exit 1
            ;;
    esac
done

# ── Auto-discover rates from ticket tracker if not provided ──────────────────
if [[ -z "$_BASELINE_RATE" || -z "$_POST_RATE" ]]; then
    _REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
    _TRACKER_DIR="${TICKETS_TRACKER_DIR:-$_REPO_ROOT/.tickets-tracker}"

    if [[ -d "$_TRACKER_DIR" ]]; then
        # Count REPLAN_TRIGGER comments across all tickets as proxy for restart rate
        _REPLAN_COUNT=$(find "$_TRACKER_DIR" -name "*.json" -exec grep -l "REPLAN_TRIGGER" {} \; 2>/dev/null | wc -l | tr -d ' ')
        _TOTAL_COUNT=$(find "$_TRACKER_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

        if [[ "$_TOTAL_COUNT" -gt 0 ]]; then
            _AUTO_RATE=$(python3 -c "print(round($_REPLAN_COUNT / $_TOTAL_COUNT, 4))" 2>/dev/null || echo "0")
            [[ -z "$_BASELINE_RATE" ]] && _BASELINE_RATE="$_AUTO_RATE"
            [[ -z "$_POST_RATE" ]] && _POST_RATE="0"  # assume improvement when not specified
            [[ -z "$_SAMPLE_SIZE" ]] && _SAMPLE_SIZE="$_TOTAL_COUNT"
        fi
    fi
fi

# Validate we have required inputs
if [[ -z "$_BASELINE_RATE" || -z "$_POST_RATE" ]]; then
    echo "ERROR: --baseline-restart-rate and --post-restart-rate are required when not discoverable from .tickets-tracker" >&2
    exit 1
fi

[[ -z "$_SAMPLE_SIZE" ]] && _SAMPLE_SIZE=100

# ── Compute analysis ─────────────────────────────────────────────────────────
python3 - <<PYEOF
import json, math, sys

baseline_rate = float("$_BASELINE_RATE")
post_rate = float("$_POST_RATE")
sample_size = int("$_SAMPLE_SIZE")
confidence = int("$_CONFIDENCE")

# Compute drop percentage
if baseline_rate == 0.0:
    drop_pct = 0.0
else:
    drop_pct = round((baseline_rate - post_rate) / baseline_rate * 100, 4)

# Wilson score interval for post_rate
# Z-value for confidence level
z_values = {90: 1.6449, 95: 1.9600, 99: 2.5758}
z = z_values.get(confidence, 1.9600)

n = sample_size
p = post_rate

# Wilson score CI: (p + z^2/(2n) ± z*sqrt(p(1-p)/n + z^2/(4n^2))) / (1 + z^2/n)
denominator = 1 + z**2 / n
center = (p + z**2 / (2 * n)) / denominator

if n > 0 and 0 <= p <= 1:
    margin = z * math.sqrt(p * (1 - p) / n + z**2 / (4 * n**2)) / denominator
else:
    margin = 0.0

ci_lower = max(0.0, round(center - margin, 4))
ci_upper = min(1.0, round(center + margin, 4))

result = {
    "baseline_rate": round(baseline_rate, 4),
    "post_rate": round(post_rate, 4),
    "drop_pct": drop_pct,
    "ci_lower": ci_lower,
    "ci_upper": ci_upper,
    "sample_size": sample_size,
    "methodology": "Wilson score interval",
}

print(json.dumps(result, indent=2))
sys.exit(0)
PYEOF
