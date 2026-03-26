# digital-service-orchestra

Workflow infrastructure plugin for Claude Code projects — TDD-driven sprint management, review gates, hook parameterization, and multi-stack config.

## Installation

```bash
claude plugin install github:navapbc/digital-service-orchestra
```

## Setup

After cloning the repo, install the pre-commit hooks so the review gate is active:

```bash
pip install pre-commit   # or: brew install pre-commit
pre-commit install       # installs hooks from .pre-commit-config.yaml
```

## Requirements

### External Dependencies

- **`ticket`** (built-in) — Event-sourced ticket management CLI for issue tracking workflows. Installed via `.claude/scripts/dso ticket <subcommand>`. No external dependency required.

## Configuration

After installation, create a `workflow-config.conf` file at the root of your project using the flat `KEY=VALUE` format. For the full list of supported keys and their types, see [`docs/workflow-config-schema.json`](docs/workflow-config-schema.json).

Example minimal configuration:

```
paths.app_dir=app
ci.workflow_name=ci.yml
```

See [`docs/CONFIG-RESOLUTION.md`](docs/CONFIG-RESOLUTION.md) for resolution order and defaults.

## What's Included

- **Skills** — Sprint management (`/dso:sprint`), bug fixes (`/dso:fix-bug`), TDD for new features (`/dso:tdd-workflow`), review gates (`/review`, `/commit`), plan review (`/dso:plan-review`), and more.
- **Hooks** — Pre-commit review gate (two-layer defense), post-tool formatting, validation gate.
- **Scripts** — Ticket CLI, CI status polling, worktree utilities, merge-to-main orchestration.
- **Docs** — Workflow guides, architecture decisions, incident templates, and onboarding materials.

## Parent Project

This plugin was developed as part of [lockpick-doc-to-logic](https://github.com/navapbc/lockpick-doc-to-logic).
