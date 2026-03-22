---
id: dso-0ey5
status: open
deps: [dso-9mvn, dso-1dws]
links: []
created: 2026-03-22T15:44:28Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ond9
---
# Add YAML validation, command sanitization, and edge-case handling to ci-generator.sh


## Description

Extend plugins/dso/scripts/ci-generator.sh with YAML validation, command sanitization, and edge-case robustness.

Implementation steps:
1. Command sanitization: apply allowlist filter (alphanumeric, space, '-', '_', '/', '.', ':', '=') to suite command strings before embedding in YAML. Reject/strip anything else.
2. YAML validation: after generating YAML to a temp path:
   a. If actionlint is on PATH: run actionlint <temp_file>; non-zero = exit 2, do not write
   b. Else: python3 -c "import yaml; yaml.safe_load(open('<temp_file>').read())" ; exception = exit 2
   c. On validation success: move temp file to final destination
3. Edge cases:
   - Empty suite list: write no files, exit 0
   - Special characters in suite name: normalize to valid job ID (lowercase, replace non-alphanumeric with '-', collapse repeated '-')
   - All-unknown suites in --non-interactive: write all to ci-slow.yml
4. Interactive speed_class prompting:
   - For each unknown suite: prompt "Is [name] a fast test (<30s) or slow test? [fast/slow/skip] (default: slow): "
   - On Enter with no input: treat as slow
   - 'skip': omit this suite from generated workflows

TDD REQUIREMENT: Depends on dso-9mvn RED tests. All tests added in dso-9mvn must pass GREEN after this task. Also depends on dso-1dws (base generator).

Security note: [Security] tag from story — suite commands come from user project config and could contain injection attempts. The allowlist sanitization prevents shell injection in generated YAML.

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] test_command_sanitization_strips_metacharacters passes
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ci-generator.sh 2>&1 | grep -q 'PASS.*test_command_sanitization'
- [ ] test_yaml_validation_blocks_invalid_yaml passes
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ci-generator.sh 2>&1 | grep -q 'PASS.*test_yaml_validation_blocks_invalid_yaml'
- [ ] test_temp_then_move_pattern passes
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ci-generator.sh 2>&1 | grep -q 'PASS.*test_temp_then_move'
- [ ] All test-ci-generator.sh tests pass
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ci-generator.sh; test $? -eq 0
