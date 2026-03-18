---
id: dso-63ez
status: open
deps: [dso-anlb]
links: []
created: 2026-03-18T19:38:50Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-hmb3
---
# Update check-skill-refs.sh default scan globs to plugins/dso/ paths

Update scripts/check-skill-refs.sh (which moved to plugins/dso/scripts/check-skill-refs.sh in T2) so its default in-scope scan targets cover the new paths. Before: scans $REPO_ROOT/{skills,docs,hooks,commands}/ and $REPO_ROOT/CLAUDE.md. After: scans $REPO_ROOT/plugins/dso/{skills,docs,hooks,commands}/ and $REPO_ROOT/CLAUDE.md. REPO_ROOT must still be derived from the script's own location (cd $(dirname) && cd .. && pwd). Also update qualify-skill-refs.sh in a parallel way if it references the same directory list. TDD: The existing tests/scripts/test-check-skill-refs.sh tests pass explicit file paths so they are not affected by glob changes -- write a new test test_default_scan_covers_plugins_dso that invokes check-skill-refs.sh with no args and verifies it scans under plugins/dso/. Run bash tests/run-all.sh to confirm no regressions.


## ACCEPTANCE CRITERIA

- [ ] check-skill-refs.sh default scan targets include plugins/dso/skills, plugins/dso/hooks, plugins/dso/commands, plugins/dso/docs
  Verify: grep -q 'plugins/dso' $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh
- [ ] Default scan no longer includes bare skills/, hooks/, commands/ at repo root
  Verify: grep -v 'plugins/dso' $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh | grep -qE '"skills"|"hooks"|"commands"' && exit 1 || exit 0
- [ ] Running check-skill-refs.sh with no args exits 0 on the current clean codebase
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
