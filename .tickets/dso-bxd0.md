---
id: dso-bxd0
status: in_progress
deps: []
links: []
created: 2026-03-18T04:36:55Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-igoj
---
# Audit current DSO setup path on macOS post-plugin-transition

As a DSO maintainer, I want a clear audit of what is stale or missing in the current setup path so that Stories B–E are grounded in reality rather than assumptions.

## Done Definition

- Written audit report (can be a markdown note or ticket note) listing:
  - All stale content in `docs/INSTALL.md` post-plugin-transition
  - All gaps in `scripts/dso-setup.sh` (missing prerequisite checks, missing hook installation, missing example config copying, etc.)
  - Any prerequisites or steps that exist in docs but not in the script, or vice versa
- Report is committed or attached to this ticket as a note before closing

## Acceptance Criteria

- [ ] Audit report exists as a ticket note on dso-bxd0 listing stale `docs/INSTALL.md` content post-plugin-transition
  Verify: test -f /Users/joeoakhart/digital-service-orchestra/.tickets/dso-bxd0.md && grep -q "AUDIT" /Users/joeoakhart/digital-service-orchestra/.tickets/dso-bxd0.md
- [ ] Audit report lists all gaps in `scripts/dso-setup.sh` (missing prerequisite checks, hook installation, example config copying)
  Verify: grep -q "gap\|missing\|stale" /Users/joeoakhart/digital-service-orchestra/.tickets/dso-bxd0.md

## Escalation Policy

**If at any point you lack high confidence in your understanding of the existing project setup — e.g., you cannot determine whether a config pattern is intentional, whether a script step is still needed, or what the expected post-plugin-transition behavior should be — stop and ask the user before proceeding. Err on the side of guidance over assumption. This is a setup audit; mischaracterizing the current state will propagate errors into all downstream stories.**


## Notes

**2026-03-18T07:14:46Z**

AUDIT REPORT — DSO Setup Path (macOS, post-plugin-transition)

## INSTALL.md Stale Content

1. **`/dso:init` referenced as the verification step ("Verify Installation" section)** — The epic's goal is a new `/dso:project-setup` skill as the primary entry point. The existing `skills/init/SKILL.md` is a legacy skill that writes `workflow-config.yaml` (YAML format), not the flat KEY=VALUE `workflow-config.conf` that the current codebase uses everywhere. Referencing `/dso:init` for verification is stale on two levels: (a) the canonical config format is now `.conf`, not `.yaml`, and (b) the intended post-epic entry point is `/dso:project-setup`, which does not yet exist.

2. **`skills/init/SKILL.md` writes `workflow-config.yaml`** — The init skill itself is stale. It proposes writing a YAML file with a `version: 1` / `commands:` structure, but the live system uses `workflow-config.conf` (flat KEY=VALUE). The INSTALL.md "Optional: workflow-config.conf" section correctly describes the current format. The init skill and the INSTALL.md verify step are mismatched with each other and with the current system.

3. **"Verify Installation" expected output is aspirational** — INSTALL.md says `/dso:init` will print "a summary table of detected commands and a confirmation that hooks are registered." The actual `skills/init/SKILL.md` does not perform a hook registration check; it only detects the stack and writes config. The "hooks are registered" output described in INSTALL.md does not reflect current behavior.

4. **validate-work configuration section belongs in a config reference, not an install guide** — The "validate-work Configuration" section (lines 129-230) is detailed reference documentation for staging keys and the `.sh` vs `.md` dispatch mechanism. This content is misplaced in an installation guide. Post-epic, it should move to the `workflow-config.conf` key reference doc (Story D scope).

5. **workflow-config.conf copy command uses a literal placeholder path** — The instruction `cp /path/to/digital-service-orchestra/docs/workflow-config.example.conf workflow-config.conf` requires users to know the actual plugin installation directory. Post-plugin-transition, the correct path is resolved via `CLAUDE_PLUGIN_ROOT` or the dso shim. The command should use `$CLAUDE_PLUGIN_ROOT/docs/workflow-config.example.conf`.

6. **Git Hooks section omits `pre-commit install`** — The section tells users to copy `examples/pre-commit-config.example.yaml` and `examples/ci.example.yml` but says nothing about running `pre-commit install` (or `pre-commit install --hook-type pre-push`) to actually activate the hooks. Copying the config file without installing does not register the hooks.

7. **Option A install command (`claude plugin install`) is unverified** — `claude plugin install github:navapbc/digital-service-orchestra` — this command fails with "Plugin not found in any configured marketplace" when tested. Option A as documented is either aspirational or requires marketplace registration that has not happened. It should be marked as aspirational/pending or removed.

8. **`scripts/dso-setup.sh` is entirely absent from INSTALL.md** — The script is the mechanical engine for setup per the epic scope, but INSTALL.md does not reference it. The Path Resolution section describes manual `CLAUDE_PLUGIN_ROOT` configuration in `settings.json`, but the actual setup mechanism (shim install + `dso.plugin_root` in `workflow-config.conf`) is invisible in the docs.

9. **`dso.plugin_root` config key not mentioned** — INSTALL.md describes only the `env.CLAUDE_PLUGIN_ROOT` approach in `settings.json` for path resolution. The `dso.plugin_root` key in `workflow-config.conf` (which is what `dso-setup.sh` actually writes) is never mentioned.

---

## dso-setup.sh Gaps

The current script does exactly two things:
1. Copies `templates/host-project/dso` shim to `TARGET_REPO/.claude/scripts/dso`
2. Writes or updates `dso.plugin_root=<PLUGIN_ROOT>` in `workflow-config.conf`

### Missing: Prerequisite Checks
- No check for Claude Code CLI presence or version
- No check for bash >= 4.0 (critical on macOS where /bin/bash is 3.2)
- No check for GNU coreutils (`gtimeout`/`gstat`) — required by workflow scripts; macOS ships BSD coreutils only
- No check for `pre-commit` tool being installed
- No check for Python 3 (used by hooks for JSON parsing)
- No check for `git` (assumed present, no explicit guard)

### Missing: Pre-commit Hook Installation
- Does not run `pre-commit install` to activate commit hooks
- Does not run `pre-commit install --hook-type pre-push` to activate push hooks
- The pre-commit-config.example.yaml in examples/ includes both pre-commit and pre-push stage hooks, so both install calls are required

### Missing: Example Config Copying
- Does not copy `examples/pre-commit-config.example.yaml` to `.pre-commit-config.yaml` (with guard: skip if target exists)
- Does not copy `examples/ci.example.yml` to `.github/workflows/ci.yml` (with guard: skip if target exists)
- Does not scaffold `workflow-config.conf` from `docs/workflow-config.example.conf` — only appends one key (`dso.plugin_root`)
- Does not copy any of the templates: `templates/CLAUDE.md.template`, `templates/KNOWN-ISSUES.example.md`, `templates/DOCUMENTATION-GUIDE.example.md`

### Missing: Optional Dependency Detection and Prompts
- No detection or install guidance for `acli` (optional, used by some skills)
- No detection or install guidance for PyYAML (optional, used by legacy YAML config path)
- Epic scope requires: detect both, offer install instructions, never block setup if absent

### Missing: Environment Variable Guidance
- No output about `CLAUDE_PLUGIN_ROOT`, `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`, `ARTIFACTS_DIR`, or other env vars used by hooks and skills
- No guidance on where to set these (shell profile, `.env`, Claude Code settings.json)

### Missing: Cross-platform Handling
- No detection of macOS vs Linux vs WSL
- No guidance on platform-specific prerequisites (e.g., `brew install coreutils` on macOS)
- `sed -i.bak` usage is BSD/GNU compatible — this one line is fine

### Missing: Success Output
- Script exits silently with no user-facing confirmation of what was installed
- No "next steps" message pointing to `/dso:project-setup` or to editing `workflow-config.conf`

### Note on Idempotency
- The `dso.plugin_root` update uses a grep+sed guard — idempotent, correct
- The shim copy is a silent overwrite — acceptable behavior for a setup script but should be documented

---

## Docs vs Script Mismatches

### Steps in INSTALL.md not in dso-setup.sh

| INSTALL.md instruction | Script status |
|---|---|
| Prerequisite checks (bash, coreutils, python3) | ABSENT |
| Copy examples/pre-commit-config.example.yaml | ABSENT |
| Copy examples/ci.example.yml | ABSENT |
| Run `pre-commit install` (implied by Git Hooks section) | ABSENT |
| Copy workflow-config.example.conf | ABSENT (only appends one key) |
| Set CLAUDE_PLUGIN_ROOT in settings.json | ABSENT (script uses dso.plugin_root instead) |
| Run /dso:init to verify | ABSENT (and /dso:init is stale anyway) |

### Steps in dso-setup.sh not in INSTALL.md

| Script action | INSTALL.md status |
|---|---|
| `git init` if TARGET_REPO is not a git repo | NOT MENTIONED |
| Write dso.plugin_root to workflow-config.conf | NOT MENTIONED (docs only describe CLAUDE_PLUGIN_ROOT env var) |
| Install dso shim to .claude/scripts/dso | NOT MENTIONED |

---

## Recommendations for Stories B–E

**Story B (Expand dso-setup.sh):**
- Add prerequisite checks: bash version, Claude Code, GNU coreutils, pre-commit, Python 3
- Add `pre-commit install` + `pre-commit install --hook-type pre-push`
- Add example config copying with existence guards (.pre-commit-config.yaml, ci.yml, workflow-config.conf scaffolding)
- Add optional dep detection (acli, PyYAML) with non-blocking prompts and install instructions
- Add env var guidance output block at script completion
- Add macOS vs Linux detection for platform-specific prerequisite guidance
- Add WSL/Ubuntu detection
- Add success summary with next-steps output

**Story C (Create /dso:project-setup skill):**
- Must replace /dso:init as the verification/setup entry point described in INSTALL.md
- Must call dso-setup.sh first (mechanical steps), then provide interactive wizard
- skills/project-setup/ directory does not yet exist — needs to be created from scratch
- Must be invokable before any project config exists (requires only CLAUDE_PLUGIN_ROOT)

**Story D (Document workflow-config.conf + env vars):**
- Move the validate-work staging config section from INSTALL.md into the new config key reference
- Document all env vars used by hooks and skills (CLAUDE_PLUGIN_ROOT, JIRA_*, ARTIFACTS_DIR, etc.)

**Story E (Rewrite INSTALL.md):**
- Replace the Option A/B install + manual path resolution section with a two-step flow: install plugin → run dso-setup.sh → invoke /dso:project-setup
- Remove stale /dso:init verification step; replace with /dso:project-setup
- Add dso-setup.sh to the documented installation flow
- Move validate-work staging config reference to Story D doc and link from INSTALL.md
- Fix workflow-config.conf copy command to use $CLAUDE_PLUGIN_ROOT
- Add explicit `pre-commit install` step
- Document dso.plugin_root config key (currently undocumented)
- Mark or remove Option A (claude plugin install) until it is supported in production
