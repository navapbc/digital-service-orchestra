#!/usr/bin/env bash
# Test: plugin boundary migration
# Story: 666f-b07d (S1 walking skeleton)
# RED before Task 3 (7862-3672), GREEN after.
# Verifies that dev-team artifacts are relocated out of plugins/dso/
# and all internal references are updated.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
PASS=0
FAIL=0

# Assertion 1: No references to old design/findings/archive paths in *.md *.sh
if ! git -C "$REPO_ROOT" grep -rn \
     -e 'plugins/dso/docs/designs' \
     -e 'plugins/dso/docs/findings' \
     -e 'plugins/dso/docs/archive' \
     -- '*.md' '*.sh' 2>/dev/null; then
  echo "PASS: no old path references in *.md/*.sh"
  PASS=$((PASS+1))
else
  echo "FAIL: old path references still present in *.md/*.sh"
  FAIL=$((FAIL+1))
fi

# Assertion 2: cascade-replan-protocol.md at new location in plugin
if test -f "$REPO_ROOT/plugins/dso/skills/sprint/docs/cascade-replan-protocol.md"; then
  echo "PASS: cascade-replan-protocol.md at plugins/dso/skills/sprint/docs/"
  PASS=$((PASS+1))
else
  echo "FAIL: cascade-replan-protocol.md not at plugins/dso/skills/sprint/docs/"
  FAIL=$((FAIL+1))
fi

# Assertion 3: project-local directories exist at repo root
if test -d "$REPO_ROOT/docs/designs" && test -d "$REPO_ROOT/docs/findings" && test -d "$REPO_ROOT/docs/archive"; then
  echo "PASS: project-local directories exist (docs/designs, docs/findings, docs/archive)"
  PASS=$((PASS+1))
else
  echo "FAIL: one or more project-local directories missing"
  FAIL=$((FAIL+1))
fi

# Assertion 4: migrated test at new path and executable
if test -x "$REPO_ROOT/tests/skills/test-sprint-skill-step10-no-merge-to-main.sh"; then
  echo "PASS: migrated test exists at tests/skills/"
  PASS=$((PASS+1))
else
  echo "FAIL: migrated test not found at tests/skills/"
  FAIL=$((FAIL+1))
fi

# Assertion 5: migrated test passes
if bash "$REPO_ROOT/tests/skills/test-sprint-skill-step10-no-merge-to-main.sh" 2>/dev/null; then
  echo "PASS: migrated test passes"
  PASS=$((PASS+1))
else
  echo "FAIL: migrated test failed (not yet migrated or failing)"
  FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
