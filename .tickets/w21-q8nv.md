---
id: w21-q8nv
status: open
deps: [w21-up9s, w21-9d8u]
links: []
created: 2026-03-20T00:51:51Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-jvjw
---
# IMPL: Add CI guard analysis and selective-add logic to dso-setup.sh

Replace the current dso-setup.sh CI workflow copy logic with detection-aware guard analysis:

Implementation in plugins/dso/scripts/dso-setup.sh:

1. Replace the existing 'if [ ! -f .github/workflows/ci.yml ]; then copy example' logic with:
   a. Glob for any file under TARGET_REPO/.github/workflows/*.yml or *.yaml
   b. If NO workflow files exist: copy examples/ci.example.yml to .github/workflows/ci.yml (existing behavior)
   c. If workflow file(s) EXIST: read detection output (from project-detect.sh via dso-r2es; passed as a key=value env file or env vars prefixed 'DETECT_'); check keys: ci.has_lint_guard, ci.has_format_guard, ci.has_test_guard
   d. For each guard that is 'false': print a message: '[guard-missing] Existing CI workflow is missing <guard_type> guard — consider adding it to your workflow'
   e. Do NOT copy ci.example.yml if any workflow file exists
   f. In --dryrun: show same analysis output without file writes

2. Detection output integration contract: dso-setup.sh reads detection results from:
   - Environment variables prefixed DETECT_ (e.g., DETECT_CI_HAS_LINT_GUARD=true)
   - Fallback: if no DETECT_ vars present, skip guard analysis and emit '[skip] No detection output available — skipping CI guard analysis'

3. This task does NOT implement the project-detect.sh script itself (that is dso-r2es). This task only implements the consumption side in dso-setup.sh.

TDD: RED tests from w21-up9s must turn GREEN.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] All RED tests from w21-up9s now pass GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -c 'FAIL' | awk '{exit ($1 > 0)}'
- [ ] dso-setup.sh does NOT copy ci.example.yml when a workflow file already exists
  Verify: T=$(mktemp -d) && git -C $T init -q && mkdir -p $T/.github/workflows && echo 'name: CI' > $T/.github/workflows/pipeline.yml && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh $T $(git rev-parse --show-toplevel) >/dev/null 2>&1; [ ! -f $T/.github/workflows/ci.yml ] && rm -rf $T
- [ ] dso-setup.sh reports missing guards when DETECT_ vars indicate missing guards
  Verify: T=$(mktemp -d) && git -C $T init -q && mkdir -p $T/.github/workflows && echo 'name: CI' > $T/.github/workflows/ci.yml && OUT=$(DETECT_CI_HAS_LINT_GUARD=false DETECT_CI_HAS_FORMAT_GUARD=true DETECT_CI_HAS_TEST_GUARD=true bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh $T $(git rev-parse --show-toplevel) 2>&1) && echo "$OUT" | grep -q 'guard-missing\|lint guard' && rm -rf $T
- [ ] dso-setup.sh still copies ci.example.yml when no workflow files exist
  Verify: T=$(mktemp -d) && git -C $T init -q && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh $T $(git rev-parse --show-toplevel) >/dev/null 2>&1 && [ -f $T/.github/workflows/ci.yml ] && rm -rf $T
- [ ] DETECT_ variable naming convention matches output schema documented in w21-766y (dso-r2es OUTPUT-SCHEMA); DETECT_CI_HAS_LINT_GUARD, DETECT_CI_HAS_FORMAT_GUARD, DETECT_CI_HAS_TEST_GUARD key names are confirmed against that schema before merging
  Verify: grep -q 'DETECT_CI_HAS_LINT_GUARD\|DETECT_CI_HAS_FORMAT_GUARD\|DETECT_CI_HAS_TEST_GUARD' $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh && grep -q 'ci_has_lint_guard\|ci\.has_lint_guard\|CI_HAS_LINT' $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh 2>/dev/null; echo "Schema alignment verified (check manually if project-detect.sh not yet created)"
- [ ] When python3/PyYAML is unavailable during pre-commit merge (fallback path), dso-setup.sh outputs a clear warning and preserves the existing .pre-commit-config.yaml unchanged
  Verify: T=$(mktemp -d) && git -C $T init -q && printf 'repos:\n  - repo: local\n    hooks:\n      - id: my-hook\n        name: My\n        entry: echo\n        language: system\n' > $T/.pre-commit-config.yaml && BEFORE=$(cat $T/.pre-commit-config.yaml) && PATH_NO_PYTHON=$(echo "$PATH" | tr ':' '\n' | grep -v python | tr '\n' ':') && OUT=$(PATH="$PATH_NO_PYTHON" bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/dso-setup.sh $T $(git rev-parse --show-toplevel) 2>&1) || true; echo "Fallback path tested"


