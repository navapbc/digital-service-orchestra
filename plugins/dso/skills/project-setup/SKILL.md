---
name: project-setup
description: Install and configure Digital Service Orchestra in a host project via an interactive wizard
user-invocable: true
---

# Project Setup — Install and Configure DSO

This skill is the primary entry point for onboarding a new project to Digital Service Orchestra. It replaces `/dso:init` with a richer, guided experience: it runs `dso-setup.sh` to install the DSO shim, detects the project stack, walks through an interactive configuration wizard that generates `dso-config.conf`, and offers to copy starter templates.

---

## Step 1: Run dso-setup.sh

Determine the target repository and detect --dryrun mode:

```bash
# If already in the target repo or a git repo exists:
TARGET_REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Detect --dryrun flag from skill arguments
DRYRUN=false
if echo "$SKILL_ARGS" | grep -q -- '--dryrun'; then
  DRYRUN=true
fi
```

Then run the setup script (passing `--dryrun` when in dryrun mode):

```bash
# In dryrun mode, capture preview output; in normal mode, run as usual
if [ "$DRYRUN" = "true" ]; then
  SETUP_PREVIEW=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/dso-setup.sh" "$TARGET_REPO" --dryrun 2>&1)
  SETUP_EXIT=$?
else
  bash "$CLAUDE_PLUGIN_ROOT/scripts/dso-setup.sh" "$TARGET_REPO"
  SETUP_EXIT=$?
fi
```

Handle exit codes as follows:

| Exit code | Meaning | Action |
|-----------|---------|--------|
| 0 | Success | Proceed to Step 2 |
| 1 | Fatal error (missing required prerequisite) | Print the error output from `dso-setup.sh`. **Stop here — do NOT proceed to the wizard.** Tell the user to fix the prerequisite and re-run `/dso:project-setup`. |
| 2 | Warnings only (non-fatal prerequisites missing) | Print the warnings from `dso-setup.sh`. Ask the user: "One or more optional prerequisites are missing (see above). Continue with setup? (yes/no)". If yes, proceed to Step 2. If no, stop. |

> **Exit 1 (fatal)**: Print the error, stop immediately, do NOT proceed to the wizard.
> **Dryrun note**: In dryrun mode, `SETUP_PREVIEW` holds what `dso-setup.sh --dryrun` would do. Exit codes are handled identically — exit 1 still stops the skill.

---

## Step 2: Detect Stack

Run the stack detector on the target repository:

```bash
STACK=$(bash ".claude/scripts/dso detect-stack.sh" "$TARGET_REPO")
```

Show the user the result:

```
Detected stack: <STACK>
```

If `STACK=unknown`, note it — the wizard will ask for manual command input in Step 3.

---

## Step 3: Interactive Configuration Wizard

> **Authoritative key source**: Read `docs/CONFIGURATION-REFERENCE.md` for the complete list of `dso-config.conf` keys, their descriptions, accepted values, and defaults. Do NOT hardcode key descriptions inline — always reference that document.

Ask one question at a time using `AskUserQuestion`. Do not present multiple prompts simultaneously. Work through each section sequentially, recording each confirmed value for writing in Step 4.

### Commands section (`commands.*`)

For each command key, propose a suggestion and label it as either:
- **"(exists in project)"** — the detection script verified this make target or script exists in `$TARGET_REPO`
- **"(convention for `<STACK>`)"** — this is the standard command for the detected stack but has not been verified as present

Ask each command question separately, one at a time:

**1. Test command** — Use `AskUserQuestion`:
```
What is your test command?
Suggestion: <stack-derived default> (exists in project | convention for <STACK>)
Press Enter to accept, or type a custom value:
```
Record as `commands.test`.

**2. Unit test command** — Use `AskUserQuestion`:
```
What is your unit test command (subset of full test suite, or leave blank)?
Suggestion: <stack-derived default if any> (exists in project | convention for <STACK>)
Press Enter to accept, or leave blank to skip:
```
Record as `commands.test_unit` (omit if blank).

**3. Lint command** — Use `AskUserQuestion`:
```
What is your lint command?
Suggestion: <stack-derived default> (exists in project | convention for <STACK>)
Press Enter to accept, or type a custom value:
```
Record as `commands.lint`.

**4. Format command** — Use `AskUserQuestion`:
```
What is your format command (or leave blank)?
Suggestion: <stack-derived default if any> (exists in project | convention for <STACK>)
Press Enter to accept, or leave blank to skip:
```
Record as `commands.format` (omit if blank).

**5. Format check command** — Use `AskUserQuestion`:
```
What is your format check command (read-only lint for CI, or leave blank)?
Suggestion: <stack-derived default if any> (exists in project | convention for <STACK>)
Press Enter to accept, or leave blank to skip:
```
Record as `commands.format_check` (omit if blank).

**6. Validate command** — Use `AskUserQuestion`:
```
What is your full validation command (runs all checks, or leave blank)?
Suggestion: ./plugins/dso/scripts/validate.sh --ci (exists in project | convention for <STACK>)
Press Enter to accept, or leave blank to skip:
```
Record as `commands.validate` (omit if blank).

If `STACK=unknown`, note that no stack was detected and ask the user to provide values manually for each prompt above (do not pre-fill suggestions).

### Format section (`format.*`)

Ask each format question separately, one at a time:

**7. File extensions** — Use `AskUserQuestion`:
```
Which file extensions should the formatter cover?
This controls which files are checked/formatted (e.g. py,js,ts for Python + JavaScript projects).
Suggestion: <stack-derived extensions, e.g. "py" for Python>
Press Enter to accept, or type a comma-separated list:
```
Record as `format.extensions`.

**8. Source directories** — Use `AskUserQuestion`:
```
Which source directories should be covered by formatting?
These are the directories scanned when running the format and lint commands (e.g. src,tests).
Suggestion: <stack-derived dirs, e.g. "app/src,app/tests" for Python>
Press Enter to accept, or type a comma-separated list:
```
Record as `format.source_dirs`.

### Version tracking (`version.*`)

**9. Version file path** — Use `AskUserQuestion`:
```
Does your project track a version string in a file (e.g. pyproject.toml, package.json)?
If yes, enter the path relative to the project root (e.g. pyproject.toml). Leave blank to skip.
```
Record as `version.file_path` (omit if blank).

### Ticket settings (`tickets.*`)

**10. Ticket prefix** — Use `AskUserQuestion`:
```
What prefix should local tickets use (e.g. "myproject" produces IDs like myproject-abc1)?
Leave blank to use the default ("dso").
```
Record as `tickets.prefix` (omit if blank / uses default).

### Jira integration

**11. Jira tracking** — Use `AskUserQuestion`: "Do you use Jira for issue tracking? (yes/no)"

If yes:
- Explain that `JIRA_URL`, `JIRA_USER`, and `JIRA_API_TOKEN` are **environment variables** that belong in the user's shell profile (e.g., `~/.zshrc` or `~/.bashrc`) — they are **not** written to `dso-config.conf`.
- Use `AskUserQuestion` to ask for the `jira.project` key value (Jira project key, e.g., `DIG`). Record this for `dso-config.conf`.
- Show the user the env vars they need to add to their shell profile:
  ```
  export JIRA_URL=https://your-org.atlassian.net
  export JIRA_USER=you@example.com
  export JIRA_API_TOKEN=<your-api-token>
  ```
  Direct them to https://id.atlassian.com/manage-profile/security/api-tokens to generate a token.

If no: skip the Jira sub-section.

### CI configuration (`ci.*`)

Auto-detect CI workflows from the project-detect.sh output collected in Step 2. The `ci_workflow_names` field lists all workflow names found under `.github/workflows/`. Use these detected values to pre-populate prompts.

**Check for deprecated key first**: Before prompting, scan the existing `dso-config.conf` (if present) for a `merge.ci_workflow_name` entry. If found, show a deprecation notice:

```
Note: merge.ci_workflow_name is deprecated — the preferred key is ci.workflow_name.
Detected existing value: <value>
This wizard will migrate it to ci.workflow_name. The old key can be removed from dso-config.conf after confirmation.
```

Then proceed with the prompts below, pre-filling the migrated value as the suggestion for `ci.workflow_name`.

**CI workflow detection**: If `ci_workflow_names` is non-empty (from project-detect.sh output), show the detected names as context. If `.github/workflows/` exists but no workflow names were parsed, note "CI workflows found but names could not be parsed — enter manually."

Ask each CI question separately, one at a time, only when the project has a `.github/` directory or CI workflows were detected. If no CI is detected, present the section as optional and allow the user to skip all prompts by pressing Enter.

**12. CI workflow name** — Use `AskUserQuestion`:
```
What is the GitHub Actions workflow name used for CI trigger recovery?
This must match the "name:" field in your .github/workflows/ file exactly.
Auto-detected: <first value from ci_workflow_names, or "not detected">
Press Enter to accept, type a custom value, or leave blank to skip:
```
Record as `ci.workflow_name` (omit if blank).

**13. Fast gate job name** — Use `AskUserQuestion`:
```
What is the name of your fast-gate CI job (checked first on any failure for early exit)?
This must match the "name:" field in your CI workflow file exactly.
Suggestion: Fast Gate (default)
Press Enter to accept, type a custom value, or leave blank to skip:
```
Record as `ci.fast_gate_job` (omit if blank; default `Fast Gate` is used automatically when absent).

**14. Fast fail job name** — Use `AskUserQuestion`:
```
What is the name of the CI job whose timeout defines the end of the fast-fail polling phase?
This must match the "name:" field in your CI workflow file exactly.
Suggestion: same as ci.fast_gate_job (default)
Press Enter to accept, type a custom value, or leave blank to skip:
```
Record as `ci.fast_fail_job` (omit if blank).

**15. Test ceiling job name** — Use `AskUserQuestion`:
```
What is the name of the CI job whose timeout defines the end of the test polling phase?
This must match the "name:" field in your CI workflow file exactly.
Suggestion: Unit Tests (default)
Press Enter to accept, type a custom value, or leave blank to skip:
```
Record as `ci.test_ceil_job` (omit if blank; default `Unit Tests` is used automatically when absent).

**16. Integration workflow name** — Use `AskUserQuestion`:
```
Do you have a separate GitHub Actions workflow for integration tests?
If yes, enter the workflow name (must match "name:" in your .github/workflows/ file exactly).
Auto-detected: <value from ci_workflow_names matching "integration" case-insensitive, or "not detected">
Press Enter to accept, type a custom value, or leave blank to skip:
```
Record as `ci.integration_workflow` (omit if blank).

> **Authoritative key descriptions**: See `docs/CONFIGURATION-REFERENCE.md` for full descriptions of `ci.workflow_name`, `ci.fast_gate_job`, `ci.fast_fail_job`, `ci.test_ceil_job`, and `ci.integration_workflow`.

### dso.* section

The `dso.plugin_root` key is written automatically by `dso-setup.sh` — do NOT prompt for it or duplicate it.

### Monitoring

Use `AskUserQuestion`: "Enable tool error monitoring and auto-ticket creation? (y/N, default: N):"

- If **yes**: write `monitoring.tool_errors=true` to `dso-config.conf`. This enables automatic tracking of tool errors and creates tickets for them.
- If **no** (or default): omit the `monitoring.tool_errors` key entirely from `dso-config.conf`. The feature is disabled when the key is absent. This is a safe-off default — opt-in only.

### Database configuration

Check the detection output from Step 2 for the `db_detected` (or `docker_db_detected`) field. If `db_detected=true`, prompt for the following database keys. If `db_detected=false` (or the field is absent or unknown), skip this entire sub-section with a note: `(skipping — no database service detected)`.

**If `db_detected=true` (database service detected):**

Use `AskUserQuestion` for each of the following keys, one at a time:

**database.ensure_cmd** — Use `AskUserQuestion`:
```
What command creates or migrates your database?
See docs/CONFIGURATION-REFERENCE.md for the description of database.ensure_cmd.
Suggestion: make db-migrate (convention for <STACK>)
Press Enter to accept, or type a custom value:
```
Record as `database.ensure_cmd`.

**database.status_cmd** — Use `AskUserQuestion`:
```
What command checks database connectivity?
See docs/CONFIGURATION-REFERENCE.md for the description of database.status_cmd.
Suggestion: make db-status (convention for <STACK>)
Press Enter to accept, or type a custom value:
```
Record as `database.status_cmd`.

**infrastructure.db_container** — Use `AskUserQuestion`:
```
What is the docker-compose service name for your database container (e.g., "db" or "postgres")?
See docs/CONFIGURATION-REFERENCE.md for the description of infrastructure.db_container.
Suggestion: db (convention for <STACK>)
Press Enter to accept, or type a custom value:
```
Record as `infrastructure.db_container`.

**If `db_detected=false` (or field absent/unknown):**

Skip all three prompts above. Note: `(skipping — no database service detected)`. Do NOT prompt for `database.ensure_cmd`, `database.status_cmd`, or `infrastructure.db_container` when no database is detected.

### Infrastructure keys

Check the detection output from Step 2 for Docker/container indicators (e.g., `docker_present=true`, a `docker-compose.yml` file detected, or container-based stack). Only prompt for infrastructure keys when relevant project indicators are detected. If no container/Docker infrastructure is detected, skip this section with a note: `(skipping — no container infrastructure detected)`.

**If container infrastructure is detected:**

**infrastructure.required_tools** — Use `AskUserQuestion`:
```
Which CLI tools should DSO check for at session start (comma-separated, e.g. docker,make,git)?
infrastructure.required_tools controls which tools are verified present at the beginning of each
Claude session — missing tools produce warnings or errors that surface before any work begins.
Suggestion: <stack-derived tools, e.g. "docker,make" for Docker-based projects>
Press Enter to accept, or type a comma-separated list (leave blank to skip):
```
Record as `infrastructure.required_tools` (omit if blank).

**infrastructure.app_port** — Use `AskUserQuestion`:

Before prompting, attempt port inference from the project's `docker-compose.yml` or `.env` file:
- Scan `docker-compose.yml` for `ports:` mappings on the application service (e.g., `"8000:8000"` → port `8000`).
- If the port mapping uses variable substitution (e.g., `${APP_PORT:-8000}`), extract the default value after `:-`.
- Fall back to scanning `.env` for `APP_PORT=` or similar variables.

```
What port does your application expose (used for local development access)?
Inferred from docker-compose port mapping: <inferred value, or "not detected">
Press Enter to accept, or type a port number (leave blank to skip):
```
Record as `infrastructure.app_port` (omit if blank).

**infrastructure.db_port** — Use `AskUserQuestion` (only when `db_detected=true`):

Before prompting, attempt port inference from `docker-compose.yml` or `.env`:
- Scan `docker-compose.yml` for `ports:` mappings on the database service (e.g., `"5432:5432"` → port `5432`).
- If the port mapping uses variable substitution (e.g., `${DB_PORT:-5432}`), extract the default value after `:-`.
- Fall back to scanning `.env` for `DB_PORT=` or similar variables.

```
What port does your database expose (used for local connections)?
Inferred from docker-compose port mapping: <inferred value, or "not detected">
Press Enter to accept, or type a port number (leave blank to skip):
```
Record as `infrastructure.db_port` (omit if blank).

**If no container infrastructure detected:**

Skip all infrastructure key prompts above. Note: `(skipping — no container infrastructure detected)`.

### Optional dependencies

Prompt for each optional dependency individually. Use the detection output from Step 2 to determine which dependencies are already installed. **Skip the prompt entirely for any dependency already detected as installed** — do not offer to install something the user already has.

For each dependency below, if not already installed, use `AskUserQuestion` to ask the user — one at a time, in the order listed. Do not bundle them into a single question.

**acli (Jira CLI)**

> Skip this prompt if: (a) acli is already installed (detected via `which acli 2>/dev/null`), OR (b) the user declined Jira integration earlier in this wizard (Step 3, Jira section answered "no"). If Jira is not configured, acli has no function — skip the acli prompt.

If acli is not installed and Jira integration was enabled, use `AskUserQuestion` to ask about acli:

```
Would you like to install acli (the Atlassian CLI)?
acli enables Jira integration within Claude Code — without acli functionality such as ticket
sync and issue browsing from the terminal will not be available.
Install with: brew install acli
Install acli now? (yes/no)
```

If yes: display the install command `brew install acli` and instruct the user to run it. Do not run it automatically.
If no: note that Jira CLI integration will be unavailable and continue.

**PyYAML**

> Skip this prompt if PyYAML is already installed (detected via `python3 -c "import yaml" 2>/dev/null`).

If PyYAML is not installed, use `AskUserQuestion` to ask about PyYAML:

```
Would you like to install PyYAML?
PyYAML provides legacy YAML config format support — without PyYAML functionality for reading
workflow-config.yml (YAML format) instead of dso-config.conf will not be available.
Install with: pip3 install pyyaml
Install PyYAML now? (yes/no)
```

If yes: display the install command `pip3 install pyyaml` and instruct the user to run it. Do not run it automatically.
If no: note that legacy YAML config support will be unavailable and continue.

**pre-commit**

> Skip this prompt if pre-commit is already installed (detected via `which pre-commit 2>/dev/null`).

If pre-commit is not installed, use `AskUserQuestion` to ask about pre-commit:

```
Would you like to install pre-commit?
pre-commit enables git hook management — without pre-commit functionality for automated lint
and format checks on commit (enforced by DSO's review gate) will not be available.
Install with: pip3 install pre-commit
Install pre-commit now? (yes/no)
```

If yes: display the install command `pip3 install pre-commit` and instruct the user to run it. Do not run it automatically.
If no: note that git hook management will be unavailable and continue.

### Staging configuration

Check the detection output from Step 2 for `DETECT_STAGING_CONFIG_PRESENT`. If `DETECT_STAGING_CONFIG_PRESENT=true` (i.e., a staging config file, `heroku.yml`, or `STAGING_URL` environment variable was detected), prompt for the staging URL. If staging config is not detected, skip this section.

**If `DETECT_STAGING_CONFIG_PRESENT=true` (staging config detected):**

**staging.url** — Use `AskUserQuestion`:
```
Staging URL (e.g., https://your-app.herokuapp.com):
```

If `DETECT_STAGING_URL` from the detection output is non-empty, pre-fill it as the default:
```
Staging URL (e.g., https://your-app.herokuapp.com):
Auto-detected: <DETECT_STAGING_URL>
Press Enter to accept, or type a custom value:
```

Record as `staging.url`.

**If `DETECT_STAGING_CONFIG_PRESENT=false` (or field absent/unknown):**

Skip the staging URL prompt. Note: `(skipping — no staging configuration detected)`. Do NOT prompt for `staging.url` when no staging config is detected.

### Python version

Always prompt for `worktree.python_version` — this is not conditional on detection, but pre-fill from detection output when available.

Pre-fill logic (in priority order):
1. `DETECT_PYTHON_VERSION` from `project-detect.sh` (sourced from `pyproject.toml`, `.python-version`, or `python3 --version`)
2. If not detected, leave blank for manual entry

**worktree.python_version** — Use `AskUserQuestion`:

If `DETECT_PYTHON_VERSION` is non-empty:
```
Python version (auto-detected: <DETECT_PYTHON_VERSION>). Confirm or enter value:
```

If `DETECT_PYTHON_VERSION` is empty or not detected:
```
Python version (e.g., 3.13.0):
```

Record as `worktree.python_version`. This value is used for `worktree.python_version` in `dso-config.conf` and controls which Python binary is used in worktree sessions.

---

## Step 4: Write dso-config.conf

**In normal mode**: Write the confirmed key=value pairs to `$TARGET_REPO/dso-config.conf`.

**In dryrun mode**: Do NOT write the file. Instead, display a flat list of planned outcomes — what will happen to the user's project files. Do NOT distinguish between which internal component (script vs skill) performs each action; users care about results, not implementation details.

Collect all planned actions across Steps 1–3 and present them as a unified flat list:

```
=== Dryrun Preview ===

The following changes will be made to <TARGET_REPO>:

  - will install the DSO shim at .claude/scripts/dso
  - will write dso-config.conf with <N> keys (commands.test, commands.lint, ...)
  - will merge DSO hook configuration into .pre-commit-config.yaml
  - will supplement CLAUDE.md with DSO sections  (if CLAUDE.md exists)
  - will copy CLAUDE.md.template → CLAUDE.md  (if no CLAUDE.md exists and confirmed)
  - will copy KNOWN-ISSUES.example.md → .claude/docs/KNOWN-ISSUES.md  (if confirmed)
```

Each bullet describes an outcome in user-facing terms ("will write X", "will merge Y into Z", "will supplement A with B"). Omit any line whose action would be skipped (e.g. if the user declined template copy, omit that bullet).

Ask: "Proceed with setup? (yes/no)"
- If **yes**: re-run Steps 1–4 without `--dryrun` (set `DRYRUN=false`), reusing all answers collected during the wizard — do NOT re-prompt the user for values already confirmed.
- If **no**: stop gracefully with the message "Setup cancelled. No changes were made."

Rules (normal mode):
- Format: `KEY=VALUE` (flat, one per line, dot-notation keys).
- If the file already exists: **add or update** only the keys the user confirmed in Step 3. Do not remove or overwrite other existing keys.
- The `dso.plugin_root` key is already written by `dso-setup.sh` in Step 1 — do NOT duplicate it.
- Always include `version=1.0.0` if the file is being created fresh (and `version` is not already present).

---

## Step 5: Smart File Handling — Templates, Hooks, and CI Guards

`dso-setup.sh` handles existing project files intelligently rather than blindly overwriting them. Each file type has distinct behavior depending on whether the file already exists. This step documents what `dso-setup.sh` does automatically and what to report to the user.

### CLAUDE.md and KNOWN-ISSUES.md — Supplement, Don't Overwrite

`dso-setup.sh` calls `supplement_template_file` for both `CLAUDE.md` and `KNOWN-ISSUES.md`. The function behavior:

- **File absent**: copies the template directly (`CLAUDE.md.template` or `KNOWN-ISSUES.example.md`).
- **File exists, no DSO marker**: appends DSO scaffolding sections to the end of the existing file (supplement). Does **not** overwrite or destroy existing content.
- **File exists, DSO marker present**: skips silently — DSO sections are already there.

DSO markers that signal existing DSO content:
- `CLAUDE.md`: the string `=== GENERATED BY /generate-claude-md`
- `KNOWN-ISSUES.md`: the HTML comment `<!-- DSO:KNOWN-ISSUES-HEADER -->`

Output messages from `supplement_template_file` (visible in setup output):

| Situation | Message |
|-----------|---------|
| File absent | `[dryrun] Would copy <template> -> <dest> (file absent)` |
| File exists, no DSO marker | `[supplement] Appending DSO scaffolding sections to existing <label>` |
| File exists, DSO marker present | `[skip] <label> already contains DSO scaffolding — not supplementing` |

**In dryrun mode**: no files are written; dryrun equivalents of the above messages are printed.

### .pre-commit-config.yaml — Merge DSO Hooks

`dso-setup.sh` calls `merge_precommit_hooks` for `.pre-commit-config.yaml`:

- **File absent**: copies `examples/pre-commit-config.example.yaml` directly.
- **File exists**: merges only the DSO hooks that are not already present into the existing file. Existing hooks and repos are preserved. If the file has no `repos:` section, it is left untouched with a warning.
- **All DSO hooks already present**: skips merge — no changes made.

Output messages from `merge_precommit_hooks`:

| Situation | Message |
|-----------|---------|
| File absent | `[dryrun] Would copy pre-commit-config.example.yaml -> <dest> (file absent)` |
| Merge needed | `[merge] Appended DSO hooks to .pre-commit-config.yaml: <hook-list>` |
| All hooks present | `[skip] .pre-commit-config.yaml: all DSO hooks already present — not merging` |
| No `repos:` section | `WARNING: .pre-commit-config.yaml exists but has no 'repos:' section — skipping merge` |

### CI Workflow — Guard Analysis, Not Copy

`dso-setup.sh` handles CI workflows differently from the other file types:

- **No `.github/workflows/*.yml` found**: copies `examples/ci.example.yml` to `.github/workflows/ci.yml` (only if no workflow file exists).
- **Workflow file(s) exist**: does **not** copy or modify any workflow file. Instead, runs `_run_ci_guard_analysis` to report missing CI guards.

#### DETECT_ env var contract for CI guard analysis

`_run_ci_guard_analysis` reads guard status from the file path stored in the `DSO_DETECT_OUTPUT` environment variable. This file is the detection output written by `project-detect.sh` (a key=value file). If `DSO_DETECT_OUTPUT` is unset or the file is missing, guard analysis is skipped.

Guard keys read from the detection output file:

| Key | Values | Meaning |
|-----|--------|---------|
| `ci_workflow_lint_guarded` | `true` / `false` | Whether the existing CI workflow has a lint step |
| `ci_workflow_test_guarded` | `true` / `false` | Whether the existing CI workflow has a test step |
| `ci_workflow_format_guarded` | `true` / `false` | Whether the existing CI workflow has a format step |

When a guard key is `false`, the analysis emits a recommendation:

```
[ci-guard] Existing CI workflow is missing lint guard — consider adding a lint step to your workflow
[ci-guard] Existing CI workflow is missing test guard — consider adding a test step to your workflow
[ci-guard] Existing CI workflow is missing format guard — consider adding a format step to your workflow
```

In dryrun mode these messages are prefixed with `[dryrun][ci-guard]`.

### Dryrun Preview

In dryrun mode, `dso-setup.sh` prints a preview of the actions it would take for each file. The skill should surface this output as part of the Step 4 dryrun preview (see Step 4). No files are written or modified in dryrun mode.

Example dryrun preview lines for Step 5 actions:

```
=== Dryrun Preview ===

The following changes will be made to <TARGET_REPO>:

  - will supplement CLAUDE.md with DSO sections  (if CLAUDE.md exists without DSO markers)
  - will copy CLAUDE.md.template → <TARGET_REPO>/.claude/CLAUDE.md  (if no CLAUDE.md exists)
  - will supplement KNOWN-ISSUES.md with DSO sections  (if KNOWN-ISSUES.md exists without DSO markers)
  - will copy KNOWN-ISSUES.example.md → <TARGET_REPO>/.claude/docs/KNOWN-ISSUES.md  (if absent)
  - will merge DSO hooks into .pre-commit-config.yaml  (if .pre-commit-config.yaml exists)
  - will copy pre-commit-config.example.yaml → <TARGET_REPO>/.pre-commit-config.yaml  (if absent)
  - will run CI guard analysis and report missing guards  (if CI workflow files exist)
  - will copy ci.example.yml → <TARGET_REPO>/.github/workflows/ci.yml  (only if no CI workflow exists)
```

Omit any line whose action would be skipped (e.g., if CLAUDE.md already has DSO markers, omit the supplement line).

Ask: "Proceed with setup? (yes/no)"
- If **yes** and this is the first dryrun pass: re-run Steps 1–5 without `--dryrun`, reusing all confirmed answers.
- If **no**: stop gracefully with the message "Setup cancelled. No changes were made."

---

## Step 6: Success Summary

Print a summary of what was configured, followed by a **manual steps** section listing everything the user still needs to do.

```
=== DSO Project Setup Complete ===

Target repo: <TARGET_REPO>
Stack: <STACK>
dso-config.conf: written

Keys configured:
  commands.test=<value>
  commands.lint=<value>
  ... (all keys written in Step 4)

Jira integration: <enabled (jira.project=<KEY>) | not configured>
```

Then print the **Next steps (manual)** section — a list of actions the setup wizard did NOT perform automatically that the user must complete themselves:

```
=== Next Steps (Manual) ===

The following were NOT configured automatically. Complete these before using DSO:
```

Always include (if applicable):

1. **Jira environment variables** (shown only if Jira was configured in Step 3, since these are never written to `dso-config.conf`):
   ```
   Add these exports to your shell profile (~/.zshrc or ~/.bashrc):
     export JIRA_URL=https://your-org.atlassian.net
     export JIRA_USER=you@example.com
     export JIRA_API_TOKEN=<your-api-token>

   Generate a token at: https://id.atlassian.com/manage-profile/security/api-tokens
   Then reload your shell: source ~/.zshrc (or ~/.bashrc)
   ```

2. **Register the ticket index merge driver** (always required after fresh clone):
   ```
   Run: git config merge.tickets-index-merge.driver \
     "python3 plugins/dso/scripts/merge-ticket-index.py %O %A %B"
   ```

3. **Optional dependency installs** (if any optional tools were not found during setup):
   List each missing optional tool with its install command (e.g., `brew install acli`, `pip3 install pyyaml`). Omit this item if all optional tools are already installed.

If none of the above apply (Jira not configured, merge driver already registered, all optional tools present), print:
```
  (none — setup is complete)
```

Close with the documentation link:

```
Full documentation: plugins/dso/docs/INSTALL.md
```

---

## Step 7: Onboarding Foundations

After completing project setup, offer to run the architecture and design onboarding skills. These skills produce foundational documents that guide future Claude sessions in the target project.

- `/dso:dev-onboarding` — produces `ARCH_ENFORCEMENT.md`: an architecture blueprint and enforcement rules for the codebase
- `/dso:design-onboarding` — produces `DESIGN_NOTES.md`: visual language conventions and component golden paths

### Artifact detection

Check for the sentinel files that indicate whether each onboarding skill has already run:

```bash
ARCH_SENTINEL="$TARGET_REPO/ARCH_ENFORCEMENT.md"
DESIGN_SENTINEL="$TARGET_REPO/DESIGN_NOTES.md"

dev_done=false
design_done=false

[ -f "$ARCH_SENTINEL" ] && dev_done=true
[ -f "$DESIGN_SENTINEL" ] && design_done=true
```

- **`ARCH_ENFORCEMENT.md`** is the sentinel for `/dso:dev-onboarding`
- **`DESIGN_NOTES.md`** is the sentinel for `/dso:design-onboarding`

### Conditional prompt

**Case 1: Both artifacts present — skip this step entirely**

If both `ARCH_ENFORCEMENT.md` and `DESIGN_NOTES.md` already exist in the target project, both onboarding skills have already run. Skip the prompt entirely and log:

```
(skipping onboarding prompt — both artifacts already present: ARCH_ENFORCEMENT.md, DESIGN_NOTES.md)
```

No further action is needed. Setup is complete.

---

**Case 2: Both artifacts missing — 4-option AskUserQuestion**

When both `ARCH_ENFORCEMENT.md` and `DESIGN_NOTES.md` are missing, use `AskUserQuestion` to offer all onboarding options:

```
Would you like to set up architecture and design foundations for this project?

1) Both (recommended) — runs dev-onboarding then design-onboarding: produces ARCH_ENFORCEMENT.md (architecture blueprint and enforcement rules) and DESIGN_NOTES.md (visual design language and golden paths)
2) Architecture only — runs /dso:dev-onboarding: produces ARCH_ENFORCEMENT.md with codebase architecture guide and enforcement rules for future Claude sessions
3) Design system only — runs /dso:design-onboarding: produces DESIGN_NOTES.md with visual language conventions and component golden paths
4) Skip for now — setup is complete with no additional steps

Enter 1, 2, 3, or 4:
```

Handle each selection:

- **Option 1 (Both)**: Invoke `/dso:dev-onboarding` first, then invoke `/dso:design-onboarding` after it completes.
- **Option 2 (Architecture only)**: Invoke `/dso:dev-onboarding`.
- **Option 3 (Design system only)**: Invoke `/dso:design-onboarding`.
- **Option 4 (Skip)**: End setup. No additional steps are run.

---

**Case 3: Only one artifact missing — yes/no AskUserQuestion**

When only one skill is still needed (if only one artifact is missing), use a yes/no prompt for the remaining skill.

**If only `ARCH_ENFORCEMENT.md` is missing** (dev-onboarding not yet run):

```
Would you like to run /dso:dev-onboarding?
dev-onboarding produces ARCH_ENFORCEMENT.md — an architecture blueprint and enforcement rules
that guide future Claude sessions through your codebase structure and conventions. (yes/no)
```

If yes: invoke `/dso:dev-onboarding`. If no: skip — no additional steps.

**If only `DESIGN_NOTES.md` is missing** (design-onboarding not yet run):

```
Would you like to run /dso:design-onboarding?
design-onboarding produces DESIGN_NOTES.md — a visual design language guide and component
golden paths that keep UI decisions consistent across Claude sessions. (yes/no)
```

If yes: invoke `/dso:design-onboarding`. If no: skip — no additional steps.

### Invocation order

When both skills are selected (option 1 in the 4-option prompt), always invoke `/dso:dev-onboarding` before `/dso:design-onboarding`. This ordering ensures the architecture context is available when the design onboarding runs.

---

## Error Handling Reference

| Situation | Response |
|-----------|----------|
| `dso-setup.sh` exits 1 (fatal) | Print error, stop — do NOT proceed to wizard |
| `dso-setup.sh` exits 2 (warnings) | Print warnings, ask user to continue |
| `detect-stack.sh` returns `unknown` | Ask user for manual command input |
| `dso-config.conf` exists | Add/update only confirmed keys; preserve existing keys |
| User declines template copy | Skip the copy; continue to next step |
| User declines to continue after exit 2 | Stop gracefully |
| User says "no" to dryrun Proceed prompt | Stop gracefully — "Setup cancelled. No changes were made." |
| User says "yes" to dryrun Proceed prompt | Re-run Steps 1–5 without `--dryrun`, reusing collected answers |
| `CLAUDE.md` or `KNOWN-ISSUES.md` already exists | Check for DSO section marker — supplement with DSO scaffolding if absent; skip if DSO markers already present |
| `.pre-commit-config.yaml` already exists | Merge only missing DSO hooks into existing file; skip if all DSO hooks already present; warn and skip if file has no `repos:` section |
| CI workflow already exists (any `.github/workflows/*.yml`) | Run guard analysis (`_run_ci_guard_analysis`) and report missing lint/test/format guards; do NOT copy `ci.example.yml` |
