---
id: dso-utw2
status: open
deps: [dso-xf8w, dso-li0w, dso-cb9v, dso-76r3]
links: []
created: 2026-03-21T18:00:57Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-l60c
---
# DOCS: Document .test-index support in the test gate

Update relevant documentation to describe the .test-index feature.

  Changes required:
  1. plugins/dso/hooks/pre-commit-test-gate.sh — update the DESIGN comment block at the top:
     - Add a paragraph describing .test-index: format, location, auto-prune behavior, and how it merges with fuzzy matching
     - Reference the hash exclusion (.test-index excluded from diff hash to prevent mismatch loops)
  2. plugins/dso/docs/COMMIT-WORKFLOW.md (if it mentions the test gate) — add a note that .test-index can map unconventional test associations
  3. CLAUDE.md architecture section — 'test gate (two-layer defense-in-depth)' paragraph already mentions pre-commit-test-gate.sh; update to mention .test-index support briefly

  test-exempt: No conditional logic introduced; this is a documentation-only task. Exemption criterion: 'static assets only' — all changes are Markdown and shell comments with no executable branches.

  Verify:
  - test -f plugins/dso/hooks/pre-commit-test-gate.sh && grep -q 'test-index' plugins/dso/hooks/pre-commit-test-gate.sh
  - grep -q 'test-index' CLAUDE.md

## ACCEPTANCE CRITERIA

- [ ] pre-commit-test-gate.sh DESIGN comment mentions .test-index
  Verify: grep -q 'test-index' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] CLAUDE.md test gate paragraph mentions .test-index
  Verify: grep -q 'test-index' $(git rev-parse --show-toplevel)/CLAUDE.md
- [ ] Skill file is valid markdown (not empty)
  Verify: test -s $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
