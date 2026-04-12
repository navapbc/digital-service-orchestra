#!/usr/bin/env bash
# Test: no plugins/dso references in comment lines within plugins/dso/
test_no_plugin_comment_refs() {
MATCHES=$(grep -rn '# .*plugins/dso' plugins/dso/ --include='*.sh')
if [ -n "$MATCHES" ]; then
  echo 'FAIL: Found plugins/dso references in comment lines:'
  echo "$MATCHES"
  exit 1
fi
echo 'PASS: Zero plugins/dso comment references found'
}
test_no_plugin_comment_refs
