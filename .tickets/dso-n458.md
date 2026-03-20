---
id: dso-n458
status: open
deps: [dso-ilc1]
links: []
created: 2026-03-20T00:42:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-6576
---
# IMPL: Add ci.workflow_name to workflow-config-schema.json

Add ci.workflow_name to the ci section in plugins/dso/docs/workflow-config-schema.json.

TDD EXEMPTION: This task modifies only a static JSON schema file. No executable conditional logic is added. Criterion 3: 'modifies only static assets ... static config files'.

IMPLEMENTATION STEPS:
1. Open plugins/dso/docs/workflow-config-schema.json
2. In the 'ci' section properties, add a 'workflow_name' property after 'integration_workflow':
   'workflow_name': {
     'type': 'string',
     'description': 'GitHub Actions workflow name for gh workflow run (used by merge-to-main.sh for post-push CI trigger recovery). Consolidates the deprecated merge.ci_workflow_name key. When absent, CI trigger recovery is skipped.',
     'minLength': 1,
     'examples': ['CI', 'Build and Test']
   }
3. Validate JSON is valid: python3 -c 'import json; json.load(open("plugins/dso/docs/workflow-config-schema.json"))'
4. Run: bash tests/scripts/test-workflow-config-schema.sh (if exists)

FILE: plugins/dso/docs/workflow-config-schema.json (edit — add workflow_name to ci section)


## ACCEPTANCE CRITERIA

- [ ] workflow-config-schema.json has workflow_name in the ci section
  Verify: python3 -c "import json; s=json.load(open('$(git rev-parse --show-toplevel)/plugins/dso/docs/workflow-config-schema.json')); assert 'workflow_name' in s['properties']['ci']['properties']"
- [ ] Schema JSON is valid (no parse errors)
  Verify: python3 -c "import json; json.load(open('$(git rev-parse --show-toplevel)/plugins/dso/docs/workflow-config-schema.json'))" && echo "valid"
- [ ] ci.workflow_name description mentions deprecation of merge.ci_workflow_name
  Verify: python3 -c "import json; s=json.load(open('$(git rev-parse --show-toplevel)/plugins/dso/docs/workflow-config-schema.json')); desc=s['properties']['ci']['properties']['workflow_name']['description']; assert 'deprecated' in desc or 'merge.ci_workflow_name' in desc"
- [ ] test-workflow-config-schema.sh passes (if exists)
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-workflow-config-schema.sh && bash $(git rev-parse --show-toplevel)/tests/scripts/test-workflow-config-schema.sh || echo "no schema test file"
