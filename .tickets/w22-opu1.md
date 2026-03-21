---
id: w22-opu1
status: open
deps: [w22-5e4i]
links: []
created: 2026-03-21T16:58:51Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w22-528r
---
# As a platform engineer, I can declare unknown test patterns via config keys

## Description

**What**: Support test.suite.<name>.command and test.suite.<name>.speed_class keys in .claude/dso-config.conf that are parsed by project-detect.sh --suites and merged with auto-discovered suites.
**Why**: Not all test patterns are auto-detectable. Config keys let engineers declare custom runners that appear in the same JSON output alongside auto-discovered suites.
**Scope**:
- IN: Config key parsing, merge-by-name with auto-discovered suites (config wins on explicit fields), config-only suites get runner=config
- OUT: Auto-discovery heuristics (story w22-5e4i), CI workflow generation (Milestone B)

## Done Definitions

- When this story is complete, declaring test.suite.custom.command=bash run-custom.sh in dso-config.conf causes project-detect.sh --suites to include an entry with name=custom, runner=config
  ← Satisfies: "Unknown testing patterns can be declared manually via config keys"
- When this story is complete, a config-declared suite with the same name as an auto-discovered suite merges correctly (config fields win)
  ← Satisfies: "Config entries merge with auto-discovered suites by name"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Reliability] Merge semantics must handle partial config declarations (command set, speed_class absent)
