---
id: dso-cvx1
status: open
deps: [dso-anlb]
links: []
created: 2026-03-18T19:38:41Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-hmb3
---
# Update .pre-commit-config.yaml hook paths to plugins/dso/hooks/

Update .pre-commit-config.yaml at repo root to reflect new hook locations under plugins/dso/hooks/. Affected entries: (1) pre-commit-review-gate entry: change './hooks/pre-commit-review-gate.sh' to './plugins/dso/hooks/pre-commit-review-gate.sh'. (2) Any other hook entry points that reference ./hooks/ directly. Update all entry: fields that reference hook scripts under the old hooks/ path. Also update the executable-guard entry if it references ./scripts/ paths that moved. After editing, run pre-commit install to re-register hooks, then run a no-op pre-commit to confirm hooks load without error. TDD: Write test in tests/hooks/ that asserts pre-commit-config.yaml hook entries reference plugins/dso/hooks/ (not bare hooks/).


## ACCEPTANCE CRITERIA

- [ ] All `entry:` fields in .pre-commit-config.yaml that reference old paths (./hooks/, ./scripts/) are updated to ./plugins/dso/hooks/ and ./plugins/dso/scripts/ respectively
  Verify: grep -E '^\s+entry:.*\./hooks/' $(git rev-parse --show-toplevel)/.pre-commit-config.yaml | wc -l | awk '{exit ($1 > 0)}'
- [ ] Python glob patterns in format-and-lint and pre-push-lint entries are updated from scripts/*.py to plugins/dso/scripts/*.py
  Verify: grep -q 'plugins/dso/scripts/\*\.py' $(git rev-parse --show-toplevel)/.pre-commit-config.yaml
- [ ] pre-commit install runs successfully (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && pre-commit install
- [ ] No remaining bare ./hooks/ or ./scripts/ references in .pre-commit-config.yaml (excluding comments)
  Verify: grep -vE '^\s*#' $(git rev-parse --show-toplevel)/.pre-commit-config.yaml | grep -vE 'plugins/dso' | grep -qE '^\s+entry:.*\./hooks/|^\s+entry:.*\./scripts/' && exit 1 || exit 0
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
