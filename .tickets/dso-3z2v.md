---
id: dso-3z2v
status: open
deps: [dso-zq4q]
links: []
created: 2026-03-18T07:37:13Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-ff9f
---
# Add pre-commit hook installation and example config scaffolding to dso-setup.sh

Expand scripts/dso-setup.sh to install pre-commit hooks and copy example config files.

TDD REQUIREMENT: Write failing tests FIRST (RED), then implement (GREEN).

RED tests to write in tests/scripts/test-dso-setup.sh:
- test_setup_copies_precommit_config: when .pre-commit-config.yaml absent in target, script copies examples/pre-commit-config.example.yaml there
- test_setup_precommit_config_not_overwritten: when .pre-commit-config.yaml already present, script does NOT overwrite it
- test_setup_precommit_config_contains_review_gate: copied file contains 'pre-commit-review-gate' entry
- test_setup_copies_ci_yml: when .github/workflows/ci.yml absent, script copies examples/ci.example.yml
- test_setup_ci_yml_not_overwritten: when ci.yml already present, script does NOT overwrite it
Note: Tests for pre-commit hook registration cannot verify .git/hooks in temp dirs without a real git repo init. Use mktemp -d + git init in tests.

Implementation in dso-setup.sh:
1. Copy example pre-commit config if target does not have it:
   TARGET_PRECOMMIT="$TARGET_REPO/.pre-commit-config.yaml"
   if [ ! -f "$TARGET_PRECOMMIT" ]; then
     cp "$PLUGIN_ROOT/examples/pre-commit-config.example.yaml" "$TARGET_PRECOMMIT"
   fi
2. Copy example CI workflow if target does not have it:
   mkdir -p "$TARGET_REPO/.github/workflows"
   if [ ! -f "$TARGET_REPO/.github/workflows/ci.yml" ]; then
     cp "$PLUGIN_ROOT/examples/ci.example.yml" "$TARGET_REPO/.github/workflows/ci.yml"
   fi
NOTE: Example source files are in plugin's examples/ directory:
  - Source: examples/pre-commit-config.example.yaml → Dest: TARGET_REPO/.pre-commit-config.yaml
  - Source: examples/ci.example.yml → Dest: TARGET_REPO/.github/workflows/ci.yml
  Source file existence should be verified in tests.

3. Run pre-commit install AFTER config copy (config must exist before hooks are registered):
   if command -v pre-commit >/dev/null 2>&1 && [ -f "$TARGET_REPO/.pre-commit-config.yaml" ]; then
     (cd "$TARGET_REPO" && pre-commit install && pre-commit install --hook-type pre-push) || true
   fi
   NOTE: Config copy MUST happen before pre-commit install (ordering is critical).

## Acceptance Criteria

- [ ] bash tests/scripts/test-dso-setup.sh passes with 0 failures
  Verify: bash /Users/joeoakhart/digital-service-orchestra/tests/scripts/test-dso-setup.sh 2>&1 | tail -1 | grep -q 'FAILED: 0'
- [ ] .pre-commit-config.yaml copied to fresh target by dso-setup.sh
  Verify: bash -c 'T=$(mktemp -d) && git -C $T init -q && bash /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh $T /Users/joeoakhart/digital-service-orchestra >/dev/null 2>&1; test -f $T/.pre-commit-config.yaml'
- [ ] copied .pre-commit-config.yaml contains review-gate hook entry
  Verify: bash -c 'T=$(mktemp -d) && git -C $T init -q && bash /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh $T /Users/joeoakhart/digital-service-orchestra >/dev/null 2>&1; grep -q pre-commit-review-gate $T/.pre-commit-config.yaml'
- [ ] Example source files exist before copy attempt
  Verify: test -f /Users/joeoakhart/digital-service-orchestra/examples/pre-commit-config.example.yaml && test -f /Users/joeoakhart/digital-service-orchestra/examples/ci.example.yml
- [ ] Config copy happens before pre-commit install in script (ordering check)
  Verify: awk '/pre-commit-config/{print NR, "config"} /pre-commit install/{print NR, "install"}' /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh | awk 'NR==1{c=$1} NR==2{i=$1} END{exit (c > i)}'
- [ ] Scripts pass ruff check
  Verify: ruff check scripts/*.py tests/**/*.py 2>&1 | grep -q 'All checks passed'

## Notes

**2026-03-18T07:47:05Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T07:47:16Z**

CHECKPOINT 2/6: Code patterns understood ✓ — examples/ dir exists with pre-commit-config.example.yaml and ci.example.yml; pre-commit-review-gate entry confirmed in example config

**2026-03-18T07:47:55Z**

CHECKPOINT 3/6: Tests written ✓ — RED phase confirmed: 3 tests fail (test_setup_copies_precommit_config, test_setup_precommit_config_contains_review_gate, test_setup_copies_ci_yml); 2 tests pass trivially (not-overwritten checks pass since copy doesn't happen yet)

**2026-03-18T07:48:39Z**

CHECKPOINT 4/6: Implementation complete ✓ — added config copy for .pre-commit-config.yaml and ci.yml (skip-if-exists), pre-commit install after config copy

**2026-03-18T07:48:43Z**

CHECKPOINT 5/6: Validation passed ✓ — PASSED: 16 FAILED: 0; all 6 AC criteria pass

**2026-03-18T07:48:43Z**

CHECKPOINT 6/6: Done ✓ — all AC verifications confirmed
