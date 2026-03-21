---
id: w21-jb9k
status: open
deps: []
links: []
created: 2026-03-21T02:59:11Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Bug: Local validation sub-agent redundantly checks CI status during post-epic validation

During /dso:validate-work, both Sub-Agent 1 (Local Validation) and Sub-Agent 2 (CI Status) check CI status independently. validate.sh --ci includes a ci(main) check that duplicates the dedicated ci-status.sh sub-agent. When Local Validation runs validate.sh --ci, it reports CI failures as local validation failures, conflating local code health with CI pipeline status. Fix: either pass a flag to validate.sh to skip the CI check when called from /dso:validate-work, or update the local-validation prompt to ignore the ci line in validate.sh output.

