---
id: dso-2rts
status: open
deps: [dso-02wk]
links: []
created: 2026-03-17T21:06:39Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-0y9j
---
# Add --lib flag to shim template (GREEN)

## TDD Requirement (GREEN phase)

Modify templates/host-project/dso to add --lib flag handling. All 4 lib-mode tests pass.

## Implementation Steps

After DSO_ROOT is resolved (before dispatch section), add:

```sh
# Library mode: export DSO_ROOT and return without dispatching
if [ "${1:-}" = "--lib" ]; then
    export DSO_ROOT="$DSO_ROOT"
    return 0 2>/dev/null || exit 0
fi
```

The `return 0 2>/dev/null || exit 0` idiom handles both sourced and exec invocations.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -q 'FAILED: 0'
- [ ] ruff check passes
  Verify: ruff check scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: ruff format --check scripts/*.py tests/**/*.py
- [ ] templates/host-project/dso contains --lib handling
  Verify: grep -q -- '--lib' $(git rev-parse --show-toplevel)/templates/host-project/dso
- [ ] DSO_ROOT is absolute path after sourcing the shim template
  Verify: PLUGIN_ROOT=$(git rev-parse --show-toplevel); out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" sh -c ". '$PLUGIN_ROOT/templates/host-project/dso' --lib 2>/dev/null; echo DSO_ROOT=$DSO_ROOT"); echo "$out" | grep '^DSO_ROOT=/' | grep -q .
- [ ] Exec mode exits 0
  Verify: CLAUDE_PLUGIN_ROOT=$(git rev-parse --show-toplevel) bash $(git rev-parse --show-toplevel)/templates/host-project/dso --lib; test $? -eq 0
- [ ] All lib-mode tests pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-shim-smoke.sh 2>&1 | grep -q 'FAILED: 0'

