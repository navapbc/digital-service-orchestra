---
id: w21-cxzv
status: in_progress
deps: [w21-f2k3, w21-okrb]
links: []
created: 2026-03-21T23:37:59Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-5e4i
---
# Implement --suites flag skeleton, Makefile heuristic, and pytest heuristic

Extend plugins/dso/scripts/project-detect.sh with the --suites flag and implement the two highest-precedence heuristics: Makefile targets matching /^test[-_]/ and pytest test directories.

TDD Requirement: This task turns GREEN the RED tests from T1 and T2:
- test_project_detect_suites_backward_compat_no_flag
- test_project_detect_suites_exit_zero_empty_repo
- test_project_detect_suites_exit_zero_always
- test_project_detect_suites_json_schema
- test_project_detect_suites_makefile
- test_project_detect_suites_pytest
- test_project_detect_suites_makefile_name_derivation

Implementation steps in plugins/dso/scripts/project-detect.sh:
1. Argument parsing: detect --suites as the first arg (before PROJECT_DIR). If present, set SUITES_MODE=1 and set PROJECT_DIR to $2 (or default). If absent, behavior is identical to current (no change to existing KEY=VALUE output path).
2. If SUITES_MODE=0: run existing detection logic unchanged, exit.
3. If SUITES_MODE=1: run only suite discovery logic, output JSON array to stdout, exit 0.
4. Makefile heuristic: grep Makefile for lines matching /^test[-_][a-zA-Z0-9_-]+:/ (top-level test targets). For each target 'test-foo' or 'test_foo', derive name by stripping 'test-' or 'test_' prefix. Entry: {name: "$name", command: "make $target", speed_class: "unknown", runner: "make"}
5. pytest heuristic: find directories under tests/ or test/ (at depth 1) containing at least one test_*.py file. For each dir 'tests/foo/', name = 'foo'. Entry: {name: "foo", command: "pytest tests/foo/", speed_class: "unknown", runner: "pytest"}. If tests/ itself has test_*.py files directly, name = 'unit' (default) or the Makefile-matched name if already present.
6. Output: JSON array using python3 (stdlib, no jq) to stdout. Empty array [] if no suites found.
7. Warnings go to stderr only.

Backward compat invariant: Any code path reached without --suites MUST produce byte-identical output to the current implementation. Add a guard comment: '# BACKWARD_COMPAT: do not modify output above this line without a backward-compat test'.

## Acceptance Criteria

- [ ] Script exits 0 when called without --suites (backward compat)
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh $(mktemp -d); echo $?
- [ ] Script exits 0 when called with --suites on empty dir (outputs [])
  Verify: TMPD=$(mktemp -d) && OUT=$(bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh --suites "$TMPD") && echo "$OUT" | python3 -c 'import sys,json; data=json.load(sys.stdin); assert data == [], f"Expected [], got {data}"' && rm -rf "$TMPD"
- [ ] Makefile test-unit target -> JSON entry name=unit, runner=make
  Verify: TMPD=$(mktemp -d) && printf 'test-unit:\n\tpytest tests/unit/' > "$TMPD/Makefile" && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh --suites "$TMPD" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(e["name"]=="unit" and e["runner"]=="make" for e in d)' && rm -rf "$TMPD"
- [ ] pytest tests/models/ dir -> JSON entry name=models, runner=pytest
  Verify: TMPD=$(mktemp -d) && mkdir -p "$TMPD/tests/models" && touch "$TMPD/tests/models/test_model.py" && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh --suites "$TMPD" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert any(e["name"]=="models" and e["runner"]=="pytest" for e in d)' && rm -rf "$TMPD"
- [ ] Without --suites, output contains expected KEY=VALUE keys (no JSON)
  Verify: TMPD=$(mktemp -d) && OUT=$(bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh "$TMPD") && echo "$OUT" | grep -q '^stack=' && ! echo "$OUT" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null && rm -rf "$TMPD"
- [ ] RED tests from T1 and T2 now pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh 2>&1 | grep -qE 'PASS.*suites_json_schema|PASS.*suites_backward_compat'
- [ ] ruff format --check passes (exit 0) on py files
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py
- [ ] ruff check passes (exit 0) on py files
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py


## Notes

**2026-03-22T00:09:09Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T00:09:29Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T00:09:32Z**

CHECKPOINT 3/6: Tests written (none required — RED tests exist) ✓

**2026-03-22T00:10:09Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T00:10:10Z**

CHECKPOINT 5/6: Validation passed ✓ — 96 passed, 0 failed

**2026-03-22T00:11:08Z**

CHECKPOINT 6/6: Done ✓ — All ACs verified. AC6 verify grep pattern has cosmetic mismatch (tests output 'name ... PASS' not 'PASS.*name') but all 7 suites tests pass.
