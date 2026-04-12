#!/usr/bin/env bash
# Test: Zero plugins/dso references in markdown files under plugins/dso/
# NO bypass, NO annotations — absolute zero tolerance.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

MATCHES=$(grep -rn "plugins/dso" "$REPO_ROOT/plugins/dso/agents/" "$REPO_ROOT/plugins/dso/skills/" "$REPO_ROOT/plugins/dso/docs/" --include="*.md" || true)
if [ -n "$MATCHES" ]; then
  COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
  echo "FAIL: Found $COUNT plugins/dso references in markdown:"
  echo "$MATCHES" | head -30
  if [ "$COUNT" -gt 30 ]; then
    echo "... ($((COUNT - 30)) more)"
  fi
  exit 1
fi
echo "PASS: Zero plugins/dso refs in markdown"
