---
name: project-setup
description: Install and configure Digital Service Orchestra in a host project via an interactive wizard
user-invocable: true
---

# Project Setup — Install and Configure DSO

This skill is the primary entry point for onboarding a new project to Digital Service Orchestra. It replaces `/dso:init` with a richer, guided experience: it runs `dso-setup.sh` to install the DSO shim, detects the project stack, walks through an interactive configuration wizard that generates `workflow-config.conf`, and offers to copy starter templates.

---

## Step 1: Run dso-setup.sh

Determine the target repository:

```bash
# If already in the target repo or a git repo exists:
TARGET_REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

Then run the setup script:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/dso-setup.sh" "$TARGET_REPO"
SETUP_EXIT=$?
```

Handle exit codes as follows:

| Exit code | Meaning | Action |
|-----------|---------|--------|
| 0 | Success | Proceed to Step 2 |
| 1 | Fatal error (missing required prerequisite) | Print the error output from `dso-setup.sh`. **Stop here — do NOT proceed to the wizard.** Tell the user to fix the prerequisite and re-run `/dso:project-setup`. |
| 2 | Warnings only (non-fatal prerequisites missing) | Print the warnings from `dso-setup.sh`. Ask the user: "One or more optional prerequisites are missing (see above). Continue with setup? (yes/no)". If yes, proceed to Step 2. If no, stop. |

> **Exit 1 (fatal)**: Print the error, stop immediately, do NOT proceed to the wizard.

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

Work through each config section relevant to initial setup. For each key:

1. Present the key name, its description (from `docs/CONFIGURATION-REFERENCE.md`), and its default value.
2. Ask the user to confirm the default or provide a custom value.
3. Record the confirmed value for writing in Step 4.

### Commands section (`commands.*`)

If `STACK` is not `unknown`, propose stack-derived defaults using the table from `skills/init/SKILL.md`. Confirm each with the user.

If `STACK=unknown`, ask the user to provide values manually:

```
No recognized stack found. Please provide:
  - test command (e.g., 'make test'):
  - lint command (e.g., 'make lint'):
  - format command (e.g., 'make format', or leave blank):
  - format_check command (e.g., 'make format-check', or leave blank):
  - validate command (e.g., './scripts/validate.sh --ci', or leave blank):
```

### Jira integration

Ask: "Do you use Jira for issue tracking? (yes/no)"

If yes:
- Explain that `JIRA_URL`, `JIRA_USER`, and `JIRA_API_TOKEN` are **environment variables** that belong in the user's shell profile (e.g., `~/.zshrc` or `~/.bashrc`) — they are **not** written to `workflow-config.conf`.
- Ask for the `jira.project` key value (Jira project key, e.g., `DIG`). Record this for `workflow-config.conf`.
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

### Optional dependencies

Inform the user about optional enhancements (do not block setup if declined):

- **acli**: Enables Jira integration within Claude Code. Install: `brew install acli`
- **PyYAML**: Enables legacy YAML config format. Install: `pip3 install pyyaml`

Ask: "Would you like install instructions for these optional tools? (yes/no)" Show them only if the user says yes.

---

## Step 4: Write workflow-config.conf

Write the confirmed key=value pairs to `$TARGET_REPO/workflow-config.conf`.

Rules:
- Format: `KEY=VALUE` (flat, one per line, dot-notation keys).
- If the file already exists: **add or update** only the keys the user confirmed in Step 3. Do not remove or overwrite other existing keys.
- The `dso.plugin_root` key is already written by `dso-setup.sh` in Step 1 — do NOT duplicate it.
- Always include `version=1.0.0` if the file is being created fresh (and `version` is not already present).

---

## Step 5: Copy DSO Templates (optional)

Check for missing starter files and offer to copy them:

1. **CLAUDE.md**: If `$TARGET_REPO/CLAUDE.md` does not exist, offer to copy `$CLAUDE_PLUGIN_ROOT/templates/CLAUDE.md.template` to `$TARGET_REPO/CLAUDE.md`.

2. **Known issues doc**: If `$TARGET_REPO/.claude/docs/` does not exist or does not contain `KNOWN-ISSUES.md`, offer to copy `$CLAUDE_PLUGIN_ROOT/templates/KNOWN-ISSUES.example.md` to `$TARGET_REPO/.claude/docs/KNOWN-ISSUES.md`.

For each offer, ask the user "Copy <file>? (yes/no)" before copying. Never copy without confirmation.

---

## Step 6: Success Summary

Print a summary of what was configured:

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

If Jira was configured, remind the user:

```
Add these env vars to your shell profile (~/.zshrc or ~/.bashrc):
  export JIRA_URL=https://your-org.atlassian.net
  export JIRA_USER=you@example.com
  export JIRA_API_TOKEN=<your-api-token>
```

Link to full documentation:

```
Full documentation: docs/INSTALL.md
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
