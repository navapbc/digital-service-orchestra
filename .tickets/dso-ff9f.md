---
id: dso-ff9f
status: open
deps: [dso-bxd0]
links: []
created: 2026-03-18T04:36:58Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-igoj
---
# Expand dso-setup.sh: prerequisites, pre-commit hooks, example configs, optional deps, cross-platform

As an engineer setting up DSO, I want `dso-setup.sh` to handle all mechanical prerequisites so I don't encounter setup failures due to missing tools, unconfigured hooks, or absent example configs.

## Done Definition

- Script verifies prerequisites: Claude Code version, bash ≥4, GNU coreutils
- Script runs `pre-commit install` to register git hooks
- Script copies example configs (`.pre-commit-config.yaml`, `ci.yml`) when not already present in the target project
- Script detects optional deps (acli, PyYAML), offers non-blocking install prompts, and continues if declined
- Script provides environment variable guidance (CLAUDE_PLUGIN_ROOT, DSO_ROOT)
- Script is idempotent (safe to re-run without side effects)
- Script works on macOS, Linux, and WSL/Ubuntu
- **Exit code contract documented as a comment block at the top of the script**: 0=success, 1=fatal error (abort), 2=warnings-only (continue with caution)
- **Example `.pre-commit-config.yaml` includes the review-gate hook entry** — omitting it would silently leave new projects without the two-layer review gate

## Escalation Policy

**If at any point you lack high confidence in your understanding of the existing project setup — e.g., you are unsure whether a prerequisite check is correct for the target platform, whether an example config value is current, or how the script's output will be consumed by the skill (Story C) — stop and ask the user before implementing. Err on the side of guidance over assumption. Implementing the wrong setup scaffold is harder to undo than pausing to confirm.**

