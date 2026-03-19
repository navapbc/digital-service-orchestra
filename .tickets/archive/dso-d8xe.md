---
id: dso-d8xe
status: closed
deps: [dso-oqto]
links: []
created: 2026-03-18T17:30:23Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-mjdp
---
# Remove block-sentinel-push from .pre-commit-config.yaml and .checkpoint-pending-rollback from .gitignore

Clean up the two config file entries that exist solely to support the pre-compact checkpoint infrastructure.

## Changes

### .pre-commit-config.yaml
Remove the block-sentinel-push hook entry (lines 48-54 in current file):
  - id: block-sentinel-push
    name: Block checkpoint sentinel push
    language: system
    entry: "bash -c 'git cat-file -t HEAD:.checkpoint-needs-review >/dev/null 2>&1 && exit 1; exit 0'"
    pass_filenames: false
    always_run: true
    stages: [pre-push]

### .gitignore
Remove the .checkpoint-pending-rollback entry including its comment (lines 25-26):
  # Checkpoint marker — written by pre-compact-checkpoint.sh, cleaned after merge/review
  .checkpoint-pending-rollback

## Implementation Steps
1. Edit .pre-commit-config.yaml: delete the block-sentinel-push stanza (7 lines)
2. Edit .gitignore: delete the .checkpoint-pending-rollback entry and its preceding comment line
3. Run pre-commit validate-config .pre-commit-config.yaml (or python3 -c "import yaml; yaml.safe_load(open('.pre-commit-config.yaml'))" ) to confirm YAML validity
4. Confirm no other references to block-sentinel-push exist in the repo

## TDD Requirement (RED before GREEN)
Write these failing tests first:
  grep -c 'block-sentinel-push' .pre-commit-config.yaml  # returns >0 before fix, 0 after
  grep -c 'checkpoint-pending-rollback' .gitignore        # returns >0 before fix, 0 after

## Constraints
- Only .pre-commit-config.yaml and .gitignore are modified in this task
- YAML must remain valid after removal (no indentation errors)
- The pre-push-lint hook (lines 56-63) must remain intact
- Note: examples/pre-commit-config.example.yaml also contains block-sentinel-push — this is OUT OF SCOPE (handled by dso-jbcp)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] .pre-commit-config.yaml contains no block-sentinel-push hook entry
  Verify: ! grep -q 'block-sentinel-push' .pre-commit-config.yaml
- [ ] .gitignore contains no .checkpoint-pending-rollback entry
  Verify: ! grep -q 'checkpoint-pending-rollback' .gitignore
- [ ] .pre-commit-config.yaml is valid YAML
  Verify: python3 -c "import yaml; yaml.safe_load(open('.pre-commit-config.yaml'))"
- [ ] pre-push-lint hook is still present in .pre-commit-config.yaml
  Verify: grep -q 'pre-push-lint' .pre-commit-config.yaml
- [ ] No other references to block-sentinel-push exist in the repo (outside examples/)
  Verify: ! grep -rq 'block-sentinel-push' . --exclude-dir=.git --exclude-dir=.tickets --exclude-dir=examples 2>/dev/null
