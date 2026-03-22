---
id: w21-v9tg
status: open
deps: [w21-ulsg, w21-cxzv]
links: []
created: 2026-03-21T23:38:25Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-5e4i
---
# Implement npm and bash runner heuristics with dedup and precedence ordering

Extend project-detect.sh --suites with npm scripts and bash runner heuristics, implement deduplication by name, and enforce precedence ordering: config > Makefile > pytest > npm > bash.

TDD Requirement: This task turns GREEN the RED tests from T3:
- test_project_detect_suites_npm
- test_project_detect_suites_bash_runner
- test_project_detect_suites_dedup_by_name
- test_project_detect_suites_precedence_config_over_makefile
- test_project_detect_suites_bash_name_derivation

Implementation steps in plugins/dso/scripts/project-detect.sh (--suites path only):
1. npm heuristic: parse package.json scripts starting with 'test' or 'test:'. For each script key 'test:foo' or 'test-foo', derive name by stripping 'test:' or 'test-' or 'test_' prefix. Entry: {name, command: 'npm run $key', speed_class: 'unknown', runner: 'npm'}. Use python3 (stdlib) for JSON parsing.
2. bash runner heuristic: find executable files in PROJECT_DIR root matching test-*.sh, run-tests*.sh, or test_*.sh patterns. Name derivation: strip leading 'test-', 'test_', 'run-tests-', 'run-tests_' prefix and .sh suffix. Entry: {name, command: 'bash $filename', speed_class: 'unknown', runner: 'bash'}
3. Dedup by name: collect all entries from all heuristics (Makefile, pytest, npm, bash, config from next task). Apply precedence ordering: config > Makefile > pytest > npm > bash. For each name, keep only the highest-precedence entry. Use an associative array (bash 4+) or python3 for ordering.
4. Output final deduped array sorted consistently (e.g., by name alphabetically) as JSON.

Name derivation rules (consistent with story spec):
- Makefile 'test-foo' or 'test_foo' -> name='foo'
- pytest 'tests/unit/' -> name='unit'
- npm 'test:integration' -> name='integration'
- bash 'test-hooks.sh' -> name='hooks', 'run-tests-integration.sh' -> name='integration'

This task does NOT implement config merge (that is T7).

## Acceptance Criteria

- [ ] npm 'test:unit' script -> JSON entry name=unit, runner=npm, command='npm run test:unit'
  Verify: TMPD=$(mktemp -d) && printf '{"scripts":{"test:unit":"jest unit"}}' > "$TMPD/package.json" && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh --suites "$TMPD" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(e["name"]=="unit" and e["runner"]=="npm" for e in d)' && rm -rf "$TMPD"
- [ ] Executable test-hooks.sh in repo root -> JSON entry name=hooks, runner=bash
  Verify: TMPD=$(mktemp -d) && echo '#!/bin/bash' > "$TMPD/test-hooks.sh" && chmod +x "$TMPD/test-hooks.sh" && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh --suites "$TMPD" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(e["name"]=="hooks" and e["runner"]=="bash" for e in d)' && rm -rf "$TMPD"
- [ ] Makefile test-unit + pytest tests/unit/ -> ONE entry for name=unit (Makefile wins), runner=make
  Verify: TMPD=$(mktemp -d) && printf 'test-unit:\n\tpytest tests/unit/' > "$TMPD/Makefile" && mkdir -p "$TMPD/tests/unit" && touch "$TMPD/tests/unit/test_foo.py" && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh --suites "$TMPD" | python3 -c 'import sys,json; d=json.load(sys.stdin); units=[e for e in d if e["name"]=="unit"]; assert len(units)==1 and units[0]["runner"]=="make"' && rm -rf "$TMPD"
- [ ] RED tests from T3 now pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh 2>&1 | grep -qE 'PASS.*suites_npm|PASS.*suites_bash_runner|PASS.*suites_dedup'
- [ ] ruff format --check passes (exit 0) on py files
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py
- [ ] ruff check passes (exit 0) on py files
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py
- [ ] Malformed package.json does not crash --suites (script emits warning to stderr, continues, exits 0)
  Verify: TMPD=$(mktemp -d) && echo 'not valid json' > "$TMPD/package.json" && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh --suites "$TMPD" > /dev/null && echo $? | grep -q '^0$' && rm -rf "$TMPD"

