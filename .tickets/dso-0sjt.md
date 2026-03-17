---
id: dso-0sjt
status: open
deps: [dso-jl2z]
links: []
created: 2026-03-17T21:07:16Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-r9fa
---
# Self-apply dso-setup.sh to plugin repo

## TDD Requirement

Run dso-setup.sh in this repo to bootstrap the plugin repo's own shim. Creates .claude/scripts/dso and writes dso.plugin_root to workflow-config.conf.

## Implementation Steps

1. Run: bash $(git rev-parse --show-toplevel)/scripts/dso-setup.sh
   (TARGET_REPO and PLUGIN_ROOT both default to this repo root)
2. Verify .claude/scripts/dso was created and is executable
3. Verify workflow-config.conf has exactly one dso.plugin_root entry
4. Verify dso tk --help exits 0 without CLAUDE_PLUGIN_ROOT set

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -q 'FAILED: 0'
- [ ] ruff check passes
  Verify: ruff check scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: ruff format --check scripts/*.py tests/**/*.py
- [ ] .claude/scripts/dso exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/.claude/scripts/dso
- [ ] workflow-config.conf has exactly one dso.plugin_root entry
  Verify: grep -c '^dso.plugin_root=' $(git rev-parse --show-toplevel)/workflow-config.conf | awk '{exit ($1 != 1)}'
- [ ] dso tk --help exits 0 without CLAUDE_PLUGIN_ROOT
  Verify: (cd $(git rev-parse --show-toplevel) && unset CLAUDE_PLUGIN_ROOT && ./.claude/scripts/dso tk --help)

