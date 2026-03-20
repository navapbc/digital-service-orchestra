---
id: dso-sapj
status: closed
deps: [dso-hui3]
links: []
created: 2026-03-20T15:35:16Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-q2ev
---
# Update dso-setup.sh to create config at .claude/dso-config.conf

## What

Update plugins/dso/scripts/dso-setup.sh to write dso.plugin_root= to .claude/dso-config.conf (not workflow-config.conf), and update all test fixtures in tests/scripts/test-dso-setup.sh that assert the old workflow-config.conf path.

## Why

Story dso-q2ev: dso-setup.sh must create .claude/dso-config.conf in host projects and must not create workflow-config.conf. Story dso-uc2d (CLOSED) already migrated config resolution — this story completes the setup side.

## Changes to dso-setup.sh

1. Line 114 comment: update 'workflow-config.conf' to '.claude/dso-config.conf'
2. Lines 131-141 CONFIG block:
   - Change: CONFIG="$TARGET_REPO/workflow-config.conf"
   - To:     CONFIG="$TARGET_REPO/.claude/dso-config.conf"
   - In the live-run branch (not dryrun), ensure mkdir -p "$(dirname "$CONFIG")" before writing to CONFIG (the .claude/ dir may not exist if setup is running for the first time and hasn't created it yet via shim install — confirm: line 124 already does mkdir -p "$TARGET_REPO/.claude/scripts/" so .claude/ is guaranteed to exist before CONFIG is written; no extra mkdir needed)
   - Update dryrun echo message: 'Would write dso.plugin_root=$PLUGIN_ROOT to $CONFIG' (CONFIG auto-reflects new value)
3. Line 463 env var guidance echo: change 'workflow-config.conf' to '.claude/dso-config.conf'
4. Line 471 next steps echo: change '1. Edit workflow-config.conf' to '1. Edit .claude/dso-config.conf'

## Changes to tests/scripts/test-dso-setup.sh

Update fixture assertions that reference the old path (must reference new path to pass GREEN):

1. test_setup_writes_plugin_root (line 71): grep path "$T/workflow-config.conf" → "$T/.claude/dso-config.conf"
2. test_setup_is_idempotent (lines 91, 102): grep path "$T/workflow-config.conf" → "$T/.claude/dso-config.conf"
   Also update the pre-existing-entry fixture (line 98): echo into "$T2/.claude/dso-config.conf" instead of "$T2/workflow-config.conf"
3. test_setup_dryrun_no_config_written (line 462): check path "$T/workflow-config.conf" → "$T/.claude/dso-config.conf"
4. test_setup_is_still_idempotent_with_new_features (line 432): grep path "$T/workflow-config.conf" → "$T/.claude/dso-config.conf"

## TDD Requirement

This task is GREEN phase — it makes tests written in task dso-hui3 pass.

After changes, run:
  bash tests/scripts/test-dso-setup.sh 2>&1 | tail -20

Expected: ALL tests pass including the 3 new tests from dso-hui3 AND all previously-passing tests (no regressions).

## Acceptance Criteria Details

- [ ] grep -q 'dso.plugin_root=' "$T/.claude/dso-config.conf" passes after fresh setup (new path written)
  Verify: T=$(mktemp -d) && git -C "$T" init -q && bash plugins/dso/scripts/dso-setup.sh "$T" plugins/dso >/dev/null 2>&1; grep -q 'dso.plugin_root=' "$T/.claude/dso-config.conf" && echo OK
- [ ] workflow-config.conf is NOT created at repo root by dso-setup.sh
  Verify: T=$(mktemp -d) && git -C "$T" init -q && bash plugins/dso/scripts/dso-setup.sh "$T" plugins/dso >/dev/null 2>&1; ! test -f "$T/workflow-config.conf" && echo OK
- [ ] dso-setup.sh idempotent: second run does not duplicate entry in .claude/dso-config.conf
  Verify: T=$(mktemp -d) && git -C "$T" init -q && bash plugins/dso/scripts/dso-setup.sh "$T" plugins/dso >/dev/null 2>&1; bash plugins/dso/scripts/dso-setup.sh "$T" plugins/dso >/dev/null 2>&1; count=$(grep -c '^dso.plugin_root=' "$T/.claude/dso-config.conf") && [ "$count" = 1 ] && echo OK
- [ ] --dryrun does not create .claude/dso-config.conf
  Verify: T=$(mktemp -d) && git -C "$T" init -q && bash plugins/dso/scripts/dso-setup.sh "$T" plugins/dso --dryrun >/dev/null 2>&1; ! test -f "$T/.claude/dso-config.conf" && echo OK

## Files to Edit

- plugins/dso/scripts/dso-setup.sh (lines 114, 131, 137, 140, 463, 471)
- tests/scripts/test-dso-setup.sh (lines 71, 91, 98-103, 432, 462)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] dso-setup.sh writes dso.plugin_root= to .claude/dso-config.conf (new path)
  Verify: T=$(mktemp -d) && git -C "$T" init -q && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh "$T" $(git rev-parse --show-toplevel)/plugins/dso >/dev/null 2>&1; grep -q 'dso.plugin_root=' "$T/.claude/dso-config.conf" && echo OK
- [ ] dso-setup.sh does NOT create workflow-config.conf at repo root
  Verify: T=$(mktemp -d) && git -C "$T" init -q && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh "$T" $(git rev-parse --show-toplevel)/plugins/dso >/dev/null 2>&1; ! test -f "$T/workflow-config.conf" && echo OK
- [ ] dso-setup.sh idempotent: second run does not duplicate entry in .claude/dso-config.conf
  Verify: T=$(mktemp -d) && git -C "$T" init -q && R=$(git rev-parse --show-toplevel) && bash "$R/plugins/dso/scripts/dso-setup.sh" "$T" "$R/plugins/dso" >/dev/null 2>&1 && bash "$R/plugins/dso/scripts/dso-setup.sh" "$T" "$R/plugins/dso" >/dev/null 2>&1; count=$(grep -c '^dso.plugin_root=' "$T/.claude/dso-config.conf") && [ "$count" = 1 ] && echo OK
- [ ] --dryrun does not create .claude/dso-config.conf
  Verify: T=$(mktemp -d) && git -C "$T" init -q && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh "$T" $(git rev-parse --show-toplevel)/plugins/dso --dryrun >/dev/null 2>&1; ! test -f "$T/.claude/dso-config.conf" && echo OK
- [ ] All tests in test-dso-setup.sh pass including dso-hui3 RED tests (now GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -c FAIL | awk '{exit ($1 > 0)}'


## Notes

**2026-03-20T15:47:06Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T15:47:21Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T15:48:29Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T15:49:26Z**

CHECKPOINT 5/6: Tests run — 57 PASSED, 0 FAILED ✓

**2026-03-20T15:49:49Z**

CHECKPOINT 6/6: Done ✓ — All 4 AC items verified: dso.plugin_root written to .claude/dso-config.conf, workflow-config.conf NOT created, idempotent, dryrun clean
