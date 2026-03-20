---
id: dso-ghcp
status: closed
deps: [dso-zq4q, dso-kknz]
links: []
created: 2026-03-18T07:38:00Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-ff9f
jira_key: DIG-74
---
# Add optional dep detection, env var guidance, and success summary to dso-setup.sh

Expand scripts/dso-setup.sh to detect optional dependencies (acli, PyYAML), print environment variable guidance, and display a success summary with next steps.

TDD REQUIREMENT: Write failing tests FIRST (RED), then implement (GREEN).

RED tests to write in tests/scripts/test-dso-setup.sh:
- test_setup_outputs_env_var_guidance: script output contains guidance about CLAUDE_PLUGIN_ROOT
- test_setup_outputs_success_summary: script output contains 'next steps' or '/dso:project-setup' reference
- test_setup_outputs_optional_dep_guidance: when acli not in PATH, script output mentions acli
- test_setup_is_still_idempotent_with_new_features: running script twice produces same state (no extra lines added)

Implementation in dso-setup.sh:
1. Detect optional deps (non-blocking, always continue):
   if ! command -v acli >/dev/null 2>&1; then
     echo '[optional] acli not found. Install: brew install acli (enables Jira integration in DSO)'
   fi
   # Check for PyYAML:
   if ! python3 -c 'import yaml' >/dev/null 2>&1; then
     echo '[optional] PyYAML not found. Install: pip3 install pyyaml (enables legacy YAML config path)'
   fi
2. Print env var guidance block at end:
   echo '=== Environment Variables (add to your shell profile) ==='
   echo 'CLAUDE_PLUGIN_ROOT=  # Required: DSO plugin path'
   echo 'JIRA_URL=https://your-org.atlassian.net  # Required for Jira sync'
   echo 'JIRA_USER=you@example.com  # Required for Jira sync'
   echo 'JIRA_API_TOKEN=...  # Required for Jira sync'
3. Print next steps:
   echo '=== Setup complete. Next steps: ==='
   echo '1. Edit workflow-config.conf to configure your project'
   echo '2. Invoke /dso:project-setup in Claude Code for interactive configuration'
   echo '3. See docs/INSTALL.md for full documentation'

## Acceptance Criteria

- [ ] bash tests/scripts/test-dso-setup.sh passes with 0 failures
  Verify: bash /Users/joeoakhart/digital-service-orchestra/tests/scripts/test-dso-setup.sh 2>&1 | tail -1 | grep -q 'FAILED: 0'
- [ ] Script output includes CLAUDE_PLUGIN_ROOT guidance
  Verify: bash -c 'T=$(mktemp -d) && git -C $T init -q && bash /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh $T /Users/joeoakhart/digital-service-orchestra 2>&1 | grep -q CLAUDE_PLUGIN_ROOT'
- [ ] Script output includes next steps referencing /dso:project-setup
  Verify: bash -c 'T=$(mktemp -d) && git -C $T init -q && bash /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh $T /Users/joeoakhart/digital-service-orchestra 2>&1 | grep -q project-setup'
- [ ] Scripts pass ruff check
  Verify: ruff check scripts/*.py tests/**/*.py 2>&1 | grep -q 'All checks passed'

## Notes

**2026-03-18T07:48:50Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T07:48:55Z**

CHECKPOINT 2/6: Code patterns understood ✓ — dso-setup.sh now 107 lines with bash shebang, detect_prerequisites(), config copy, and pre-commit install; test file has 16 passing tests using assert_eq pattern

**2026-03-18T07:49:30Z**

CHECKPOINT 3/6: Tests written ✓ — 3 tests fail as expected (RED): test_setup_outputs_env_var_guidance, test_setup_outputs_success_summary, test_setup_outputs_optional_dep_guidance

**2026-03-18T07:53:12Z**

CHECKPOINT 4/6: Implementation complete ✓ — added optional dep detection (acli, PyYAML), env var guidance block (CLAUDE_PLUGIN_ROOT, JIRA_*), success summary with next steps referencing project-setup

**2026-03-18T07:53:12Z**

CHECKPOINT 5/6: Validation passed ✓ — PASSED: 20 FAILED: 0; all 4 AC criteria pass

**2026-03-18T07:53:12Z**

CHECKPOINT 6/6: Done ✓ — all AC verifications confirmed; note: linter enforces /dso:init in skill refs so 'project-setup' appears as descriptive text in output rather than as a skill invocation
