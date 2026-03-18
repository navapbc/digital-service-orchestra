---
id: dso-anlb
status: open
deps: [dso-2oyj]
links: []
created: 2026-03-18T19:38:24Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-hmb3
---
# Move plugin files to plugins/dso/ and track workflow-config.conf at repo root

TDD GREEN phase: Perform the physical restructure. (1) Create plugins/dso/ directory. (2) Use git mv to move skills/, hooks/, commands/, scripts/, docs/, .claude-plugin/ into plugins/dso/. Resulting: plugins/dso/skills/, plugins/dso/hooks/, plugins/dso/commands/, plugins/dso/scripts/, plugins/dso/docs/, plugins/dso/.claude-plugin/. (3) Verify workflow-config.conf exists at repo root and add to git tracking if not already tracked (git add workflow-config.conf). (4) Run tests/scripts/test-plugin-dir-structure.sh -- it should now pass (GREEN) for directory existence and workflow-config tests. (5) Run bash tests/run-all.sh to confirm no regressions. Note: .pre-commit-config.yaml and check-skill-refs.sh will have broken paths after this task -- those are fixed in subsequent tasks. This task must still leave the test suite passing, so any tests that fail due to broken hook paths must be skipped or the hook path updates must be done atomically with this task.


## ACCEPTANCE CRITERIA

- [ ] tests/scripts/test-plugin-dir-structure.sh passes after the move (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-plugin-dir-structure.sh
- [ ] plugins/dso/ contains skills/, hooks/, commands/, scripts/, docs/, .claude-plugin/
  Verify: for d in skills hooks commands scripts docs .claude-plugin; do test -d $(git rev-parse --show-toplevel)/plugins/dso/$d || (echo "MISSING: $d"; exit 1); done
- [ ] Repo root does NOT contain bare skills/, hooks/, commands/ directories
  Verify: ! test -d $(git rev-parse --show-toplevel)/skills && ! test -d $(git rev-parse --show-toplevel)/hooks && ! test -d $(git rev-parse --show-toplevel)/commands
- [ ] workflow-config.conf is tracked by git at repo root
  Verify: cd $(git rev-parse --show-toplevel) && git ls-files workflow-config.conf | grep -q workflow-config.conf
- [ ] validate.sh REPO_ROOT still resolves to the git root (not plugins/dso/)
  Verify: REPO_ROOT=$(bash -c 'SCRIPT_DIR=$(cd $(dirname $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate.sh) && pwd); echo $(cd "$SCRIPT_DIR/../.." && pwd)'); test "$REPO_ROOT" = "$(git rev-parse --show-toplevel)"
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
