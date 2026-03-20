---
name: project-setup
description: Install and configure Digital Service Orchestra in a host project via an interactive wizard
user-invocable: true
---

# Project Setup — Install and Configure DSO

This skill is the primary entry point for onboarding a new project to Digital Service Orchestra. It replaces `/dso:init` with a richer, guided experience: it runs `dso-setup.sh` to install the DSO shim, detects the project stack, walks through an interactive configuration wizard that generates `workflow-config.conf`, and offers to copy starter templates.

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

> **Authoritative key source**: Read `docs/CONFIGURATION-REFERENCE.md` for the complete list of `workflow-config.conf` keys, their descriptions, accepted values, and defaults. Do NOT hardcode key descriptions inline — always reference that document.

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
- Explain that `JIRA_URL`, `JIRA_USER`, and `JIRA_API_TOKEN` are **environment variables** that belong in the user's shell profile (e.g., `~/.zshrc` or `~/.bashrc`) — they are **not** written to `workflow-config.conf`.
- Use `AskUserQuestion` to ask for the `jira.project` key value (Jira project key, e.g., `DIG`). Record this for `workflow-config.conf`.
- Show the user the env vars they need to add to their shell profile:
  ```
  export JIRA_URL=https://your-org.atlassian.net
  export JIRA_USER=you@example.com
  export JIRA_API_TOKEN=<your-api-token>
  ```
  Direct them to https://id.atlassian.com/manage-profile/security/api-tokens to generate a token.

If no: skip the Jira sub-section.

### dso.* section

The `dso.plugin_root` key is written automatically by `dso-setup.sh` — do NOT prompt for it or duplicate it.

### Monitoring

Use `AskUserQuestion`: "Enable tool error monitoring and auto-ticket creation? (y/N, default: N):"

- If **yes**: write `monitoring.tool_errors=true` to `workflow-config.conf`. This enables automatic tracking of tool errors and creates tickets for them.
- If **no** (or default): omit the `monitoring.tool_errors` key entirely from `workflow-config.conf`. The feature is disabled when the key is absent. This is a safe-off default — opt-in only.

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
workflow-config.yml (YAML format) instead of workflow-config.conf will not be available.
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

---

## Step 4: Write workflow-config.conf

**In normal mode**: Write the confirmed key=value pairs to `$TARGET_REPO/workflow-config.conf`.

**In dryrun mode**: Do NOT write the file. Instead, display a flat list of planned outcomes — what will happen to the user's project files. Do NOT distinguish between which internal component (script vs skill) performs each action; users care about results, not implementation details.

Collect all planned actions across Steps 1–3 and present them as a unified flat list:

```
=== Dryrun Preview ===

The following changes will be made to <TARGET_REPO>:

  - will install the DSO shim at .claude/scripts/dso
  - will write workflow-config.conf with <N> keys (commands.test, commands.lint, ...)
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

## Step 5: Copy DSO Templates (optional)

Check for missing starter files and offer to copy them:

1. **CLAUDE.md**: If `$TARGET_REPO/CLAUDE.md` does not exist, offer to copy `$CLAUDE_PLUGIN_ROOT/templates/CLAUDE.md.template` to `$TARGET_REPO/CLAUDE.md`.

2. **Known issues doc**: If `$TARGET_REPO/.claude/docs/` does not exist or does not contain `KNOWN-ISSUES.md`, offer to copy `$CLAUDE_PLUGIN_ROOT/templates/KNOWN-ISSUES.example.md` to `$TARGET_REPO/.claude/docs/KNOWN-ISSUES.md`.

**In normal mode**: For each offer, ask the user "Copy <file>? (yes/no)" before copying. Never copy without confirmation.

**In dryrun mode**: Do NOT copy any files. Instead, list which templates would be copied:

```
[dryrun] Templates that would be copied:
  - CLAUDE.md.template → <TARGET_REPO>/CLAUDE.md  (if confirmed)
  - KNOWN-ISSUES.example.md → <TARGET_REPO>/.claude/docs/KNOWN-ISSUES.md  (if confirmed)
```

Ask: "Proceed with template copy? (yes/no)"
- If **yes** and this is the first dryrun pass: re-run Steps 1–5 without `--dryrun`, reusing all confirmed answers.
- If **no**: skip template copy and continue to Step 6 summary.

---

## Step 6: Success Summary

Print a summary of what was configured, followed by a **manual steps** section listing everything the user still needs to do.

```
=== DSO Project Setup Complete ===

Target repo: <TARGET_REPO>
Stack: <STACK>
workflow-config.conf: written

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

1. **Jira environment variables** (shown only if Jira was configured in Step 3, since these are never written to `workflow-config.conf`):
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

## Error Handling Reference

| Situation | Response |
|-----------|----------|
| `dso-setup.sh` exits 1 (fatal) | Print error, stop — do NOT proceed to wizard |
| `dso-setup.sh` exits 2 (warnings) | Print warnings, ask user to continue |
| `detect-stack.sh` returns `unknown` | Ask user for manual command input |
| `workflow-config.conf` exists | Add/update only confirmed keys; preserve existing keys |
| User declines template copy | Skip the copy; continue to next step |
| User declines to continue after exit 2 | Stop gracefully |
| User says "no" to dryrun Proceed prompt | Stop gracefully — "Setup cancelled. No changes were made." |
| User says "yes" to dryrun Proceed prompt | Re-run Steps 1–5 without `--dryrun`, reusing collected answers |
