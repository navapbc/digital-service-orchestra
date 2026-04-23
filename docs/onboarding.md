# DSO Onboarding

## Bootstrapping a New NextJS Project

Use the DSO NextJS Starter to scaffold a fully-configured project with one command. Pass your project name as the first argument:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/navapbc/digital-service-orchestra/HEAD/scripts/create-dso-app.sh) my-project
```

Running the installer without a project-name argument runs dep-check-only mode (verifies prerequisites and exits). When the installer is invoked interactively (a terminal is available) without an argument, it will prompt you for a project name.

## What the installer does

1. Checks and installs required dependencies (Homebrew, Node 20.x, pre-commit, Claude Code)
2. Clones the DSO NextJS template repository at <https://github.com/navapbc/digital-service-orchestra-nextjs-template> (public, Apache-2.0; see its [NOTICE](https://github.com/navapbc/digital-service-orchestra-nextjs-template/blob/main/NOTICE) for upstream attribution)
3. Substitutes your project name (the `{{PROJECT_NAME}}` placeholder) throughout the template
4. Installs npm dependencies
5. Launches Claude Code with DSO pre-configured (run `/dso:roadmap` as your first command to start a backlog)

The installer ↔ template interface is documented at [`docs/designs/create-dso-app-template-contract.md`](designs/create-dso-app-template-contract.md). Real-URL end-to-end validation runs daily in CI via `.github/workflows/template-real-url-e2e.yml`.

## Prerequisites

- macOS with internet access
- Homebrew will be installed if not present
