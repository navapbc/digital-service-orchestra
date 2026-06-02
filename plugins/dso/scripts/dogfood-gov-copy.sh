#!/usr/bin/env bash
# dogfood-gov-copy.sh — Synthetic dogfood harness for gov-copy-writer validation.
#
# Reads pre-processed baseline and improved copy artifacts, extracts per-item
# checks (fk_grade, banned_words_found, active_voice) from the YAML checks block,
# and asserts the before/after acceptance bar.
#
# The deterministic post-processor (gov_copy_postprocess) populates the checks
# block on each artifact. This harness reads those values rather than re-running
# the processor, making it runnable without the full post-processor installed.
#
# Usage:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/dogfood-gov-copy.sh" [--baseline PATH] [--improved PATH]
#
# Exit codes:
#   0  All three acceptance bars met
#   1  One or more bars missed (diagnostic printed to stdout)
#   2  Usage error or missing artifact
#
# Acceptance bars:
#   avg fk_grade decreases by >= 1 grade level
#   banned_words_found total drops to 0
#   active_voice rate increases by >= 20 percentage points

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This file lives at <plugin_root>/scripts/dogfood-gov-copy.sh.
# Derive _PLUGIN_ROOT via SCRIPT_DIR, which is always correct for the current worktree.
_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BASELINE="${_PLUGIN_ROOT}/data/fixtures/dogfood/bad-copy-baseline.yaml"
IMPROVED="${_PLUGIN_ROOT}/data/fixtures/dogfood/good-copy-improved.yaml"

# Parse optional overrides
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "error: --baseline requires a PATH argument" >&2
        echo "usage: $0 [--baseline PATH] [--improved PATH]" >&2
        exit 2
      fi
      BASELINE="$2"
      shift 2
      ;;
    --improved)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "error: --improved requires a PATH argument" >&2
        echo "usage: $0 [--baseline PATH] [--improved PATH]" >&2
        exit 2
      fi
      IMPROVED="$2"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      echo "usage: $0 [--baseline PATH] [--improved PATH]" >&2
      exit 2
      ;;
  esac
done

# Validate artifacts exist
if [[ ! -f "$BASELINE" ]]; then
  echo "error: baseline artifact not found: $BASELINE" >&2
  exit 2
fi
if [[ ! -f "$IMPROVED" ]]; then
  echo "error: improved artifact not found: $IMPROVED" >&2
  exit 2
fi

# Python helper: extract metrics from a gov-copy YAML artifact's checks block.
# Outputs three lines: avg_fk_grade, banned_words_total, active_voice_rate
_extract_metrics() {
  local artifact="$1"
  python3 - "$artifact" <<'PYEOF'
import sys
import yaml

artifact_path = sys.argv[1]
with open(artifact_path) as f:
    data = yaml.safe_load(f) or {}

items = data.get("items", []) or []
if not items:
    print("0.0")
    print("0")
    print("0.0")
    sys.exit(0)

total_fk = 0.0
total_banned = 0
active_count = 0
n = len(items)

for item in items:
    checks = item.get("checks", {}) or {}
    fk_raw = checks.get("fk_grade", 0)
    # checks.fk_grade may be a plain number or {"value": N, "source": ...}
    if isinstance(fk_raw, dict):
        fk = float(fk_raw.get("value", 0))
    else:
        fk = float(fk_raw)

    banned_raw = checks.get("banned_words_found", [])
    if isinstance(banned_raw, dict):
        banned = banned_raw.get("value", []) or []
    else:
        banned = banned_raw or []

    active_raw = checks.get("active_voice", False)
    if isinstance(active_raw, dict):
        active = bool(active_raw.get("value", False))
    else:
        active = bool(active_raw)

    total_fk += fk
    total_banned += len(banned)
    if active:
        active_count += 1

avg_fk = total_fk / n
active_rate = (active_count / n) * 100.0

print(f"{avg_fk:.4f}")
print(f"{total_banned}")
print(f"{active_rate:.4f}")
PYEOF
}

# Extract before metrics
echo "--- BEFORE (baseline) ---"
echo "Artifact: $BASELINE"
before_metrics=$(_extract_metrics "$BASELINE")
before_avg_fk=$(echo "$before_metrics" | sed -n '1p')
before_banned=$(echo "$before_metrics" | sed -n '2p')
before_active_rate=$(echo "$before_metrics" | sed -n '3p')
echo "  avg_fk_grade:      $before_avg_fk"
echo "  banned_words_total: $before_banned"
echo "  active_voice_rate:  ${before_active_rate}%"

# Extract after metrics
echo ""
echo "--- AFTER (improved) ---"
echo "Artifact: $IMPROVED"
after_metrics=$(_extract_metrics "$IMPROVED")
after_avg_fk=$(echo "$after_metrics" | sed -n '1p')
after_banned=$(echo "$after_metrics" | sed -n '2p')
after_active_rate=$(echo "$after_metrics" | sed -n '3p')
echo "  avg_fk_grade:      $after_avg_fk"
echo "  banned_words_total: $after_banned"
echo "  active_voice_rate:  ${after_active_rate}%"

echo ""
echo "--- ACCEPTANCE BAR EVALUATION ---"

# Use Python for floating-point comparisons
python3 - \
  "$before_avg_fk" "$after_avg_fk" \
  "$before_banned" "$after_banned" \
  "$before_active_rate" "$after_active_rate" <<'PYEOF'
import sys

before_avg_fk   = float(sys.argv[1])
after_avg_fk    = float(sys.argv[2])
before_banned   = int(sys.argv[3])
after_banned    = int(sys.argv[4])
before_active   = float(sys.argv[5])
after_active    = float(sys.argv[6])

FK_DECREASE_MIN   = 1.0
BANNED_TARGET     = 0
ACTIVE_INCREASE_MIN = 20.0

failures = []

fk_decrease = before_avg_fk - after_avg_fk
if fk_decrease < FK_DECREASE_MIN:
    failures.append(
        f"  FAIL fk_grade: decrease={fk_decrease:.2f} (required >= {FK_DECREASE_MIN})"
        f" before={before_avg_fk:.2f} after={after_avg_fk:.2f}"
    )
else:
    print(f"  PASS fk_grade:     decrease={fk_decrease:.2f} >= {FK_DECREASE_MIN}"
          f" (before={before_avg_fk:.2f}, after={after_avg_fk:.2f})")

if after_banned != BANNED_TARGET:
    failures.append(
        f"  FAIL banned_words: after_total={after_banned} (required == {BANNED_TARGET})"
    )
else:
    print(f"  PASS banned_words: total dropped to 0 (before={before_banned})")

active_increase = after_active - before_active
if active_increase < ACTIVE_INCREASE_MIN:
    failures.append(
        f"  FAIL active_voice: increase={active_increase:.2f}pp (required >= {ACTIVE_INCREASE_MIN}pp)"
        f" before={before_active:.2f}% after={after_active:.2f}%"
    )
else:
    print(f"  PASS active_voice: increase={active_increase:.2f}pp >= {ACTIVE_INCREASE_MIN}pp"
          f" (before={before_active:.2f}%, after={after_active:.2f}%)")

print()
if failures:
    print("RESULT: FAIL — acceptance bar not met:")
    for msg in failures:
        print(msg)
    sys.exit(1)
else:
    print("RESULT: PASS — all acceptance bars met")
    sys.exit(0)
PYEOF
