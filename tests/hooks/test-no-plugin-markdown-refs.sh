#!/usr/bin/env bash
# Test: absolute zero plugins/dso refs in markdown files under plugins/dso/
test_zero_refs() {
MATCHES=$(grep -rn "plugins/dso" plugins/dso/agents/ plugins/dso/skills/ plugins/dso/docs/ --include="*.md")
if [ -n "$MATCHES" ]; then
  echo "FAIL: Found plugins/dso references in markdown:"
  echo "$MATCHES" | head -30
  echo "(showing first 30 of $(echo "$MATCHES" | wc -l) matches)"
  exit 1
fi
echo "PASS: Zero plugins/dso refs in markdown"
}
test_zero_refs
