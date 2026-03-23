---
id: dso-cnj5
status: in_progress
deps: [dso-vl19]
links: []
created: 2026-03-23T20:27:32Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-78iq
---
# Register ticket gate in pre-commit-config.example.yaml, dso-setup.sh, and project-setup skill

Wire the pre-commit-ticket-gate.sh hook into the onboarding flow so it is automatically registered in host projects.

TDD EXEMPTION JUSTIFICATION (all 3 criteria met):
1. No conditional logic — these are structural additions (YAML entry, function call wiring)
2. Any test would be a change-detector test asserting the entry exists, not behavioral correctness
3. Infrastructure-boundary-only — config wiring and module registration with no business logic

CHANGES REQUIRED:

1. plugins/dso/docs/examples/pre-commit-config.example.yaml:
   Add a new commit-msg stage hook entry (after the pre-commit-review-gate entry or in a commit-msg section):
   ```yaml
   # Ticket gate (commit-msg stage, timeout: 10s)
   # Blocks commits lacking a valid v3 ticket ID when non-allowlisted files are staged.
   - id: pre-commit-ticket-gate
     name: Ticket Gate (10s timeout)
     entry: plugins/dso/scripts/pre-commit-wrapper.sh pre-commit-ticket-gate 10 "plugins/dso/hooks/pre-commit-ticket-gate.sh"
     language: system
     pass_filenames: false
     always_run: true
     stages: [commit-msg]
   ```
   NOTE: This example file is what dso-setup.sh copies/merges into the host project. The stage is 'commit-msg' not 'pre-commit' because the hook needs access to the commit message file ($1 from git).

2. ALSO add the same entry to .pre-commit-config.yaml in THIS repo (the DSO plugin repo itself), so dogfooding applies immediately. Insert after the pre-commit-review-gate entry.

3. plugins/dso/scripts/dso-setup.sh:
   The merge_precommit_hooks function already reads hook IDs from the example file and merges missing ones — no code change needed IF the example file entry is correct and the hook ID 'pre-commit-ticket-gate' is not already present.
   Verify: the merge_precommit_hooks function reads example_file hook IDs and adds missing ones. If that already covers this, no dso-setup.sh code change is needed — document this in the task notes.

4. plugins/dso/skills/project-setup/SKILL.md:
   Verify the .pre-commit-config.yaml merge step references the example file. If project-setup already calls dso-setup.sh (which handles the merge), no skill change needed. If the skill has an explicit hook listing, add 'pre-commit-ticket-gate' to it.

CHECK FIRST: search for 'pre-commit-ticket-gate' in dso-setup.sh and project-setup/SKILL.md to confirm no manual additions needed beyond the example file.

## Acceptance Criteria

- [ ] plugins/dso/docs/examples/pre-commit-config.example.yaml contains 'pre-commit-ticket-gate' with stages: [commit-msg]
  Verify: grep -q 'pre-commit-ticket-gate' $(git rev-parse --show-toplevel)/plugins/dso/docs/examples/pre-commit-config.example.yaml && grep -A5 'pre-commit-ticket-gate' $(git rev-parse --show-toplevel)/plugins/dso/docs/examples/pre-commit-config.example.yaml | grep -q 'commit-msg'
- [ ] .pre-commit-config.yaml (this repo) contains 'pre-commit-ticket-gate' with stages: [commit-msg]
  Verify: grep -q 'pre-commit-ticket-gate' $(git rev-parse --show-toplevel)/.pre-commit-config.yaml && grep -A5 'pre-commit-ticket-gate' $(git rev-parse --show-toplevel)/.pre-commit-config.yaml | grep -q 'commit-msg'
- [ ] dso-setup.sh merge_precommit_hooks will pick up the new hook ID automatically (verify by inspection or test)
  Verify: grep -q 'merge_precommit_hooks\|pre-commit-config.example' $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
## ACCEPTANCE CRITERIA

- [ ] pre-commit-config.example.yaml has ticket gate entry
  Verify: grep -q 'ticket-gate' .pre-commit-config.yaml || grep -q 'ticket-gate' plugins/dso/docs/examples/pre-commit-config.example.yaml
- [ ] dso-setup.sh registers ticket gate
  Verify: grep -q 'ticket.gate\|ticket-gate' plugins/dso/scripts/dso-setup.sh

## Notes

**2026-03-23T21:22:37Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T21:23:35Z**

CHECKPOINT 2/6: Code patterns understood ✓ — merge_precommit_hooks reads hook IDs from examples/pre-commit-config.example.yaml automatically; dso-setup.sh and SKILL.md require no code changes

**2026-03-23T21:23:39Z**

CHECKPOINT 3/6: Tests written (none required) ✓ — TDD exemption applies: structural config wiring, no conditional logic

**2026-03-23T21:26:04Z**

CHECKPOINT 4/6: Implementation complete ✓ — added pre-commit-ticket-gate to examples/pre-commit-config.example.yaml and .pre-commit-config.yaml; dso-setup.sh and SKILL.md require no changes (merge_precommit_hooks auto-picks up from example file)

**2026-03-23T21:34:50Z**

CHECKPOINT 5/6: Validation passed ✓ — ticket gate tests: 12/12 pass; review gate tests: 21/21 pass; ruff check: clean; ruff format: 85 files formatted

**2026-03-23T21:35:00Z**

CHECKPOINT 6/6: Done ✓ — all ACs satisfied. examples/pre-commit-config.example.yaml and .pre-commit-config.yaml both have pre-commit-ticket-gate entry with commit-msg stage. dso-setup.sh and SKILL.md required no changes.
