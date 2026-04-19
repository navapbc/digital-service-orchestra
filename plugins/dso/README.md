# DSO (Digital Service Orchestrator) Plugin

DSO is a Claude Code plugin that provides AI-assisted development workflows for government digital services teams.

## DSO NextJS Starter

A one-command bootstrap for non-engineer NextJS prototyping. The nextjs-starter installer sets up a complete DSO-configured NextJS project with all required infrastructure files.

**Quick start**: See [`docs/onboarding.md`](../../docs/onboarding.md) for the full bootstrap command.

To install the nextjs-starter scaffolding, run the `create-dso-app.sh` installer script from the `scripts/` directory, passing the desired project name as the first argument (e.g. `bash scripts/create-dso-app.sh my-project`). Running it without an argument performs a dependency check only.

## Features

- Sprint orchestration and task management
- TDD-driven implementation workflows
- Code review and quality gates
- Architecture enforcement

## Documentation

- **Installation**: See `INSTALL.md`
- **Configuration**: See `docs/CONFIGURATION-REFERENCE.md`
- **Worktree Guide**: See `docs/WORKTREE-GUIDE.md`
- **Ticket CLI Reference**: See `docs/ticket-cli-reference.md`
