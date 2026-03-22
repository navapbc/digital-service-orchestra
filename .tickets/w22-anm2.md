---
id: w22-anm2
status: in_progress
deps: [w22-528r]
links: []
created: 2026-03-21T16:50:59Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# CI workflow generation from discovered test suites


## Notes

**2026-03-21T16:51:21Z**

## Context
Even after test suites are discoverable (Milestone A / w22-528r), the setup skill still copies a static CI template with hardcoded job names or merely advises that guards are missing. A platform engineer onboarding a Django service must manually translate discovered suites into CI workflow jobs and decide which belong in the fast gate vs. a separate workflow. This milestone uses Milestone A's discovery output to generate GitHub Actions workflows automatically, with user control over suite placement.

## Success Criteria
1. For new projects with no CI, the setup skill generates .github/workflows/ci.yml (one job per fast suite, triggered on pull_request) and .github/workflows/ci-slow.yml (slow suites, triggered on push to main). Job IDs derived from suite name (e.g., name=unit -> test-unit).
2. For existing projects, the setup skill identifies uncovered suites (no step run: in any .github/workflows/*.yml contains the suite's command as a substring; reusable workflow uses: treated as uncovered) and prompts the user: fast-gate (add to gating workflow), separate (new workflow file), or skip (recorded as test.suite.<name>.ci_placement=skip). Accepting a prompt results in the suite being incorporated with no further manual steps.
3. For suites with speed_class=unknown, the setup skill prompts: 'Is [name] a fast test (<30s) or slow test? [fast/slow/skip]'. Default on Enter: slow. In non-interactive environments, uncovered fast suites default to fast-gate, slow/unknown to separate workflow, skip is unavailable.
4. Generated YAML is validated before writing: actionlint if installed, else python3 yaml.safe_load. Files written to temp path, validated, then moved to final destination on success.
5. Running /dso:project-setup on the DSO repo produces a CI workflow that passes all jobs on first push, with zero manual edits to the generated YAML (dogfooding validation).

## Approach
Detection-driven template engine (Option A from brainstorm). Consumes project-detect.sh --suites JSON output to generate GitHub Actions YAML dynamically.

## Dependencies
w22-528r (Test suite auto-discovery engine) — requires the project-detect.sh --suites JSON output contract.

**2026-03-21T16:55:38Z**

## Final Spec (approved)

## Context
Even after test suites are discoverable (w22-528r), the setup skill copies a static CI template. A platform engineer must manually translate suites into CI jobs. This milestone generates GitHub Actions workflows automatically with user control over placement.

Upstream contract: project-detect.sh --suites outputs JSON array (name, command, speed_class, runner). Platform: GitHub Actions only. Config: .claude/dso-config.conf (flat KEY=VALUE). Non-interactive detection: test -t 0.

## Success Criteria
1. New projects: generate .github/workflows/ci.yml (fast suites, on: pull_request) and ci-slow.yml (slow, on: push to main). Job template: checkout -> setup runtime -> run command. Job IDs from suite name (unit -> test-unit). Runner: ubuntu-latest. No secrets/services assumed.
2. Existing projects: uncovered = no step run: contains suite command as substring (uses: treated as uncovered). Prompt: fast-gate (append to gating workflow) / separate (new file) / skip (write test.suite.<name>.ci_placement=skip). Incorporated = written to disk and git add.
3. speed_class=unknown prompt: fast/slow/skip, default slow. Non-interactive: fast -> ci.yml, slow/unknown -> ci-slow.yml, skip unavailable.
4. YAML validation: actionlint if on PATH, else python3 yaml.safe_load. Temp dir -> validate -> move. Failure blocks write.
5. Dogfooding: /dso:project-setup on DSO repo -> actionlint exit 0 on generated files.

## Approach
Detection-driven template engine consuming project-detect.sh --suites JSON.

## Dependencies
w22-528r (Test suite auto-discovery engine) — requires --suites JSON output.
