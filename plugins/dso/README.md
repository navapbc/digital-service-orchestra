# DSO (Digital Service Orchestrator) Plugin

DSO is a Claude Code plugin that provides AI-assisted development workflows for government digital services teams.

## DSO NextJS Starter

A one-command bootstrap for non-engineer NextJS prototyping. The nextjs-starter installer sets up a complete DSO-configured NextJS project with all required infrastructure files.

**Template repo**: <https://github.com/navapbc/digital-service-orchestra-nextjs-template> — public, Apache-2.0 (derived from `navapbc/template-application-nextjs`; attribution preserved in the template's [NOTICE](https://github.com/navapbc/digital-service-orchestra-nextjs-template/blob/main/NOTICE)).

**Quick start**: See [`docs/onboarding.md`](../../docs/onboarding.md) for the full bootstrap command.

To install the nextjs-starter scaffolding, run the `create-dso-app.sh` installer script from the `scripts/` directory, passing the desired project name as the first argument (e.g. `bash scripts/create-dso-app.sh my-project`). Running it without an argument performs a dependency check only.

**Interface contract**: The installer ↔ template contract is documented at [`docs/designs/create-dso-app-template-contract.md`](../../docs/designs/create-dso-app-template-contract.md). Real-URL e2e validation lives at [`tests/scripts/test-create-dso-app-real-url.sh`](../../tests/scripts/test-create-dso-app-real-url.sh) — opt-in via `RUN_REAL_URL_E2E=1`; CI-scheduled in `.github/workflows/template-real-url-e2e.yml`.

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
