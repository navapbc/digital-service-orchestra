---
id: dso-anlb
status: in_progress
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

## Notes

**2026-03-18T20:05:31Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T20:09:30Z**

CHECKPOINT 2/6: Code patterns understood ✓ - PLUGIN_ROOT resolves to repo root via tests/../..; after move, need to update CLAUDE_PLUGIN_ROOT to plugins/dso in run-all.sh and run-script-tests.sh. check-skill-refs.sh scans skills/docs/hooks/commands dirs. .pre-commit-config.yaml uses ./scripts/ and ./hooks/ paths. marketplace.json needs git-subdir update.

**2026-03-18T20:09:34Z**

CHECKPOINT 3/6: Tests written (RED phase tests from dso-2oyj already exist) ✓

**2026-03-18T20:24:16Z**

CHECKPOINT 4/6: Implementation complete ✓ - Moved skills/, hooks/, commands/, scripts/, docs/, .claude-plugin/ to plugins/dso/. Updated .gitignore and git-tracked workflow-config.conf. Created .claude-plugin/marketplace.json at repo root with git-subdir. Updated .pre-commit-config.yaml, check-skill-refs.sh, validate.sh, evals.json, run-all.sh, run-script-tests.sh. Bulk-updated 171+ test files to use DSO_PLUGIN_DIR=/plugins/dso. Updated dso-setup.sh DIST_ROOT for templates/examples.
