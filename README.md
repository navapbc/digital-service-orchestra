# Digital Service Orchestra (DSO)

Digital Service Orchestra is a Claude Code plugin that coordinates AI agents to help teams plan, build, review, and ship software with consistent quality gates built in. It turns the Claude Code CLI into a guided multi-agent workflow that covers everything from turning a rough idea into a spec, through code review, to safely landing work on main.

DSO is designed for platform teams, internal tooling teams, and engineers working on multi-person codebases where consistent process matters. Rather than using a large language model in an ad-hoc way — asking it questions, copy-pasting answers — DSO gives teams a repeatable workflow with built-in checks at each stage. The result is that code gets reviewed with the same rigor every time, tests are tracked before and after changes, and nothing lands on main without passing the quality gates the team cares about.

Getting started is straightforward. Install DSO following the instructions in [INSTALL.md](INSTALL.md), then run `/dso:onboarding` from the Claude Code CLI. Onboarding asks a few questions about your project and sets up the configuration, hooks, and scaffolding needed for the full workflow. From there, `/dso:sprint` is the primary command for executing work tickets end-to-end.

## Highlights

- **Preplanning workflows** — turns rough epics into prioritized user stories with acceptance criteria
- **Code review gates** — tiered AI-assisted review (haiku for light, sonnet for standard, opus for deep) with security and performance overlays
- **Test status tracking** — TDD-enforced workflow; every change requires a failing test before the fix
- **Safe merges** — multi-phase merge-to-main with validation, version bumping, and CI status checks
- **Multi-agent orchestration** — parallel sub-agents with worktree isolation so large tasks don't block each other

For full installation and onboarding instructions, see [INSTALL.md](INSTALL.md).
