#!/usr/bin/env bash
# Maps DSO_FILING_CONTEXT env var to a detected_by tag value.
# Outputs one of the 7 allowed values to stdout; exits 0 on success.
# Unknown or empty DSO_FILING_CONTEXT maps to "other" (exit 0).
set -euo pipefail

ALLOWED=(tests review-llm review-human production user-report internal-dogfood other)

case "${DSO_FILING_CONTEXT:-}" in
  mutation-auto-bug)    CHANNEL=tests ;;
  fix-bug-phase-g)      CHANNEL=review-llm ;;
  debug-everything)     CHANNEL=review-llm ;;
  review-human)         CHANNEL=review-human ;;
  production)           CHANNEL=production ;;
  user-report)          CHANNEL=user-report ;;
  internal-dogfood)     CHANNEL=internal-dogfood ;;
  *)                    CHANNEL=other ;;
esac

found=0
for v in "${ALLOWED[@]}"; do
  [ "$v" = "$CHANNEL" ] && found=1 && break
done
[ "$found" = 1 ] || { echo "infer-detected-by: $CHANNEL not in ALLOWED whitelist" >&2; exit 2; }

printf '%s' "$CHANNEL"
