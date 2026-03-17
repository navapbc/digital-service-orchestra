---
id: dso-jl2z
status: closed
deps: [dso-5l1c]
links: []
created: 2026-03-17T21:07:07Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-r9fa
---
# Create scripts/dso-setup.sh (GREEN)

## TDD Requirement (GREEN phase)

Create scripts/dso-setup.sh. All 5 setup tests pass.

## Interface

```
dso-setup.sh [TARGET_REPO [PLUGIN_ROOT]]
```

- TARGET_REPO: directory to install shim into; defaults to $(git rev-parse --show-toplevel)
- PLUGIN_ROOT: plugin directory; defaults to parent of this script's directory (scripts/../)

## Implementation (POSIX sh)

```sh
#!/bin/sh
TARGET_REPO="${1:-$(git rev-parse --show-toplevel)}"
PLUGIN_ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

mkdir -p "$TARGET_REPO/.claude/scripts/"
cp "$PLUGIN_ROOT/templates/host-project/dso" "$TARGET_REPO/.claude/scripts/dso"
chmod +x "$TARGET_REPO/.claude/scripts/dso"

CONFIG="$TARGET_REPO/workflow-config.conf"
if grep -q '^dso\.plugin_root=' "$CONFIG" 2>/dev/null; then
    # Update existing entry (idempotent)
    sed -i.bak "s|^dso\.plugin_root=.*|dso.plugin_root=$PLUGIN_ROOT|" "$CONFIG" && rm -f "$CONFIG.bak"
else
    printf 'dso.plugin_root=%s\n' "$PLUGIN_ROOT" >> "$CONFIG"
fi
```

chmod +x scripts/dso-setup.sh

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -q 'FAILED: 0'
- [ ] ruff check passes
  Verify: ruff check scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: ruff format --check scripts/*.py tests/**/*.py
- [ ] scripts/dso-setup.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/scripts/dso-setup.sh
- [ ] All setup tests pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -q 'FAILED: 0'


## Notes

<!-- note-id: ho48zd63 -->
<!-- timestamp: 2026-03-17T21:40:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Implemented: scripts/dso-setup.sh
