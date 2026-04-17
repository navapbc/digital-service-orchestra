# DSO Onboarding

## Bootstrapping a New NextJS Project

Use the DSO NextJS Starter to scaffold a fully-configured project with one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/navapbc/digital-service-orchestra/HEAD/plugins/dso/scripts/create-dso-app.sh)
```

## What the installer does

1. Checks and installs required dependencies (Homebrew, Node 20.x, pre-commit, Claude Code)
2. Clones the DSO NextJS template repository
3. Substitutes your project name throughout the template
4. Installs npm dependencies
5. Launches Claude Code with DSO pre-configured

## Prerequisites

- macOS with internet access
- Homebrew will be installed if not present
