---
id: dso-pmaj
status: closed
deps: []
links: []
created: 2026-03-18T04:49:51Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Fix pre-existing precompact telemetry test failures (18 pytest failures)

python3 -m pytest tests/plugin/ tests/scripts/ tests/skills/ -q reports 18 failures in test_precompact_telemetry.py and test_analyze_precompact_telemetry.py. Pre-existing — unrelated to any recent changes. Needs investigation.

