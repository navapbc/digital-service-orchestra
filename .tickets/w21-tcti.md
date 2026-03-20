---
id: w21-tcti
status: open
deps: [w21-mzof]
links: []
created: 2026-03-20T02:38:54Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-mzof
---
# RED: Tests for contract detection in implementation-plan SKILL.md

## Description
Create tests/scripts/test-implementation-plan-contracts.sh with 5 test functions following project conventions (set -uo pipefail, PASS/FAIL counters, summary block):

1. test_contract_detection_section_exists — grep SKILL.md for '### Contract Detection Pass' heading
2. test_contract_emit_parse_pattern — grep for emit/parse signal pair detection (both 'emit' and 'parse' in contract detection section)
3. test_contract_orchestrator_subagent_pattern — grep for orchestrator/sub-agent report schema pattern
4. test_contract_deduplication — grep for 'tk dep tree' AND 'existing contract' or 'Contract:' in contract detection section
5. test_contract_task_template — grep for contract task template with 'plugins/dso/docs/contracts/' artifact path

All 5 FAIL (RED). Test harness uses project-standard FAIL: prefix, PASS: prefix, RESULT: PASS/FAIL summary.

TDD: These ARE the RED tests.

## File Impact
- tests/scripts/test-implementation-plan-contracts.sh (create)

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash tests/run-all.sh
- [ ] Test file exists
  Verify: test -f tests/scripts/test-implementation-plan-contracts.sh
- [ ] Valid bash syntax
  Verify: bash -n tests/scripts/test-implementation-plan-contracts.sh
- [ ] Contains 5 test functions
  Verify: test $(grep -c 'test_contract_' tests/scripts/test-implementation-plan-contracts.sh) -ge 5
- [ ] All 5 FAIL (RED)
  Verify: bash tests/scripts/test-implementation-plan-contracts.sh 2>&1 | grep -c 'FAIL:' | { read c; test "$c" -ge 5; }

