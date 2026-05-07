#!/usr/bin/env bash
# assert-golden.sh: Compare output to a golden file or substring
# Usage: assert_contains "haystack text" "needle" "description"
assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    return 0
  else
    echo "  FAIL: $desc (expected to contain: $needle)"
    return 1
  fi
}
