---
id: dso-q0df
status: closed
deps: []
links: []
created: 2026-03-18T17:29:19Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-5lb8
---
# Remove _phase_checkpoint_verify from scripts/merge-to-main.sh

Remove the checkpoint_verify phase entirely from scripts/merge-to-main.sh.

## What to change

1. Delete the `_phase_checkpoint_verify()` function body (the entire block starting at the `# --- 1.7) Verify checkpoint review sentinel ---` comment through the closing `}`).
2. Remove `checkpoint_verify` from the `_ALL_PHASES=(...)` array. The updated array should be: `_ALL_PHASES=(sync merge validate push archive ci_trigger)`
3. Remove the `_phase_checkpoint_verify` call from the main execution sequence (bottom of file).
4. Update the `--help` usage block to remove `checkpoint_verify` from the phase list.

## TDD Requirement

Write a failing test FIRST:
- Assert `_phase_checkpoint_verify` does NOT appear in the file: `grep -c '_phase_checkpoint_verify' scripts/merge-to-main.sh` returns 0
- Assert `checkpoint_verify` does NOT appear in `_ALL_PHASES`

Confirm the test fails (RED). Then make the deletions. Confirm the test passes (GREEN).

## Known Test Impact

`tests/scripts/test-merge-to-main.sh` currently asserts 7 phase functions exist including `_phase_checkpoint_verify`. After this task, that test will fail. This is expected — the test file update is scoped to sibling story dso-jneo (which dso-5lb8 blocks). Do NOT update the test file in this task.

## Files

- `scripts/merge-to-main.sh` — Edit (deletions only)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes for all test suites EXCEPT test-merge-to-main.sh (which will fail until dso-jneo lands)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh 2>&1 | grep -v "test-merge-to-main" | grep -c "FAIL" | awk '{exit ($1 > 0)}'
- [ ] `_phase_checkpoint_verify` function is absent from scripts/merge-to-main.sh
  Verify: ! grep -q '_phase_checkpoint_verify' $(git rev-parse --show-toplevel)/scripts/merge-to-main.sh
- [ ] `checkpoint_verify` is absent from the entire scripts/merge-to-main.sh file
  Verify: ! grep -q 'checkpoint_verify' $(git rev-parse --show-toplevel)/scripts/merge-to-main.sh
- [ ] `--help` output no longer lists `checkpoint_verify` as a valid phase
  Verify: ! bash $(git rev-parse --show-toplevel)/scripts/merge-to-main.sh --help 2>&1 | grep -q 'checkpoint_verify'
- [ ] `_ALL_PHASES` array contains exactly 6 phases (sync merge validate push archive ci_trigger)
  Verify: grep '_ALL_PHASES=' $(git rev-parse --show-toplevel)/scripts/merge-to-main.sh | grep -q 'sync merge validate push archive ci_trigger'
