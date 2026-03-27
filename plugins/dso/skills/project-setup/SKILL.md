---
name: project-setup
description: Install and configure Digital Service Orchestra in a host project via an interactive wizard
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires direct user interaction (prompts, confirmations, interactive choices). If you are running as a sub-agent dispatched via the Task tool, STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:project-setup cannot run in sub-agent context — it requires direct user interaction. Invoke this skill directly from the main session instead."

Do NOT proceed with any skill logic if you are running as a sub-agent.
</SUB-AGENT-GUARD>

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
- Run `jira-credential-helper.sh` to auto-detect any Jira environment variables already set:
  ```bash
  JIRA_HELPER_OUTPUT=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/jira-credential-helper.sh")
  ```
  Parse the output:
  - `DETECTED=<vars>` — these env vars are already present; use them as defaults when prompting.
  - `MISSING=<vars>` — these are not set; show `GUIDANCE_DESC:` and `GUIDANCE_URL:` lines for each.
  - `CONFIRM_BEFORE_COPY` — if present, JIRA_API_TOKEN is set; prompt the user for confirmation before using it (see Step 6.5 C1).
- Explain that `JIRA_URL`, `JIRA_USER`, and `JIRA_API_TOKEN` are **environment variables** that belong in the user's shell profile (e.g., `~/.zshrc` or `~/.bashrc`) — they are **not** written to `dso-config.conf`.
- If any vars are MISSING, show the user the env vars they need to add to their shell profile:
  ```
  export JIRA_URL=https://your-org.atlassian.net
  export JIRA_USER=you@example.com
  export JIRA_API_TOKEN=<your-api-token>
  ```
  Direct them to https://id.atlassian.com/manage-profile/security/api-tokens to generate a token.
- Use `AskUserQuestion` to ask for the `jira.project` key value (Jira project key, e.g., `DIG`). Record this as `jira.project` in `dso-config.conf`.

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

### Review configuration (`review.*`)

**17. Max resolution attempts** — Use `AskUserQuestion`:
```
How many autonomous fix/defend attempts should the review loop make before escalating to you?
Default: 5
Press Enter to accept the default, or type a number:
```
Record as `review.max_resolution_attempts` (omit if default accepted — the workflow applies 5 when the key is absent).

> **Authoritative key descriptions**: See `docs/CONFIGURATION-REFERENCE.md` for full descriptions of `review.max_resolution_attempts` and `review.behavioral_patterns`.

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

- **No `.github/workflows/*.yml` found**: generate CI workflows from discovered test suites using `ci-generator.sh` (see "New Project: Generate from Discovered Suites" below).
- **Workflow file(s) exist**: does **not** copy or modify any workflow file. Instead, runs `_run_ci_guard_analysis` to report missing CI guards.

#### New Project: Generate from Discovered Suites

When no CI workflow files exist, run `project-detect.sh --suites <TARGET_REPO>` to get the discovered suites JSON array, then invoke `ci-generator.sh` to generate CI workflows:

```bash
# Step 1: Discover test suites
SUITES_JSON="$(project-detect.sh --suites "$TARGET_REPO")"

# Step 2: If suites discovered (non-empty array), invoke the generator
if [[ "$SUITES_JSON" != "[]" && -n "$SUITES_JSON" ]]; then
    # For suites with speed_class=unknown: prompt user (fast/slow/skip, default: slow)
    # In non-interactive mode, default all unknown to slow
    NONINTERACTIVE_FLAG=""
    if ! test -t 0; then
        NONINTERACTIVE_FLAG="--non-interactive"
    fi

    # Write suites JSON to a temp file and invoke ci-generator.sh
    SUITES_TMP="$(mktemp)"
    printf '%s' "$SUITES_JSON" > "$SUITES_TMP"
    ci-generator.sh \
        --suites-json "$SUITES_TMP" \
        --output-dir "$TARGET_REPO/.github/workflows/" \
        $NONINTERACTIVE_FLAG
    rm -f "$SUITES_TMP"

    # ci-generator.sh handles YAML validation internally (actionlint or yaml.safe_load)
    # and exits non-zero on failure — surface any error to the user.
    # Report generated files:
    #   "Generated .github/workflows/ci.yml (N fast suites)"  (if fast suites exist)
    #   "Generated .github/workflows/ci-slow.yml (N slow suites)"  (if slow suites exist)
else
    # Step 3: No suites discovered — fall back to copying the generic CI template
    # (only if no workflow file exists)
    mkdir -p "$TARGET_REPO/.github/workflows/"
    cp "$DSO_ROOT/examples/ci.example.yml" "$TARGET_REPO/.github/workflows/ci.yml"
    echo "No test suites discovered — copied generic CI template. Review and customize .github/workflows/ci.yml."
fi
```

**speed_class=unknown prompting**: When a discovered suite has `speed_class=unknown`, `ci-generator.sh` prompts the user interactively:
```
Suite '<name>' has unknown speed_class. Classify as [f]ast/[s]low/[k]ip (default: slow):
```
In non-interactive mode (`--non-interactive` flag or `CI_NONINTERACTIVE=1`), all suites with `speed_class=unknown` are defaulted to slow without prompting.

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

### Suite Placement for Uncovered Suites

After guard analysis, identify which test suites detected by `project-detect.sh` are not yet covered by any CI workflow step. Then offer to place each uncovered suite into CI.

#### COVERAGE DETECTION

Parse each `.github/workflows/*.yml` file and collect all `run:` values from every workflow step. A suite is **covered** if its command string appears as a substring of any step's `run:` value. `uses:` steps (reusable workflow references) are treated as uncovered — they are not inspected for suite commands.

```bash
# For each detected suite, check if suite.command is a substring of any step run: value
# Suites with no matching run: substring are 'uncovered'
# uses: steps are skipped (treated as uncovered)
```

A suite is **uncovered** when its command does not appear as a substring in any `run:` value across all workflow files.

#### PLACEMENT PROMPT

For each uncovered suite (one at a time), prompt the user with three options using `AskUserQuestion`:

```
Uncovered suite: <suite-name> (command: <suite.command>)

How would you like to place this suite in CI?

1) fast-gate  — append a new job to the existing gating workflow (e.g. ci.yml)
               Job ID derived from suite name: unit → test-unit
               Job template: checkout → setup runtime → run command
2) separate   — create a new workflow file (.github/workflows/ci-<suitename>.yml)
               Triggered on push to main; suite is the sole job
3) skip       — record test.suite.<name>.ci_placement=skip in .claude/dso-config.conf
               Suite will not be prompted again on subsequent runs

Enter 1, 2, or 3:
```

Handle each selection:

- **Option 1 (fast-gate)**: Append to the existing gating workflow (e.g., `ci.yml`). Add a new job whose ID is derived from the suite name (e.g., `unit` → `test-unit`). The job template contains: checkout step, setup runtime step, and a step that runs `<suite.command>`. Validate YAML before writing (see YAML Validation below).
- **Option 2 (separate)**: Create a new workflow file at `.github/workflows/ci-<suitename>.yml` with the suite as its sole job, triggered on push to main. Validate YAML before writing (see YAML Validation below).
- **Option 3 (skip)**: Write `test.suite.<name>.ci_placement=skip` to `.claude/dso-config.conf` (add or update the key). Do not write any workflow file.

#### NON-INTERACTIVE FALLBACK

When running in non-interactive mode (`test -t 0` returns false), apply defaults automatically without prompting:

- **fast suites** (`speed_class=fast`) → fast-gate (append to the existing ci.yml)
- **slow or unknown suites** (`speed_class=slow` or `speed_class=unknown`) → separate workflow (create new file)
- The skip option is unavailable in non-interactive mode

```bash
if ! test -t 0; then
  # non-interactive: apply default placement
  if [ "$speed_class" = "fast" ]; then
    placement="fast-gate"
  else
    placement="separate"
  fi
fi
```

#### INCORPORATED DEFINITION

A suite is **incorporated** when its workflow file or job has been written to disk AND `git add` has been run on the file. Both conditions must be met before the suite is considered incorporated.

#### YAML VALIDATION

Before writing any workflow file (whether appending to an existing file for fast-gate, or creating a new file for separate), validate the YAML output:

1. Write the YAML content to a temporary path (e.g., `<dest>.tmp`).
2. Validate the temporary file:
   - If `actionlint` is on PATH: run `actionlint <tmpfile>`. Exit non-zero blocks the write.
   - Otherwise: run `python3 -c "import yaml; yaml.safe_load(open('<tmpfile>'))"`. Exit non-zero blocks the write.
3. If validation passes: move the temporary file to the final destination path.
4. If validation fails: print the error, remove the temporary file, and do not write the workflow file. Report the failure to the user.

```bash
# temp path → validate → move pattern
TMPFILE="${DEST}.tmp"
write_yaml_to "$TMPFILE"
if command -v actionlint >/dev/null 2>&1; then
  actionlint "$TMPFILE" || { rm -f "$TMPFILE"; echo "YAML validation failed (actionlint)"; exit 1; }
else
  python3 -c "import yaml; yaml.safe_load(open('$TMPFILE'))" || { rm -f "$TMPFILE"; echo "YAML validation failed (yaml.safe_load)"; exit 1; }
fi
mv "$TMPFILE" "$DEST"
git add "$DEST"
```

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
  - will generate .github/workflows/ci.yml from N fast suites  (if suites discovered and fast suites exist)
  - will generate .github/workflows/ci-slow.yml from N slow suites  (if suites discovered and slow suites exist)
  - will copy ci.example.yml → <TARGET_REPO>/.github/workflows/ci.yml (no suites discovered, fallback only)
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

2. **Optional dependency installs** (if any optional tools were not found during setup):
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

## Step 6.5: Jira Bridge Configuration (Skippable)

This step configures the GitHub Actions-based Jira bridge that syncs tickets between the local `tickets` branch and Jira. It is **optional and skippable** — projects without Jira integration continue to work without it.

> **Prerequisite**: This step only runs if the user enabled Jira integration in Step 3 (question 11). If the user declined Jira integration, skip this step entirely.

### Offer the bridge setup

Use `AskUserQuestion`:

```
Would you like to configure the Jira bridge?
The bridge syncs your local tickets to Jira via GitHub Actions, keeping issues in sync automatically.
This requires a GitHub repository with Actions enabled and a Jira API token.
Set up the Jira bridge? (yes/no, default: no)
```

If no (or Enter with default): skip this step entirely. Note:
```
(skipping Jira bridge setup — bridge workflows will remain disabled)
```

If yes: proceed through the sub-steps below in order.

---

### Sub-step A: Ensure the `tickets` branch exists

The bridge CI workflow reads from and writes to a `tickets` branch on the remote. Check whether it exists:

```bash
# Check if tickets branch exists on remote
if git ls-remote --exit-code origin tickets >/dev/null 2>&1; then
  echo "[tickets-branch] Remote branch 'tickets' already exists — skipping creation"
else
  echo "[tickets-branch] Remote branch 'tickets' not found — will create it"
fi
```

If the branch does not exist, create it:

```bash
# Create orphan tickets branch (no commit history from main)
git checkout --orphan tickets
git rm -rf . >/dev/null 2>&1 || true
git commit --allow-empty -m "chore: initialize tickets branch for Jira bridge"
git push origin tickets
git checkout -
```

Report the outcome to the user:
- Branch existed: `tickets branch already present on remote — no action needed.`
- Branch created: `Created and pushed remote branch 'tickets'.`

---

### Sub-step B: Collect required GitHub Variables

The bridge workflow reads configuration from GitHub Actions repository **variables** (not secrets). Collect each one using `AskUserQuestion`, one at a time. For each variable, explain what it is and how to find or derive the value.

**B1. JIRA_URL** — Use `AskUserQuestion`. If `jira-credential-helper.sh` output includes `JIRA_URL` in `DETECTED=`, pre-fill the prompt with the detected env var value as the default:
```
JIRA_URL — The base URL of your Jira instance (e.g., https://your-org.atlassian.net).
This is the same value as your JIRA_URL environment variable.
Auto-detected: <value from $JIRA_URL env var, or "not detected">
Enter value (or press Enter to accept detected value):
```
If the user presses Enter and `$JIRA_URL` is set in the environment, use that value. If not detected, use the value the user enters.

**B2. JIRA_USER** — Use `AskUserQuestion`. If `jira-credential-helper.sh` output includes `JIRA_USER` in `DETECTED=`, pre-fill the prompt with the detected env var value as the default:
```
JIRA_USER — The email address of the Jira account used by the bridge bot.
This is the same value as your JIRA_USER environment variable.
Auto-detected: <value from $JIRA_USER env var, or "not detected">
Enter value (or press Enter to accept detected value):
```
If the user presses Enter and `$JIRA_USER` is set in the environment, use that value. If not detected, use the value the user enters.

**B3. ACLI_VERSION and B4. ACLI_SHA256** — Auto-resolved via `acli-version-resolver.sh`:

```bash
ACLI_RESOLVER_OUT=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/acli-version-resolver.sh" --platform linux --arch amd64 2>/dev/null)
ACLI_VERSION=$(echo "$ACLI_RESOLVER_OUT" | grep '^ACLI_VERSION=' | cut -d= -f2-)
ACLI_SHA256=$(echo "$ACLI_RESOLVER_OUT" | grep '^ACLI_SHA256=' | cut -d= -f2-)
```

The script resolves the installed acli version and computes the SHA-256 checksum of the linux/amd64 tarball (the platform used by GitHub Actions runners). No user prompt is needed when the script succeeds.

If `ACLI_VERSION` is empty after the above (script failed — e.g., acli not installed and network unavailable), prompt the user
via `AskUserQuestion`:
```
ACLI_VERSION — Could not be resolved automatically.
The Atlassian CLI (acli) version to install in CI (e.g., 1.3.0).
ACLI v1.3+ is required for auth via 'acli jira auth login --site --email --token'.
Check available versions at: https://github.com/ankitpokhrel/jira-cli/releases
Enter value:
```

If `ACLI_SHA256` is empty after auto-resolution (or after manual version entry), prompt the user
via `AskUserQuestion`:
```
ACLI_SHA256 — Could not be resolved automatically.
The SHA-256 checksum of the acli linux/amd64 tar.gz release asset (used to verify CI download integrity).

Options:
  a) Enter the SHA-256 now (find it in the release's checksum file or brew formula)
  b) Leave blank to bootstrap — the first CI run will log the actual hash; update this
     variable after reviewing the log output.

Enter SHA-256 (or leave blank to bootstrap):
```
If blank, record as empty — the bridge workflow will perform hash-bootstrap logging on first run.

**B5–B7. Identity resolution (BRIDGE_BOT_LOGIN, BRIDGE_BOT_NAME, BRIDGE_BOT_EMAIL)**

Run `gh-identity-resolver.sh --own-identity` to get the authenticated user's login for display, then ask the user which identity to use:

```bash
IDENTITY_OUT=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/gh-identity-resolver.sh" --own-identity 2>/dev/null)
OWN_LOGIN=$(echo "$IDENTITY_OUT" | grep '^BRIDGE_BOT_LOGIN=' | cut -d= -f2-)
```

Use `AskUserQuestion`:
```
BRIDGE_BOT_LOGIN/NAME/EMAIL — The GitHub identity used for commit authorship in bridge sync commits.
This account needs write access to the repository.

Detected authenticated GitHub user: {OWN_LOGIN}

Options:
  a) Use your GitHub identity ({OWN_LOGIN})
  b) Configure a bot account (e.g., github-actions[bot] or a dedicated service account)

Enter choice (a/b):
```

**If the user chooses (a) — own identity:**

Parse the key=value output from `gh-identity-resolver.sh --own-identity` (already captured above):

```bash
# Parse key=value lines
BRIDGE_BOT_LOGIN=$(echo "$IDENTITY_OUT" | grep '^BRIDGE_BOT_LOGIN=' | cut -d= -f2-)
BRIDGE_BOT_NAME=$(echo "$IDENTITY_OUT"  | grep '^BRIDGE_BOT_NAME='  | cut -d= -f2-)
BRIDGE_BOT_EMAIL=$(echo "$IDENTITY_OUT" | grep '^BRIDGE_BOT_EMAIL=' | cut -d= -f2-)
```

If any of `BRIDGE_BOT_LOGIN` or `BRIDGE_BOT_NAME` is empty (script failed to resolve), fall back to `AskUserQuestion` for the missing field(s). Do NOT proceed with empty values. Fallback prompts:
- `BRIDGE_BOT_LOGIN`: "BRIDGE_BOT_LOGIN — The GitHub username for bridge commit authorship. Enter value:"
- `BRIDGE_BOT_NAME`: "BRIDGE_BOT_NAME — The display name for bridge commit authorship (e.g., 'DSO Bridge Bot'). Enter value:"

If `BRIDGE_BOT_EMAIL` equals `PROMPT_NEEDED` (the script could not resolve an email automatically), prompt via `AskUserQuestion`:
```
BRIDGE_BOT_EMAIL — Your GitHub profile email could not be resolved automatically.
For personal accounts, use your GitHub-provided noreply address: <username>@users.noreply.github.com
Or enter any email you use for git commits.

Enter email address:
```
Record the entered value as `BRIDGE_BOT_EMAIL`.

**If the user chooses (b) — bot account:**

Run `gh-identity-resolver.sh --bot` to get placeholder values, then let the user override each one. Parse key=value output:

```bash
BOT_OUT=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/gh-identity-resolver.sh" --bot 2>/dev/null)
DEFAULT_LOGIN=$(echo "$BOT_OUT" | grep '^BRIDGE_BOT_LOGIN=' | cut -d= -f2-)
DEFAULT_NAME=$(echo "$BOT_OUT"  | grep '^BRIDGE_BOT_NAME='  | cut -d= -f2-)
DEFAULT_EMAIL=$(echo "$BOT_OUT" | grep '^BRIDGE_BOT_EMAIL=' | cut -d= -f2-)
```

Use `AskUserQuestion` for each field, showing the default:
```
BRIDGE_BOT_LOGIN — GitHub username of the bot account (default: {DEFAULT_LOGIN}).
Enter username (or press Enter to use default):
```
```
BRIDGE_BOT_NAME — Display name for commit authorship (default: {DEFAULT_NAME}).
Enter display name (or press Enter to use default):
```
```
BRIDGE_BOT_EMAIL — Email for commit authorship (default: {DEFAULT_EMAIL}).
Enter email (or press Enter to use default):
```
If the user leaves a field blank, use the corresponding default value.

**B8. BRIDGE_ENV_ID** — Auto-resolved (no prompt needed)

Run `gh-identity-resolver.sh --env-id` and parse the output:

```bash
ENV_ID_OUT=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/gh-identity-resolver.sh" --env-id 2>/dev/null)
BRIDGE_ENV_ID=$(echo "$ENV_ID_OUT" | grep '^BRIDGE_ENV_ID=' | cut -d= -f2-)
```

The script derives the environment ID from the repository's GitHub org and name (e.g., `github-myorg-myrepo`). No user prompt is needed unless the script fails — if `BRIDGE_ENV_ID` is empty after the above, prompt the user
via `AskUserQuestion`:
```
BRIDGE_ENV_ID — Could not be resolved automatically from the repository context.
Enter an identifier for the bridge environment (e.g., "github-myorg-myrepo"):
```

> **Note on gh variable set failures**: If any `gh variable set` call for an auto-resolved value fails in Sub-step D, print the resolved value to the terminal so the user can set it manually (e.g., `[bridge] BRIDGE_ENV_ID resolved as: github-myorg-myrepo — set manually via GitHub web UI`).

---

### Sub-step C: Collect required GitHub Secret

**C1. JIRA_API_TOKEN** — Before prompting, check whether `jira-credential-helper.sh` output includes `CONFIRM_BEFORE_COPY`. If it does, JIRA_API_TOKEN is already set in the environment. Use `AskUserQuestion` to present the confirmation gate:
```
JIRA_API_TOKEN is already set in your environment (CONFIRM_BEFORE_COPY signal detected).
Would you like to use the current $JIRA_API_TOKEN value for the GitHub Actions secret? (yes/no)
Note: The token value will NOT be echoed — it will be passed directly to 'gh secret set'.
```
- If the user says **yes**: use `$JIRA_API_TOKEN` directly in Sub-step D (do not prompt for the token value).
- If the user says **no** (or JIRA_API_TOKEN is not in the environment): Use `AskUserQuestion`:
```
JIRA_API_TOKEN — The Jira API token used by the bridge to authenticate with Jira.
This will be stored as a GitHub Actions repository SECRET (encrypted, not visible after entry).
Generate a token at: https://id.atlassian.com/manage-profile/security/api-tokens

Enter the API token (it will NOT be shown back or stored locally):
```

> **Security note**: Do NOT write this value to `dso-config.conf` or any local file. It must only be stored as a GitHub Actions secret.

---

### Sub-step D: Apply GitHub Variables and Secrets

Before setting variables and secrets, check whether the `gh` CLI is available and authenticated by running:

```bash
GH_CHECK=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/gh-availability-check.sh" \
  --vars=JIRA_URL,JIRA_USER,ACLI_VERSION,ACLI_SHA256,BRIDGE_BOT_LOGIN,BRIDGE_BOT_NAME,BRIDGE_BOT_EMAIL,BRIDGE_ENV_ID \
  --secrets=JIRA_API_TOKEN)
GH_STATUS=$(echo "$GH_CHECK" | grep -E '^GH_STATUS=' | cut -d= -f2 | tr -d '[:space:]')
FALLBACK_LINES=$(echo "$GH_CHECK" | grep -v '^GH_STATUS=\|^FALLBACK=')
```

Route based on `GH_STATUS`:

**If `GH_STATUS=authenticated`**: proceed with the `gh` CLI commands below.

**If `GH_STATUS=not_authenticated`**: print the fallback commands from the script output and skip all `gh` operations. Inform the user:
```
[bridge] gh CLI is installed but not authenticated.
[bridge] After running 'gh auth login', set variables and secrets with the following commands:

$FALLBACK_LINES
```
Then continue to Sub-step E without setting any variables or secrets.

**If `GH_STATUS=not_installed`**: print the UI navigation steps from the script output and skip all `gh` operations. Inform the user:
```
[bridge] gh CLI is not installed.
[bridge] Set variables and secrets manually via the GitHub web UI:

$FALLBACK_LINES
```
Then continue to Sub-step E without setting any variables or secrets.

---

**Authenticated path**: Using the `gh` CLI, set all collected variables and the secret on the GitHub repository.

```bash
# Set repository variables (visible in workflow logs, not encrypted)
gh variable set JIRA_URL       --body "<JIRA_URL_VALUE>"
gh variable set JIRA_USER      --body "<JIRA_USER_VALUE>"
gh variable set JIRA_PROJECT   --body "<JIRA_PROJECT_VALUE>"   # from jira.project in dso-config.conf (set in Step 3 Q11)
gh variable set ACLI_VERSION   --body "<ACLI_VERSION_VALUE>"
gh variable set BRIDGE_BOT_LOGIN   --body "<BRIDGE_BOT_LOGIN_VALUE>"
gh variable set BRIDGE_BOT_NAME    --body "<BRIDGE_BOT_NAME_VALUE>"
gh variable set BRIDGE_BOT_EMAIL   --body "<BRIDGE_BOT_EMAIL_VALUE>"
gh variable set BRIDGE_ENV_ID  --body "<BRIDGE_ENV_ID_VALUE>"

# Set ACLI_SHA256 only if a non-empty value was provided
if [[ -n "<ACLI_SHA256_VALUE>" ]]; then
    gh variable set ACLI_SHA256 --body "<ACLI_SHA256_VALUE>"
fi

# Set the API token as a secret (encrypted)
gh secret set JIRA_API_TOKEN --body "<JIRA_API_TOKEN_VALUE>"
```

The `JIRA_PROJECT` value is the `jira.project` key written to `dso-config.conf` during Step 3 Q11 (e.g., `DIG`). Read it from the config file rather than re-prompting the user.

Report each variable/secret as it is set:
```
[bridge] Set variable: JIRA_URL
[bridge] Set variable: JIRA_USER
[bridge] Set variable: JIRA_PROJECT
[bridge] Set variable: ACLI_VERSION
[bridge] Set variable: ACLI_SHA256  (or: [bridge] ACLI_SHA256 skipped — will bootstrap on first CI run)
[bridge] Set variable: BRIDGE_BOT_LOGIN
[bridge] Set variable: BRIDGE_BOT_NAME
[bridge] Set variable: BRIDGE_BOT_EMAIL
[bridge] Set variable: BRIDGE_ENV_ID
[bridge] Set secret:   JIRA_API_TOKEN
```

If `gh variable set` or `gh secret set` fails (non-zero exit), report the error and ask the user whether to retry or skip. Do not abort the entire setup on a single variable failure.

---

### Sub-step E: Validate ACLI connectivity

After setting the secret, validate that the ACLI authentication works correctly. This requires `acli` to be installed (Step 3, Optional dependencies).

If `acli` is not installed on the local machine, skip connectivity validation with a note:
```
(skipping ACLI auth validation — acli not installed locally; connectivity will be verified on first CI run)
```

If `acli` is installed, run the auth login command:

```bash
acli jira auth login \
    --site "$JIRA_URL" \
    --email "$JIRA_USER" \
    --token "$JIRA_API_TOKEN_VALUE"
```

Interpret the result:
- **Exit 0**: Report `[bridge] ACLI auth validated — Jira connectivity confirmed.`
- **Non-zero exit**: Report the error output and prompt:
  ```
  ACLI auth login failed. This may indicate an incorrect JIRA_URL, JIRA_USER, or JIRA_API_TOKEN.
  Options:
    1) Re-enter credentials and retry
    2) Skip validation (bridge setup continues; verify connectivity manually)
  Enter 1 or 2:
  ```
  If option 1: return to Sub-step B1 to re-collect JIRA_URL/JIRA_USER, and C1 for the token. Re-run Sub-steps D and E.
  If option 2: skip validation and continue to Sub-step F.

---

### Sub-step F: Enable the bridge cron and run a test sync

After credentials are validated, instruct the user to enable the bridge cron workflow manually in the GitHub Actions UI (automated cron cannot be enabled via `gh` CLI):

```
[bridge] Manual step required:
  1. Go to your repository on GitHub → Actions → Jira Bridge (Inbound) workflow
  2. Click "Enable workflow" to activate the scheduled cron trigger
  3. Optionally click "Run workflow" to trigger an immediate sync

The bridge cron runs on a schedule defined in the workflow file.
```

Then optionally offer to run a test sync immediately via `gh workflow run`:

Use `AskUserQuestion`:
```
Would you like to trigger a test sync now via 'gh workflow run'? (yes/no, default: no)
This dispatches the bridge workflow immediately to verify end-to-end connectivity.
```

If yes:
```bash
gh workflow run jira-bridge-inbound.yml
```
Report: `[bridge] Test sync dispatched. Check GitHub Actions for the workflow run status.`
Provide the link: `https://github.com/<owner>/<repo>/actions`

If no: skip.

---

### Sub-step G: Bridge setup summary

Report the final bridge setup outcome:

```
=== Jira Bridge Setup Complete ===

tickets branch: <created | already existed>
GitHub variables set: JIRA_URL, JIRA_USER, JIRA_PROJECT, ACLI_VERSION, ACLI_SHA256 (or: bootstrap), BRIDGE_BOT_LOGIN, BRIDGE_BOT_NAME, BRIDGE_BOT_EMAIL, BRIDGE_ENV_ID
GitHub secret set:    JIRA_API_TOKEN
ACLI connectivity:    <validated | skipped — not installed | skipped — user choice>
Bridge cron:          Manual activation required (see GitHub Actions UI)
Test sync:            <dispatched | skipped>
```

If `ACLI_SHA256` was left blank (bootstrap mode), include a reminder:
```
IMPORTANT: ACLI_SHA256 bootstrap reminder
On the first bridge CI run, the workflow will log the actual SHA-256 hash.
After reviewing the log, run:
  gh variable set ACLI_SHA256 --body "<hash-from-log>"
This ensures subsequent runs verify the download integrity.
```

---

## Step 7: Onboarding Foundations

After completing project setup, offer to run the architecture and design onboarding skills. These skills produce foundational documents that guide future Claude sessions in the target project.

- `/dso:dev-onboarding` — produces `ARCH_ENFORCEMENT.md`: an architecture blueprint and enforcement rules for the codebase
- `/dso:design-onboarding` — produces `.claude/design-notes.md`: visual language conventions and component golden paths

### Artifact detection

Check for the sentinel files that indicate whether each onboarding skill has already run:

```bash
ARCH_SENTINEL="$TARGET_REPO/ARCH_ENFORCEMENT.md"
DESIGN_SENTINEL="$TARGET_REPO/.claude/design-notes.md"

dev_done=false
design_done=false

[ -f "$ARCH_SENTINEL" ] && dev_done=true
[ -f "$DESIGN_SENTINEL" ] && design_done=true
```

- **`ARCH_ENFORCEMENT.md`** is the sentinel for `/dso:dev-onboarding`
- **`.claude/design-notes.md`** is the sentinel for `/dso:design-onboarding`

### Conditional prompt

**Case 1: Both artifacts present — skip this step entirely**

If both `ARCH_ENFORCEMENT.md` and `.claude/design-notes.md` already exist in the target project, both onboarding skills have already run. Skip the prompt entirely and log:

```
(skipping onboarding prompt — both artifacts already present: ARCH_ENFORCEMENT.md, .claude/design-notes.md)
```

No further action is needed. Setup is complete.

---

**Case 2: Both artifacts missing — 4-option AskUserQuestion**

When both `ARCH_ENFORCEMENT.md` and `.claude/design-notes.md` are missing, use `AskUserQuestion` to offer all onboarding options:

```
Would you like to set up architecture and design foundations for this project?

1) Both (recommended) — runs dev-onboarding then design-onboarding: produces ARCH_ENFORCEMENT.md (architecture blueprint and enforcement rules) and .claude/design-notes.md (visual design language and golden paths)
2) Architecture only — runs /dso:dev-onboarding: produces ARCH_ENFORCEMENT.md with codebase architecture guide and enforcement rules for future Claude sessions
3) Design system only — runs /dso:design-onboarding: produces .claude/design-notes.md with visual language conventions and component golden paths
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

**If only `.claude/design-notes.md` is missing** (design-onboarding not yet run):

```
Would you like to run /dso:design-onboarding?
design-onboarding produces .claude/design-notes.md — a visual design language guide and component
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
