#!/usr/bin/env bash
# Test: absolute zero plugins/dso refs in non-comment code lines under plugins/dso/
test_no_plugin_runtime_refs() {
MATCHES=$(grep -rn "plugins/dso" plugins/dso/ --include="*.sh" | grep -v "^[^:]*:[^:]*:#")
if [ -n "$MATCHES" ]; then
  echo "FAIL: Found plugins/dso references in code lines:"
  echo "$MATCHES"
  exit 1
fi
echo "PASS: Zero plugins/dso refs in code lines"
}
test_no_plugin_runtime_refs
