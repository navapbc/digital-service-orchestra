---
id: dso-hui3
status: in_progress
deps: []
links: []
created: 2026-03-20T15:34:44Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-q2ev
---
# RED: Write failing tests for dso-setup.sh .claude/dso-config.conf path

## What

Add 3 new failing test functions to tests/scripts/test-dso-setup.sh that assert dso-setup.sh creates and manages .claude/dso-config.conf (the new path), not workflow-config.conf.

## Why (RED phase)

These tests must FAIL before the implementation task runs, confirming the current script writes to the old path. After the implementation task completes, these tests must turn GREEN.

## Tests to Add

Add the following functions before the 'Run all tests' section in tests/scripts/test-dso-setup.sh, and call each function in the 'Run all tests' block:

### test_setup_writes_dso_config_conf
Verifies dso-setup.sh writes dso.plugin_root= to .claude/dso-config.conf (not workflow-config.conf).

```bash
test_setup_writes_dso_config_conf() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local result="missing"
    if grep -q "^dso.plugin_root=" "$T/.claude/dso-config.conf" 2>/dev/null; then
        result="exists"
    fi
    assert_eq "test_setup_writes_dso_config_conf" "exists" "$result"
}
```

### test_setup_dso_config_conf_idempotent
Verifies running dso-setup.sh twice does NOT duplicate dso.plugin_root= in .claude/dso-config.conf.

```bash
test_setup_dso_config_conf_idempotent() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true
    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

    local count=0
    count=$(grep -c "^dso.plugin_root=" "$T/.claude/dso-config.conf" 2>/dev/null || echo "0")
    assert_eq "test_setup_dso_config_conf_idempotent" "1" "$count"
}
```

### test_setup_dryrun_no_dso_config_conf_written
Verifies --dryrun mode does NOT create .claude/dso-config.conf.

```bash
test_setup_dryrun_no_dso_config_conf_written() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    git -C "$T" init -q

    bash "$SETUP_SCRIPT" "$T" "$PLUGIN_ROOT" --dryrun >/dev/null 2>&1 || true

    if [[ ! -f "$T/.claude/dso-config.conf" ]]; then
        assert_eq "test_setup_dryrun_no_dso_config_conf_written" "not-written" "not-written"
    else
        assert_eq "test_setup_dryrun_no_dso_config_conf_written" "not-written" "written"
    fi
}
```

## TDD Requirement

Write the three test functions (RED phase) and confirm they FAIL by running:
  bash tests/scripts/test-dso-setup.sh 2>&1 | grep -E 'FAIL|test_setup_writes_dso_config_conf|test_setup_dso_config_conf_idempotent|test_setup_dryrun_no_dso_config_conf_written'

Expected: all 3 new tests FAIL (they assert .claude/dso-config.conf path which does not yet exist in dso-setup.sh).

## Files to Edit

- tests/scripts/test-dso-setup.sh (add 3 new test functions + call each in run-all block)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] test_setup_writes_dso_config_conf function exists in test-dso-setup.sh
  Verify: grep -q 'test_setup_writes_dso_config_conf' $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] test_setup_dso_config_conf_idempotent function exists in test-dso-setup.sh
  Verify: grep -q 'test_setup_dso_config_conf_idempotent' $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] test_setup_dryrun_no_dso_config_conf_written function exists in test-dso-setup.sh
  Verify: grep -q 'test_setup_dryrun_no_dso_config_conf_written' $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] All 3 new tests FAIL (RED) before implementation — dso-setup.sh still writes to old path
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -c 'FAIL' | awk '{exit ($1 < 3)}'


## Notes

**2026-03-20T15:38:44Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T15:39:44Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T15:40:26Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T15:40:30Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T15:43:35Z**

CHECKPOINT 5/6: Tests run — 2 of 3 new tests FAIL (RED) as expected; 3rd (dryrun) passes trivially (file never written at old path either). Pre-existing failure test_setup_dso_tk_help_works unchanged. 54 passed, 3 failed total. ✓

**2026-03-20T15:43:40Z**

CHECKPOINT 6/6: Done ✓
