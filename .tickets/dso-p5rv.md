---
id: dso-p5rv
status: open
deps: []
links: []
created: 2026-03-18T00:25:48Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Pre-existing pytest failures: test_analyze_precompact_telemetry + test_precompact_telemetry (18 failures)

18 pytest tests failing in tests/plugin/test_analyze_precompact_telemetry.py (11) and tests/plugin/test_precompact_telemetry.py (7). These are pre-existing failures unrelated to bump-version.sh sprint work. They are part of the broader CI failure pattern tracked in dso-n5dr. Need investigation into what broke these tests.

