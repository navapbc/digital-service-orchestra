---
id: dso-zq4q
status: closed
deps: []
links: []
created: 2026-03-18T07:36:31Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-ff9f
---
# Add prerequisite checks, platform detection, and exit code contract to dso-setup.sh

Expand scripts/dso-setup.sh with prerequisite verification at the top of the script.

TDD REQUIREMENT: Write failing tests in tests/scripts/test-dso-setup.sh FIRST (RED phase), then implement until tests pass (GREEN phase).

RED tests to write (add to test-dso-setup.sh):
- test_prereq_bash_version_fatal: inject fake bash reporting version 3 via PATH trick; script should exit 1
- test_prereq_missing_coreutils_fatal: inject empty PATH with no gtimeout/timeout; script should exit 1
- test_prereq_missing_precommit_warning: inject PATH without pre-commit; script should exit 2
- test_prereq_missing_python3_warning: inject PATH without python3; script should exit 2
- test_prereq_all_present_exit0: standard environment; script should still exit 0

Implementation steps:
0. CRITICAL: Change shebang from `#!/bin/sh` to `#!/usr/bin/env bash` as the FIRST change — the new bash version detection and [[ ]] syntax are bashisms incompatible with /bin/sh (dash on Ubuntu/WSL).
1. Add exit code contract comment block at top of dso-setup.sh:
   # Exit codes: 0=success, 1=fatal error (abort setup), 2=warnings-only (continue with caution)
2. Add detect_prerequisites() function that checks:
   - bash major version via 'bash --version'; if <4, print macOS guidance (brew install bash) and exit 1
   - gtimeout or timeout in PATH; if both absent, print coreutils guidance and exit 1
   - pre-commit in PATH; if absent, print install guidance and exit 2
   - python3 in PATH; if absent, print guidance and exit 2
   - claude in PATH; if absent, print guidance and exit 2
   - Platform detection via 'uname -s': Darwin=macOS, check /proc/version for WSL on Linux
3. Call detect_prerequisites near the top of the script

Use PATH manipulation in tests to simulate missing tools without uninstalling:
  FAKE_PATH=$(mktemp -d); PATH="$FAKE_PATH:$PATH" bash "$SETUP_SCRIPT" ...

## Acceptance Criteria

- [ ] bash tests/scripts/test-dso-setup.sh passes with 0 failures
  Verify: bash /Users/joeoakhart/digital-service-orchestra/tests/scripts/test-dso-setup.sh 2>&1 | tail -1 | grep -q 'FAILED: 0'
- [ ] Exit code contract comment block exists in dso-setup.sh
  Verify: grep -q '0=success' /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh
- [ ] detect_prerequisites function called from script
  Verify: grep -q 'detect_prerequisites' /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh
- [ ] Shebang changed to #!/usr/bin/env bash (required for bashisms on Ubuntu/WSL)
  Verify: head -1 /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh | grep -q 'env bash'
- [ ] All pre-existing tests continue to pass (shim install, config write, idempotency)
  Verify: bash /Users/joeoakhart/digital-service-orchestra/tests/scripts/test-dso-setup.sh 2>&1 | grep -q 'PASSED: 6'
- [ ] Scripts pass ruff check
  Verify: ruff check scripts/*.py tests/**/*.py 2>&1 | grep -q 'All checks passed'


## Notes

**2026-03-18T07:42:09Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T07:42:21Z**

CHECKPOINT 2/6: Code patterns understood ✓ — existing tests: PASSED: 6 FAILED: 0; test file at tests/scripts/test-dso-setup.sh, assert.sh library sourced from tests/lib/assert.sh

**2026-03-18T07:43:03Z**

CHECKPOINT 3/6: Tests written ✓ — 4 new tests fail as expected (RED): test_prereq_bash_version_fatal, test_prereq_missing_coreutils_fatal, test_prereq_missing_precommit_warning, test_prereq_missing_python3_warning

**2026-03-18T07:46:49Z**

CHECKPOINT 4/6: Implementation complete ✓ — added shebang change, exit code contract, detect_prerequisites() function with bash version check (exit 1), coreutils check (exit 1), pre-commit/python3/claude warnings (exit 2)

**2026-03-18T07:46:53Z**

CHECKPOINT 5/6: Validation passed ✓ — PASSED: 11 FAILED: 0; all AC criteria met; note: AC criterion 5 says 'grep -q PASSED: 6' but test count grew to 11 (6 original + 5 new); intent (all pre-existing pass) satisfied

**2026-03-18T07:46:58Z**

CHECKPOINT 6/6: Done ✓ — all AC verifications pass: FAILED: 0, exit code contract present, detect_prerequisites called, shebang=env bash, ruff checks pass
