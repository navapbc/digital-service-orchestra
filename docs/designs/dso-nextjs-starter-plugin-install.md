# DSO NextJS Starter: Plugin Install Consent Design

> **Status (2026-04-19)**: The DSO NextJS template referenced in this design is now live at <https://github.com/navapbc/digital-service-orchestra-nextjs-template>. The interface contract between `scripts/create-dso-app.sh` and the template is documented at [`create-dso-app-template-contract.md`](create-dso-app-template-contract.md). This document remains the design rationale for the consent flow.

## Overview

This document investigates whether placing `extraKnownMarketplaces` and `enabledPlugins` in a
project's `.claude/settings.json` will trigger a consent/install dialog when a developer first
opens the project in Claude Code — enabling the DSO plugin to be auto-installed without any
manual `claude plugin install` step.

The use case is the **DSO NextJS Starter template**: a scaffolded project that ships with a
pre-populated `.claude/settings.json` pointing to the DSO plugin marketplace. The question is
whether a first-time user who clones the template and runs `claude` will be automatically
prompted to install the DSO plugin.

---

## Research Findings

### Official Documentation (code.claude.com/docs/en/settings — April 2026)

The authoritative Claude Code settings reference describes `extraKnownMarketplaces` behavior
under **Plugin settings**:

> **When a repository includes `extraKnownMarketplaces`**:
> 1. Team members are prompted to install the marketplace when they trust the folder
> 2. Team members are then prompted to install plugins from that marketplace
> 3. Users can skip unwanted marketplaces or plugins (stored in user settings)
> 4. Installation respects trust boundaries and requires explicit consent

This is a two-step flow: marketplace registration consent, then plugin install consent. Both are
interactive prompts that appear at the workspace trust moment.

### GitHub Issue #13097: Interactive-Only Constraint

Issue [#13097](https://github.com/anthropics/claude-code/issues/13097) ("Clarify that
extraKnownMarketplaces requires interactive trust dialog") documents that:

- The `extraKnownMarketplaces` feature **only activates during interactive mode**
- In headless/print mode (`-p` flag), the trust dialog is skipped entirely and
  `extraKnownMarketplaces` is not processed
- This is intentional: consent requires a human at the keyboard

An independent investigation (gist linked in the issue) confirmed:

> "Two separate systems exist: project-level `extraKnownMarketplaces` (ignored by plugin
> commands) and user-level `known_marketplaces.json` (actually consulted). The auto-installation
> bridge between them only engages during the interactive trust moment."

This means the mechanism works in the exact scenario we care about — a developer running
`claude` interactively in a newly cloned repo — and does not apply to CI or headless runs.

### GitHub Issue #32607: Silent Failure for Uninstalled Enabled Plugins

Issue [#32607](https://github.com/anthropics/claude-code/issues/32607) ("No warning when
enabledPlugins references a plugin that is not installed") identifies a current gap:

- If `enabledPlugins` lists a plugin but the user skips installation or the marketplace prompt
  doesn't fire, Claude Code **silently does nothing** — no error, no warning
- Users see `Unknown skill: dso:sprint` with no diagnostic path

This does not affect the primary consent flow (which does present a prompt), but it matters
for the degraded-path experience documented below.

### GitHub Issue #23737: Auto-Install Feature Request

Issue [#23737](https://github.com/anthropics/claude-code/issues/23737) ("Auto-install plugins
from enabledPlugins in shared settings.json") was filed requesting fully automatic installation
without a consent prompt. It was **closed as a duplicate** of an existing open feature request.

Key implication: as of April 2026, fully silent auto-install (no dialog at all) is **not
implemented**. The consent prompt approach documented in the official docs is the current
mechanism.

### Platform Consistency Note

Issue [#32268](https://github.com/anthropics/claude-code/issues/32268) documents that the
official Anthropic marketplace (`claude-plugins-official`) is pre-registered on macOS but
**not** on Windows. For a custom DSO marketplace, `extraKnownMarketplaces` registration is
required on all platforms, making the `.claude/settings.json` approach consistently necessary
regardless of OS.

---

## Success Path

**When `extraKnownMarketplaces` + `enabledPlugins` is used in project settings:**

A developer clones the DSO NextJS Starter and runs `claude` in interactive mode:

1. Claude Code detects a new (untrusted) project directory and presents the workspace trust dialog
2. Developer selects "Yes, proceed" (trust the folder)
3. Claude Code reads `.claude/settings.json`, finds `extraKnownMarketplaces` pointing to the
   DSO plugin marketplace
4. A second prompt appears: "This project recommends the [DSO] marketplace — install it?"
5. Developer confirms; the marketplace catalog is fetched
6. A third prompt (or sequential continuation) appears for each plugin listed in
   `enabledPlugins`: "Install [digital-service-orchestra]?"
7. Developer confirms; the DSO plugin installs and is available immediately

The user experience is a guided sequence of two or three consent dialogs, not a manual
`claude plugin install` invocation. From the developer's perspective, opening a new project
*just works* after clicking through the prompts.

**Limitations of this path:**

- Requires interactive mode — the prompts do not appear in `claude -p` (headless) runs
- Users can skip each prompt (stored as "dismissed" in their local settings)
- If skipped, the plugin is silently absent with no follow-up warning (see Issue #32607)
- Does not apply in CI/CD pipelines — the template's README should document the manual
  `claude plugin marketplace add` + `claude plugin install` commands for CI contexts

---

## Failure Path

**Conditions under which the consent flow does not trigger:**

1. **Headless/CI mode** (`claude -p`): Trust dialog is skipped; `extraKnownMarketplaces` is
   never processed. This is intentional, not a bug.
2. **Already-trusted directory**: If the developer has previously trusted the directory (e.g.,
   ran `claude` before the template's `.claude/settings.json` was committed), the trust dialog
   may not re-appear. The marketplace prompt fires only on the first trust event.
3. **User dismisses the prompt**: Dismissed marketplaces and plugins are recorded in the user's
   `~/.claude/settings.json` and will not prompt again on subsequent runs.
4. **Plugin listed in `enabledPlugins` is not yet installed**: If the marketplace prompt fires
   but the user skips the plugin install step, subsequent skill invocations fail silently
   (Issue #32607 — no warning is shown).

The failure path does not mean the configuration is wrong; it means the feature has clear
interactive-only scope and a silent-degradation gap that operators should anticipate.

---

## Recommendation

This document declares the **Success Path** as **authoritative**.

The `extraKnownMarketplaces` field **does** trigger a consent/install prompt sequence when a
developer opens a project for the first time in interactive Claude Code. This behavior is
documented in the official settings reference and confirmed by community investigation.

**Template fork recommendation: include `.claude/settings.json` with these fields.**

The DSO NextJS Starter template should ship with a `.claude/settings.json` that declares:

```json
{
  "extraKnownMarketplaces": {
    "digital-service-orchestra": {
      "source": {
        "source": "github",
        "repo": "navapbc/digital-service-orchestra"
      }
    }
  },
  "enabledPlugins": {
    "digital-service-orchestra@digital-service-orchestra": true
  }
}
```

This delivers the onboarding goal: first-time users are guided through plugin installation
without needing to know about the installer script `create-dso-app.sh` or the plugin system
internals.

**Additional steps for a complete experience:**

1. **README callout**: Document that Claude Code will prompt to install the DSO marketplace on
   first launch; explain what to do if the prompt was skipped (run
   `/plugin marketplace add navapbc/digital-service-orchestra` then
   `/plugin install digital-service-orchestra@digital-service-orchestra`)
2. **CI guidance**: For teams running `claude -p` in CI, document the explicit install commands
   since the consent flow does not run in headless mode
3. **Trust re-trigger caveat**: If a developer has run `claude` in the project directory
   before the settings file was added, they may need to run the manual install; the trust event
   only fires once per directory

The recommendation does **not** depend on the silent auto-install feature requested in
Issue #23737 (not yet implemented). The consent-dialog path is sufficient for interactive
developer onboarding.
