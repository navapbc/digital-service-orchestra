---
id: w21-u5mg
status: open
deps: []
links: []
created: 2026-03-20T00:50:53Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-jvjw
---
# RED: Write failing tests for pre-commit YAML hook merge

Write failing (RED) tests in tests/scripts/test-dso-setup.sh covering pre-commit YAML merge behavior:

1. When .pre-commit-config.yaml already exists AND dso-setup.sh is run, the existing file is NOT overwritten with the full example config
2. When existing .pre-commit-config.yaml has a 'repos:' section, the DSO hooks (at minimum 'pre-commit-review-gate') are merged into the existing repos list
3. When existing .pre-commit-config.yaml already contains the 'pre-commit-review-gate' hook id, it is NOT duplicated after merge
4. Merge preserves existing hook entries (none are deleted)
5. Merge produces valid YAML (the resulting file can be parsed)
6. In --dryrun mode, no changes are made to the existing .pre-commit-config.yaml

TDD Requirement: All tests must FAIL (RED) before any implementation. Uses bash tests with mktemp temp dirs. YAML validation can use python3 -c 'import yaml; yaml.safe_load(open("..."))' or a simpler grep/structure check.

Note: The merge strategy is append-repos (add the DSO local repo block to the existing repos list). The existing file's fail_fast and other top-level keys are preserved.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] tests/scripts/test-dso-setup.sh contains at least 4 new test functions covering pre-commit YAML merge
  Verify: grep -c 'test_.*precommit.*merge\|test_.*merge.*precommit\|test_.*yaml.*merge\|test_.*hook.*merge' $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh | awk '{exit ($1 < 4)}'
- [ ] All new YAML merge test functions FAIL against current dso-setup.sh (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -q 'FAIL'


