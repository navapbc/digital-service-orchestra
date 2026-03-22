---
id: w21-1pyo
status: open
deps: []
links: []
created: 2026-03-21T22:02:33Z
type: bug
priority: 4
assignee: Joe Oakhart
---
# Bug: test-design-skills-cross-stack.sh arithmetic error from grep -c fallback pattern

grep -c outputs '0' and exits non-zero when no matches. The || echo '0' fallback adds a second '0', causing arithmetic syntax error. Fixed by replacing || echo '0' with || true on all grep -c lines. Pre-existing in 4 locations.

