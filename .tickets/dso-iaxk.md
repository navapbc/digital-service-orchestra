---
id: dso-iaxk
status: open
deps: [dso-87p7]
links: []
created: 2026-03-22T15:45:39Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ond9
---
# Dogfooding: run /dso:project-setup on DSO repo and verify generated CI passes actionlint


## Description

Dogfooding validation: run ci-generator.sh on the DSO repo's discovered test suites and verify the generated YAML passes actionlint.

Steps:
1. Run: bash plugins/dso/scripts/project-detect.sh --suites . > /tmp/dso-suites.json
2. Run: bash plugins/dso/scripts/ci-generator.sh --suites-json=/tmp/dso-suites.json --output-dir=/tmp/dso-ci-test/ --non-interactive
3. Verify exit 0 from ci-generator.sh
4. If actionlint is available: run actionlint on each generated YAML file; must exit 0
5. If actionlint not available: run python3 -c "import yaml; yaml.safe_load(open('<file>').read())" on each generated file; must exit 0
6. Inspect generated file(s): confirm job IDs match suite names, triggers are correct (pull_request for ci.yml, push for ci-slow.yml)
7. Document findings in a note on this ticket: which suites were discovered, which files were generated, actionlint result

This task does NOT write files to .github/workflows/ — it uses a temp output dir to avoid modifying the repo.

TDD REQUIREMENT: This task has no RED test predecessor — it is a validation/integration task whose deliverable is a passing dogfood run (documented in ticket notes), not new production code.
Exemption: Integration exemption criterion 2 — scaffolding/validation task; behavioral contract is the absence of actionlint errors, which is verified by the task steps directly.

test-exempt: integration-exemption-2 — this is an integration validation task with no new behavioral code; the verification IS the test.

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ci-generator.sh exits 0 on DSO repo suites
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh --suites $(git rev-parse --show-toplevel) > /tmp/dso-dogfood-suites.json && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ci-generator.sh --suites-json=/tmp/dso-dogfood-suites.json --output-dir=/tmp/dso-ci-dogfood/ --non-interactive; test $? -eq 0
- [ ] Generated YAML passes actionlint (or yaml.safe_load if actionlint unavailable)
  Verify: for f in /tmp/dso-ci-dogfood/*.yml; do python3 -c "import yaml; yaml.safe_load(open('$f').read())" || exit 1; done
- [ ] Dogfood results documented in ticket notes (via tk add-note)
  Verify: grep -q 'dogfood\|actionlint\|suites' $(git rev-parse --show-toplevel)/.tickets/dso-iaxk.md
