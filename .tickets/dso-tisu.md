---
id: dso-tisu
status: open
deps: [dso-yncv]
links: []
created: 2026-03-18T16:05:22Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-ojbb
---
# Implement --dryrun flag in scripts/dso-setup.sh (TDD GREEN)

Implement --dryrun flag in scripts/dso-setup.sh so all tests from dso-yncv pass (GREEN phase).

TDD REQUIREMENT: Write failing test test_setup_dryrun_no_shim_created first (already written in dso-yncv), then implement until all dryrun tests pass.

Implementation:
1. Parse --dryrun at the top of the script (before positional arg processing):
   DRYRUN=''
   for arg in "$@"; do [[ "$arg" == '--dryrun' ]] && DRYRUN=1; done
   # Strip --dryrun from positional args before set -- processing

2. Wrap each action block with DRYRUN guard:
   - Shim copy: if [[ -z "$DRYRUN" ]]; then cp/chmod; else echo "[dryrun] Would copy $PLUGIN_ROOT/templates/host-project/dso -> $TARGET_REPO/.claude/scripts/dso (chmod +x)"; fi
   - Config write: if [[ -z "$DRYRUN" ]]; then sed/printf; else echo "[dryrun] Would write dso.plugin_root=$PLUGIN_ROOT to $CONFIG"; fi
   - Pre-commit copy: if [[ -z "$DRYRUN" ]]; then cp; else echo "[dryrun] Would copy pre-commit-config.example.yaml -> $TARGET_REPO/.pre-commit-config.yaml"; fi
   - CI yml copy: if [[ -z "$DRYRUN" ]]; then mkdir+cp; else echo "[dryrun] Would copy ci.example.yml -> $TARGET_REPO/.github/workflows/ci.yml"; fi
   - pre-commit install: if [[ -z "$DRYRUN" ]]; then pre-commit install; else echo "[dryrun] Would run: pre-commit install && pre-commit install --hook-type pre-push"; fi

3. Print/show blocks (env guidance, next steps, optional deps, prereq warnings) remain unconditional.
4. Exit codes unchanged: 0=success, 1=fatal prereq, 2=warnings.

## Acceptance Criteria

- [ ] bash tests/scripts/test-dso-setup.sh passes with FAILED: 0
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | tail -1 | grep -q 'FAILED: 0'
- [ ] --dryrun creates no files in target repo
  Verify: bash -c 'T=$(mktemp -d) && git -C $T init -q && bash /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh $T /Users/joeoakhart/digital-service-orchestra --dryrun >/dev/null 2>&1; test ! -f $T/.claude/scripts/dso && test ! -f $T/workflow-config.conf && test ! -f $T/.pre-commit-config.yaml'
- [ ] --dryrun stdout contains [dryrun] action previews
  Verify: bash -c 'T=$(mktemp -d) && git -C $T init -q && bash /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh $T /Users/joeoakhart/digital-service-orchestra --dryrun 2>/dev/null | grep -q "\[dryrun\]"'
- [ ] --dryrun works after positional args (position-independent)
  Verify: bash -c 'T=$(mktemp -d) && git -C  init -q && bash /Users/joeoakhart/digital-service-orchestra/scripts/dso-setup.sh $T /Users/joeoakhart/digital-service-orchestra --dryrun 2>/dev/null; test ! -f $T/.claude/scripts/dso'
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py

