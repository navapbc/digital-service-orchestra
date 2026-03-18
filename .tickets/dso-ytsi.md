---
id: dso-ytsi
status: open
deps: [dso-9k0z, dso-cvx1, dso-63ez]
links: []
created: 2026-03-18T19:38:59Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-hmb3
---
# Validate end-to-end: bash plugins/dso/scripts/validate.sh --ci exits 0

Gate task: Run the full validation suite from the new location to confirm all prior tasks are coherent. (1) Run: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/validate.sh --ci. (2) Run tests/scripts/test-plugin-dir-structure.sh -- all tests must pass. (3) Run bash tests/run-all.sh -- exit 0. (4) Manually verify: ls plugins/dso/ shows skills/ hooks/ commands/ scripts/ docs/ .claude-plugin/. (5) Verify: repo root does NOT contain bare skills/, hooks/, commands/ directories. (6) Verify: git ls-files workflow-config.conf returns non-empty. (7) Verify: git worktree add ../dso-validate-worktree HEAD && ls ../dso-validate-worktree/workflow-config.conf (worktree contains workflow-config.conf without manual copy); cleanup worktree after. This is the story acceptance gate — all Done Definitions must pass before this task closes.


## ACCEPTANCE CRITERIA

- [ ] bash plugins/dso/scripts/validate.sh --ci exits 0 from repo root
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/validate.sh --ci
- [ ] tests/scripts/test-plugin-dir-structure.sh passes (all tests GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-plugin-dir-structure.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] git ls-files workflow-config.conf returns non-empty from repo root
  Verify: cd $(git rev-parse --show-toplevel) && git ls-files workflow-config.conf | grep -q workflow-config.conf
- [ ] ls plugins/dso/ shows all expected directories: skills/ hooks/ commands/ scripts/ docs/ .claude-plugin/
  Verify: for d in skills hooks commands scripts docs .claude-plugin; do test -d $(git rev-parse --show-toplevel)/plugins/dso/$d || (echo "MISSING: $d"; exit 1); done
- [ ] Repo root does NOT contain bare skills/, hooks/, commands/ directories
  Verify: ! test -d $(git rev-parse --show-toplevel)/skills && ! test -d $(git rev-parse --show-toplevel)/hooks && ! test -d $(git rev-parse --show-toplevel)/commands
- [ ] git worktree add produces a worktree containing workflow-config.conf (Done Definition verified)
  Verify: cd $(git rev-parse --show-toplevel) && git worktree add /tmp/dso-worktree-validate HEAD 2>/dev/null; test -f /tmp/dso-worktree-validate/workflow-config.conf && git worktree remove /tmp/dso-worktree-validate --force
