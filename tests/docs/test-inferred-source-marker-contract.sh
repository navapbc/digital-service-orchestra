#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

test_inferred_source_marker_contract() {
  local f="$REPO_ROOT/plugins/dso/docs/contracts/inferred-source-marker.md"
  # Assertion 1: file exists
  if test -f "$f"; then actual_exists="present"; else actual_exists="missing"; fi
  assert_eq "inferred-source-marker.md exists" "present" "$actual_exists"
  # Assertion 2: Level-1 heading starts with "# Contract:" (check-contract-schemas.sh rule)
  if grep -q '^# Contract:' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has '# Contract:' heading" "present" "$actual"
  # Assertion 3: Purpose section present (check-contract-schemas.sh rule)
  if grep -q '^## Purpose' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has '## Purpose' section" "present" "$actual"
  # Assertion 4: Marker syntax documented
  if grep -q '<<inferred:' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "marker syntax <<inferred: documented" "present" "$actual"
  # Assertion 5: Emit site section present
  if grep -qE '^## Emit Site|^## Emitter' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has emit site section" "present" "$actual"
  # Assertion 6: Consume sites section present
  if grep -qE '^## Consume Sites|^## Consumers|^## Consumer' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has consume sites section" "present" "$actual"
  # Assertion 7: Lifecycle section present
  if grep -q '^## Lifecycle' "$f" 2>/dev/null; then actual="present"; else actual="missing"; fi
  assert_eq "has '## Lifecycle' section" "present" "$actual"
}

test_inferred_source_marker_contract
print_summary
