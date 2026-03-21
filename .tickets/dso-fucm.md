---
id: dso-fucm
status: open
deps: []
links: []
created: 2026-03-21T15:59:17Z
type: bug
priority: 4
assignee: Joe Oakhart
---
# phase-10-merge-verify sub-agent redundantly checks CI via validate.sh --ci after ci-status.sh wait

In plugins/dso/skills/debug-everything/prompts/phase-10-merge-verify.md, the sub-agent runs ci-status.sh --wait (line 38) to wait for CI, then also runs validate.sh --ci (line 94) which calls check_ci() internally. The CI status check in validate.sh --ci is redundant because ci-status.sh --wait already determined CI health. Fix: pass --skip-ci to validate.sh in phase-10-merge-verify.md (same fix as w21-jb9k applied to local-validation.md in /dso:validate-work).

