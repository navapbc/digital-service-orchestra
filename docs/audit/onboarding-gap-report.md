# Onboarding Gap Report

**Audit date**: 2026-04-16
**Sprint**: 91f5-0aec
**Scope**: Retrospective audit of onboarding artifact state BEFORE Batches 2-3 remediation work landed.

---

## Target: root README.md

### Pre-sprint state

Before this sprint, the root `README.md` contained only the content introduced at commit `2afd3100 init` — a bare-minimum stub — later supplemented by an ast-grep install block added at `8d26b20c`. The file lacked:

- Any plain-language description of what DSO is or who it is for
- A link to `INSTALL.md` or any onboarding entry point
- Installation prerequisites or quick-start guidance

The content regression is visible in the commit history:

```
f3c565e1 feat(91f5-0aec): Batch 3 — scan-config-keys + path migration + Integration Setup
4a5276f5 feat(91f5-0aec): Batch 2 — INSTALL.md + 3 RED tests + path updates
8d26b20c docs(dafa-b1fe): add ast-grep structural code search guidance to CLAUDE.md and README
2afd3100 init
54b69188 fix: remove 6 remaining v2 ticket system references missed by epic sweep (2066-89e2)
8de98211 feat(dso-tmmj): batch 21 GREEN — w21-6fir docs update (dso:fix-bug references)
9a5ed734 fix: use non-deprecated pre-commit stage names and add setup docs
34e993e6 feat: complete plugin extraction — rename to dso, update all paths and references
14693273 fix: update GitHub org to navapbc and fix swapped plugin variables
70233046 feat: add README.md and .gitignore for digital-service-orchestra standalone repo (pgvb)
```

Commit `2afd3100 init` reduced the README to an `init` stub. Commit `8d26b20c` later appended an ast-grep install block, but neither commit addressed the missing product description or install pointer.

### Remediation

A minimal rewrite — title + pointer to `INSTALL.md` — landed in **Batch 3** via task **03b9-bd2d**.

**Gap status: CLOSED**

---

## Target: plugins/dso/docs/INSTALL.md

### Pre-sprint state

The plugin-internal `INSTALL.md` (formerly at `plugins/dso/docs/INSTALL.md`) had the following documented gaps:

1. **Git-clone-era install path** — instructions assumed direct `git clone` installation, which has been superseded by the `/plugin marketplace` install mechanism.
2. **`$CLAUDE_PLUGIN_ROOT` in copy commands** — `cp` commands referenced `$CLAUDE_PLUGIN_ROOT`, a variable frequently unset in consumer installs, causing silent failures.
3. **Missing marketplace slash-command instructions** — no mention of `/plugin marketplace add` or `/plugin install` syntax.
4. **No blocking-prerequisite callout** — no explicit notice that bash >= 4.0 and GNU coreutils are required on macOS (macOS ships bash 3.2 and BSD coreutils by default).
5. **No Integration Setup section** — Jira, Figma, and Confluence environment variables (`JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`, `FIGMA_PAT`, etc.) were undocumented.
6. **Buried location** — placing install instructions inside `plugins/dso/docs/` rather than at the repo root made the file hard to find for new consumers.

### Remediation

- **Batch 2 (task 93d2-cd41)**: New root-level `INSTALL.md` created with marketplace install instructions and Optional Plugins section migrated.
- **Batch 3 (task fe56-8919)**: Old `plugins/dso/docs/INSTALL.md` deleted.
- **Batch 3 (task ca62-8442)**: Integration Setup section (Jira/Figma/Confluence env vars) added to root `INSTALL.md`.

**Gap status: CLOSED**

---

## Target: plugins/dso/docs/CONFIGURATION-REFERENCE.md

### Pre-sprint state

The `CONFIGURATION-REFERENCE.md` was missing documentation for the following key namespaces, identified before the audit:

| Missing Key | Description |
|---|---|
| `brainstorm.enforce_entry_gate` | Gate enforcement toggle for brainstorm entry |
| `sprint.max_replan_cycles` | Maximum replanning cycles before escalation |
| `test_gate.*` | Test gate configuration (batch threshold, centrality threshold) |
| `test_quality.*` | Test quality gate settings (enabled, tool) |
| `worktree.isolation_enabled` | Worktree isolation toggle for sub-agents |
| `orchestration.max_agents` | Agent concurrency cap |
| `design.figma_collaboration` | Figma collaboration feature toggle |
| `bug_report.title_warning_enabled` | Bug report title warning toggle |
| `ticket_clarity.threshold` | Ticket clarity scoring threshold |
| `clarity_check.pass_threshold` | Clarity check pass threshold |

The `scan-config-keys.sh` tool, implemented in **Batch 3 (task b1d7-c727)**, now provides ongoing visibility into which config keys used in plugin scripts lack corresponding documentation entries. See Section 5 (Config Key Gap List) for its current output as of 2026-04-16.

### Remediation

Documentation updates for the identified missing keys are scoped to story **b2ec-ddb9**, which has not yet been executed.

**Gap status: PARTIALLY CLOSED** — `scan-config-keys.sh` tooling landed (Batch 3); documentation content updates are pending (b2ec-ddb9).

---

## Command Verification Appendix

### (a) Shell-command execution transcript

Commands run from the session worktree on 2026-04-16:

**`bash --version`**
```
GNU bash, version 5.3.9(1)-release (aarch64-apple-darwin25.1.0)
Copyright (C) 2025 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>

This is free software; you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
```
Exit code: 0. Note: this machine has GNU bash 5.3 installed (via Homebrew). macOS default (`/bin/bash`) ships bash 3.2, which does not meet the >= 4.0 prerequisite documented in INSTALL.md.

**`command -v brew`**
```
/opt/homebrew/bin/brew
```
Exit code: 0. Homebrew is present at the standard Apple Silicon path.

**`command -v coreutils || ls /opt/homebrew/opt/coreutils 2>/dev/null`**
```
AUTHORS
bin
ChangeLog
COPYING
INSTALL_RECEIPT.json
libexec
NEWS
README
sbom.spdx.json
share
TODO
```
Exit code: 0. GNU coreutils is installed via Homebrew at `/opt/homebrew/opt/coreutils`. `command -v coreutils` returned nothing (coreutils is not a single binary), but the package is installed.

**`command -v sg`**
```
/opt/homebrew/bin/sg
```
Exit code: 0. ast-grep binary (`sg`) is present.

### (b) /plugin marketplace syntax confirmation

The following install commands are documented at https://code.claude.com/docs/en/plugin-marketplaces:

```
/plugin marketplace add navapbc/digital-service-orchestra
/plugin install dso@digital-service-orchestra
```

The current root `INSTALL.md` (lines 25-26 as verified via grep) contains exactly:

```
/plugin marketplace add navapbc/digital-service-orchestra
/plugin install dso@digital-service-orchestra
```

**SYNTAX MATCHES** — verified by direct grep of `INSTALL.md` against the documented canonical syntax.

---

## Config Key Gap List

Output of `_PLUGIN_GIT_PATH=plugins/dso bash plugins/dso/scripts/scan-config-keys.sh` run 2026-04-16:

```
brainstorm.enforce_entry_gate
brainstorm.max_feasibility_cycles
checkpoint.marker_file
clarity_check.pass_threshold
commands.lint_mypy
commands.lint_ruff
commands.syntax_check
design.figma_staleness_days
implementation_plan.approach_resolution
model.haiku
model.opus
model.sonnet
sprint.max_replan_cycles
suggestion.error_threshold
suggestion.timeout_threshold
test_gate.batch_threshold
test_gate.centrality_threshold
test_quality.enabled
test_quality.tool
worktree.isolation_enabled
```

These keys are referenced in plugin scripts but lack entries in `CONFIGURATION-REFERENCE.md` as of this date. Story b2ec-ddb9 covers adding documentation for these keys.

## Audit Status Summary

| Target | Gap Status |
|---|---|
| root README.md | CLOSED (Batch 3, task 03b9-bd2d) |
| plugins/dso/docs/INSTALL.md | CLOSED (Batch 2 task 93d2-cd41 + Batch 3 tasks fe56-8919, ca62-8442) |
| plugins/dso/docs/CONFIGURATION-REFERENCE.md | PARTIALLY CLOSED — tooling landed; doc updates pending (b2ec-ddb9) |
