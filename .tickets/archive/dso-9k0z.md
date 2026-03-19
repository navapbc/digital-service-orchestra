---
id: dso-9k0z
status: closed
deps: [dso-anlb]
links: []
created: 2026-03-18T19:38:33Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-hmb3
---
# Update marketplace.json to use git-subdir: plugins/dso

Update .claude-plugin/marketplace.json to replace the flat source entry with a git-subdir entry pointing to plugins/dso/. Before: {"source": "./"}. After: {"source": {"git-subdir": "plugins/dso"}} (or the correct marketplace.json format for git-subdir). Verify the marketplace.json is valid JSON after edit. Run tests/scripts/test-plugin-dir-structure.sh -- the test_marketplace_json_has_git_subdir test should pass. Also verify plugins/dso/.claude-plugin/plugin.json uses only relative paths (./skills/, ./hooks/, ./commands/) not absolute paths. Note: plugin.json already uses ${CLAUDE_PLUGIN_ROOT}/... paths in hook commands, which is correct and requires no change.


## ACCEPTANCE CRITERIA

- [ ] .claude-plugin/marketplace.json contains a git-subdir field pointing to plugins/dso
  Verify: grep -q 'git-subdir' $(git rev-parse --show-toplevel)/.claude-plugin/marketplace.json
- [ ] marketplace.json is valid JSON
  Verify: python3 -m json.tool $(git rev-parse --show-toplevel)/.claude-plugin/marketplace.json > /dev/null
- [ ] plugins/dso/.claude-plugin/plugin.json uses only relative path references (./skills/, ./hooks/, ./commands/)
  Verify: python3 -c "import json; d=json.load(open('$(git rev-parse --show-toplevel)/plugins/dso/.claude-plugin/plugin.json')); assert d['skills'].startswith('./') and d['commands'].startswith('./')"
- [ ] tests/scripts/test-plugin-dir-structure.sh test_marketplace_json_has_git_subdir passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-plugin-dir-structure.sh 2>&1 | grep -q 'test_marketplace_json_has_git_subdir.*PASS'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
