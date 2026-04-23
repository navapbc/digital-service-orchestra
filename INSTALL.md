# Installing Digital Service Orchestra

This file is for platform engineers onboarding onto DSO. It covers the prerequisites, plugin installation commands, optional tooling, and how to run `/dso:onboarding` to configure DSO for your project.

## Prerequisites

All prerequisites below are **blocking** — they must be installed before running the `/plugin` commands.

- **[Homebrew](https://brew.sh/)** (macOS): the package manager used for most prerequisite installations. Install via the one-liner at https://brew.sh/
- **Claude Code**: the CLI that hosts DSO. Download from https://claude.ai/code and follow the setup guide there.
- **bash >= 4.0**: DSO hooks require bash 4.0 or later. macOS ships with bash 3.2.57 (GPL-2); upgrade with:
  ```
  brew install bash
  ```
- **GNU coreutils** (macOS): required for portable shell utilities (`timeout`, `date -d`, etc.). Install with:
  ```
  brew install coreutils
  ```

## Installation

Run the following commands inside Claude Code while your working directory is set to the project you want DSO to manage:

```
/plugin marketplace add navapbc/digital-service-orchestra
/plugin install dso@digital-service-orchestra
```

After the plugin is installed, proceed to [Getting Started with /dso:onboarding](#getting-started-with-dsoonboarding) below.

### Release Channels

DSO is published on two channels. Choose the channel that fits your team's risk tolerance:

| Channel | Install command | When it advances |
|---------|----------------|-----------------|
| **Stable** (default) | `/plugin install dso@digital-service-orchestra` | Tagged releases only |
| **Dev** | `/plugin install dso-dev@digital-service-orchestra` | Every merge to main |

**Version semantics**: dso advances on tagged releases; dso-dev advances on every merge to main.

**Recommendation**: Enable auto-update for your chosen channel in the marketplace via the `/plugin` UI so you receive fixes and improvements automatically without a manual reinstall.

## Optional Dependencies

- **ast-grep** (`sg`): enables structural code search in `/dso:fix-bug`, `/dso:sprint`, and other skills. DSO falls back to text grep when `ast-grep` is absent, but structural search significantly reduces false positives when tracing call sites and dependency graphs. Install with:
  ```
  brew install ast-grep
  ```

### Optional Plugins — Agent Enhancements

DSO works standalone with `general-purpose` agents for all task categories. Installing optional
Claude Code plugins adds specialized agents that are automatically discovered:

| Plugin | Enhancement |
|--------|-------------|
| **feature-dev** | Code review (`code-reviewer`), architecture exploration (`code-explorer`, `code-architect`) |
| **error-debugging** | Error pattern detection (`error-detective`), structured debugging (`debugger`); enhances INTERMEDIATE investigation in `/dso:fix-bug` |
| **playwright** | Browser automation for visual regression testing and staging verification via `@playwright/cli` (`npm install --save-dev @playwright/cli`) |

When a plugin is not installed, DSO falls back to `general-purpose` with a category-specific
prompt. No manual configuration is required.

## Getting Started with /dso:onboarding

`/dso:onboarding` is a Socratic dialogue that configures DSO for your specific project. It walks you through your stack, key commands, architecture overview, CI setup, and enforcement preferences — writing a `CLAUDE.md` and `dso-config.conf` tailored to your project. Non-interactive defaults are offered throughout, so you can move quickly or go deep.

Plan for **20–40 minutes** for a typical first run. Re-running `/dso:onboarding` on an existing project is safe; it performs an elevation-only update (never overwrites higher-confidence values).

Full configuration reference: [`plugins/dso/docs/CONFIGURATION-REFERENCE.md`](plugins/dso/docs/CONFIGURATION-REFERENCE.md)

## Integration Setup

Some DSO skills integrate with external tools. Each integration is optional and configured via environment variables or the DSO config file. Skip any integration you don't use.

### Jira

DSO's ticket system can sync to Jira issues. To enable, set:

- `JIRA_URL` — your Jira base URL (e.g., `https://your-org.atlassian.net`)
- `JIRA_USER` — the email address of the Atlassian account used for API access
- `JIRA_API_TOKEN` — an Atlassian API token

Create an API token at: https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/

### Figma

DSO's design collaboration features can pull Figma designs into your implementation manifests. To enable, set a Figma personal access token via `FIGMA_PAT` (or the equivalent DSO config key `design.figma_pat`).

Create a personal access token at: https://help.figma.com/hc/en-us/articles/8085703771159-Manage-personal-access-tokens

### Confluence

Confluence integration is planned but not yet available — no setup steps at this time.
