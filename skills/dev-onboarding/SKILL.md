---
name: dev-onboarding
description: Architect a new project from scratch using a Google-style Design Doc interview, blueprint validation, enforcement scaffolding, and peer review
user-invocable: true
---

# Dev Onboarding: Evolutionary Architecture Setup

Role: **Google Senior Staff Software Architect** specializing in Evolutionary Architecture — balancing "Day 1" speed with "Day 2" reliability. Design systems that future AI agents can build upon without creating a "Big Ball of Mud." Value **reliability, maintainability, and "boring technology"** (proven solutions) over hype.

## Usage

```
/dev-onboarding          # Start the full onboarding flow
```

**Supports dryrun mode.** Use `/dryrun /dev-onboarding` to preview without changes.

## Workflow Overview

```
Flow: P0 (Audit) → P1 (Design Doc Interview) → P2 (Blueprint)
  → [user approves?] Yes: P3 (Enforcer Setup) → P4 (Peer Review) → Done
                     Adjust: → P2 (loop)
```

---

## Phase 0: The Architectural Audit (/dev-onboarding)

*Before speaking to the user, scan the current project context/files.*

1. **Scan for context files** in priority order:
   - **`QASP.md`** (Quality Assurance & Standards Plan): If found, extract interface type, tech stack, infrastructure targets, testing standards, accessibility requirements, and compliance constraints. This is the richest source of defaults.
   - **`package.json`**: Extract framework (dependencies like `next`, `express`, `react`), build tools, test runner, and Node version constraints.
   - **`pyproject.toml`** / **`requirements.txt`**: Extract Python version, framework (Flask, FastAPI, Django), and dependencies.
   - **`go.mod`**: Extract Go version and module dependencies.
   - **`Dockerfile`** / **`docker-compose.yaml`**: Extract infrastructure hints (base images, services, databases).
   - **`DESIGN_NOTES.md`**: If found, extract tech stack and UI library choices from the System Architecture section.

2. **Propose Defaults:** Based on files found above, pre-populate default answers for the Phase 1 interview questions. Present each default with its source (e.g., *"Stack: Python 3.13 + Flask (from pyproject.toml)"*). Do not guess; if no data exists for a question, leave it blank.

3. **Current State Summary:** Provide a 3-sentence summary of the existing architecture (or lack thereof).

**Starting Prompt to user:** "I have audited the current environment. [Insert Phase 0 results with sources]. Let's move to **Phase 1**: I've pre-filled defaults where I could — confirm or override each one."

---

## Phase 1: The Design Doc Interview (/dev-onboarding)

Engage the user in a dialogue to gather the constraints for a **Google-style Design Doc**. Ask these questions in small batches (2-3 at a time) using `AskUserQuestion` to manage cognitive load. Do not proceed until you have clarity.

### Group 1: The Product & Interface

1. **The Interface:** Will this be a UI-driven app (Web/Mobile), a CLI tool, or a headless API service?
2. **The User & Traffic:** Who is the user (Internal Ops vs. Public Consumer)? What is the expected scale (Requests Per Second)?

### Group 2: The Tech Stack & Constraints

3. **The Stack:** What is your preferred programming language and framework (e.g., Go/Gin, TS/Next.js, Python/FastAPI)?
4. **Frontend Blocks:** If a UI is needed, which library/design system should we use (e.g., Tailwind, Material UI, Shadcn, USWDS)?
5. **Infrastructure:** Where will this live (GCP, AWS, Vercel)? Do you have a preferred Database (SQL vs. NoSQL) or CI/CD provider (GitHub Actions, GitLab)?

---

## Phase 2: The Blueprint (Iterative Validation) (/dev-onboarding)

Once requirements are clear, generate a **"System Design Blueprint."** Present this to the user and ask for approval before generating any code.

**The Blueprint must include:**

* **System Context Diagram:** (Use `mermaid.js`) showing high-level boundaries and data flow.
* **Directory Structure:** A complete file tree following **Clean Architecture** (separating Domain, Application, and Infrastructure).
* **ADR 001 (Architecture Decision Record):** A document explaining *why* we chose this stack (e.g., "Why Postgres over Mongo?").
* **Standardization Guide:** Rules for Naming (e.g., `*Controller.ts`), Error Handling, and Logging standards.
* **Key Configuration Files:** Initial `Dockerfile`, `docker-compose.yaml`, and config files appropriate to the chosen stack (e.g., `tsconfig.json`, `pyproject.toml`).

### Validation Loop

Ask the user:

> "Does this blueprint meet your viability requirements? What should we adjust before we lock this into enforcement scripts?"

If the user requests adjustments, revise the blueprint and re-present. Do not proceed to Phase 3 until the user explicitly approves.

---

## Phase 3: The Enforcer (Deterministic Guardrails) (/dev-onboarding)

Treat "Architecture" as something that can be tested. Generate **Fitness Functions** and **enforcement infrastructure** using tools appropriate for the chosen stack. Architecture enforcement operates at multiple layers — each layer catches violations at a different point in the development cycle, from real-time editing to CI/CD.

### Step 0: Inventory Available Plugin Infrastructure

Before building enforcement from scratch, audit what the plugin already provides. Many enforcement mechanisms ship as plugin hooks, scripts, and skills that can be wired into the project with configuration alone.

**Scan the plugin directory** at `${CLAUDE_PLUGIN_ROOT}`:

```bash
# Discover available hooks (real-time enforcement)
ls "${CLAUDE_PLUGIN_ROOT}/hooks/"*.sh 2>/dev/null

# Discover available scripts (validation, CI, stack detection)
ls "${CLAUDE_PLUGIN_ROOT}/scripts/"*.sh 2>/dev/null

# Discover available skills (workflow enforcement)
ls "${CLAUDE_PLUGIN_ROOT}/skills/"*/SKILL.md 2>/dev/null

# Read the plugin's hook wiring to see what's already active
cat "${CLAUDE_PLUGIN_ROOT}/hooks.json" 2>/dev/null
```

**Classify each discovered component** into the enforcement layers below. For each, determine:

1. **Already wired** — listed in `hooks.json` and active for this project (no action needed)
2. **Available but unwired** — exists in the plugin but not in `hooks.json`; may need project-specific activation (e.g., adding to `.claude/settings.json` or `hooks.json`)
3. **Needs project configuration** — exists but requires a `workflow-config.yaml` value or environment variable (e.g., `validate.sh` needs a `commands.validate` entry; `auto-format.sh` needs the project's formatter command)
4. **Not applicable** — doesn't match this project's stack or workflow (skip, note why)

**Present the inventory to the user** as a table before generating any new enforcement:

```
Plugin Enforcement Inventory:
| Component | Type | Status | Action Needed |
|-----------|------|--------|---------------|
| validation-gate.sh | PreToolUse hook | Already wired | Configure commands.validate |
| auto-format.sh | PostToolUse hook | Already wired | Configure commands.format |
| cascade-circuit-breaker.sh | PreToolUse hook | Already wired | None |
| review-gate.sh | PreToolUse hook | Already wired | None |
| validate.sh | Script | Available | Set commands.validate in workflow-config.yaml |
| /tdd-workflow | Skill | Available | Reference in CLAUDE.md |
| /fix-cascade-recovery | Skill | Available | Referenced by circuit breaker |
| ... | ... | ... | ... |
```

**Principle: configure before creating.** Only build custom enforcement scripts for gaps the plugin doesn't cover. The plugin's hooks are designed to be stack-agnostic — they read commands from `workflow-config.yaml` via `read-config.sh` and work across Python, JS/TS, Go, Rust, and convention-based stacks.

### Layer 1: Architectural Invariants (Documentation as Enforcement)

Document the project's structural boundaries as explicit, testable rules in `CLAUDE.md` (or equivalent project config). These guide both human developers and AI agents. Use `/init` to create a `workflow-config.yaml` for the detected stack, then `/generate-claude-md` to scaffold the `CLAUDE.md` with generated sections (Quick Reference, Never Do These, Always Do These). Add project-specific architectural invariants in the preserved sections.

Each invariant should name:

- **The boundary**: What is being protected (e.g., "All LLM calls route through the factory")
- **The consequence of violation**: Why this boundary exists (e.g., "bypassing the factory breaks mock injection and provider switching")
- **The pattern to follow**: The correct way to accomplish the goal

Common invariant categories (language-agnostic):

| Category | Example | Enforcement Target |
|----------|---------|-------------------|
| **Factory/Gateway patterns** | All external service calls route through a single factory or gateway | Prevents scattered integration points that break mocking, switching, and monitoring |
| **Service layer boundaries** | Business logic queries go through a service layer, not direct DB access | Prevents bypassing business rules, caching, and event hooks |
| **Route/endpoint registration** | All routes registered via a module system (blueprints, routers, controllers) | Prevents orphaned endpoints that miss middleware, auth, and logging |
| **Configuration centralization** | All config reads go through a typed config system, not raw env vars | Prevents type errors, missing validation, and inconsistent defaults |
| **State boundaries** | Pipeline/workflow components use a shared state object, not instance variables | Prevents retry and checkpointing bugs |
| **Write ordering** | Read-only validations precede all irreversible side effects | Prevents partial failures that leave inconsistent state |
| **DB write restrictions** | Only designated components write to the database; intermediary steps do not | Prevents race conditions with retry logic and inconsistent state |
| **Dependency policy** | Prefer stdlib/existing dependencies; new runtime deps require justification | Prevents dependency bloat and supply chain risk |

### Layer 2: Real-Time Enforcement (Pre-Action Hooks)

Configure hooks that fire **before** an action executes and can **block** it. These are the fastest feedback loop — violations are caught before they happen, not after.

**Plugin-provided hooks** (check Step 0 inventory — these may already be wired):

| Hook | Gate Type | What it blocks |
|------|-----------|---------------|
| `validation-gate.sh` | **Validation Gate** | Blocks new work when codebase is unhealthy. Three-state model: `not_run` → hard block; `failed` → warn on edits, block new work; `passed` → allow all. Reads `commands.validate` from `workflow-config.yaml` |
| `review-gate.sh` | **Review Gate** | Blocks commits without code review. Computes diff hash; stale reviews are rejected. Exempts WIP and emergency saves |
| `cascade-circuit-breaker.sh` | **Circuit Breaker** | Blocks edits after N consecutive failures. Paired with `track-cascade-failures.sh` (PostToolUse). Forces `/fix-cascade-recovery` skill |
| `worktree-edit-guard.sh` | **Boundary Guard** | Blocks cross-worktree file edits |
| `bug-close-guard.sh` | **Boundary Guard** | Blocks closing bugs without a code change |
| `plan-review-gate.sh` | **Review Gate** | Blocks ExitPlanMode without `/plan-review` |
| `review-integrity-guard.sh` | **Integrity Guard** | Blocks fabrication of review artifacts |

If any of these are listed in `hooks.json` but need project-specific configuration (e.g., `validation-gate.sh` needs `commands.validate`), configure them via `workflow-config.yaml` or `/init`.

**Project-specific hooks to add** (only if gaps remain after plugin inventory):

- **Boundary guards** for project-specific constraints (e.g., "services cannot import from controllers," "only designated components write to DB")
- **Protected file guards** for files that should require human approval before modification

**Implementation patterns** (language-agnostic):

| Platform | Pre-action hooks |
|----------|-----------------|
| Git | `pre-commit` hooks (lint, format, security scan, import cycles) |
| AI coding tools | `PreToolUse` hooks on Edit/Write/Bash (Claude Code, Cursor, etc.) — see `hooks.json` |
| CI/CD | Required status checks, branch protection rules |
| Build systems | Pre-build validation tasks (Gradle, Make, Turborepo) |
| Editor/IDE | Save-time linting, error squiggles, format-on-save |

**Design principles for hooks:**

- **Fail safe**: Unexpected errors in the hook should exit cleanly (allow the action), not block the developer. Log errors for diagnosis. The plugin's `run-hook.sh` wrapper enforces this — route all hooks through it.
- **Passthrough exceptions**: Infrastructure files (config, docs, temp files) should be exempt from most gates so developers can always fix problems.
- **State file model**: Gates read from a state file (e.g., `/tmp/project-state/status`) written by validation runs. This decouples "when validation ran" from "when the gate checks."
- **Explicit timeout**: Every hook should have a documented timeout to prevent hanging the development loop.

### Layer 3: Reactive Enforcement (Post-Action Hooks)

Configure hooks that fire **after** an action completes. These don't block but maintain invariants automatically.

**Plugin-provided hooks** (check Step 0 inventory):

| Hook | Purpose | Trigger |
|------|---------|---------|
| `auto-format.sh` | Reformat code after edits. Reads `commands.format` from `workflow-config.yaml` | PostToolUse on Edit |
| `track-cascade-failures.sh` | Count consecutive failures to feed the circuit breaker | PostToolUse on Bash |
| `check-validation-failures.sh` | Detect test/lint failures in Bash output | PostToolUse on Bash |
| `track-tool-errors.sh` | Log tool errors for pattern analysis | PostToolUseFailure |
| `tool-logging.sh` | JSONL logging of all tool calls for session analysis | PostToolUse (all) |

**Project-specific hooks to add** (only if gaps remain):

- **Sync/propagation** — Automatically sync shared state (tickets, config) across workspaces or branches
- **Domain-specific post-processing** — e.g., regenerate API clients after schema changes, rebuild indexes after migration

### Layer 4: Commit-Time Enforcement (Pre-commit Hooks)

Configure a pre-commit framework appropriate to the stack. Each hook should have:

- **An explicit timeout** (prevents CI/local hangs)
- **A debug command** (developers can run the check manually to diagnose)
- **Scoped file triggers** (only run when relevant files change)

**Standard hooks to consider:**

| Hook | Purpose | Example tools |
|------|---------|---------------|
| Format check | Style consistency | Ruff, Prettier, gofmt, rustfmt |
| Lint | Code quality | Ruff, ESLint, golangci-lint, Clippy |
| Type check | Type safety | mypy, TypeScript `tsc`, Flow |
| Security scan | Vulnerability detection | Bandit, npm audit, gosec, cargo-audit |
| Import cycle detection | Dependency hygiene | import-linter, madge, circular-dependency-plugin |
| Lock file validation | Dependency integrity | `poetry check --lock`, `npm ci --dry-run` |
| Test marker validation | Test organization | pytest marker checks, Jest tag validation |
| Assertion density | Test quality | Custom scripts ensuring minimum assertions per test |
| Persistence coverage | DB correctness | Custom scripts ensuring write paths have round-trip tests |
| Migration consistency | Schema safety | Alembic head checks, Prisma drift detection |

### Layer 5: Dependency Boundary Rules

Install and configure tools to enforce import/dependency direction:

| Stack | Tool | Rule Example |
|-------|------|-------------|
| JS/TS | `dependency-cruiser`, `eslint-plugin-import` | "Domain cannot import Infrastructure" |
| Java/Kotlin | `ArchUnit` | "Services cannot depend on Controllers" |
| Python | `import-linter` | "Core cannot import from adapters" |
| Go | `depguard`, custom `go vet` analyzers | "Internal packages cannot import external HTTP" |
| Rust | `cargo-deny`, visibility rules | Crate-level pub/private boundaries |
| .NET | `NDepend`, `ArchUnitNET` | Assembly-level dependency constraints |

### Layer 6: CI Pipeline Enforcement

The final enforcement layer. CI should run the full suite that pre-commit hooks sample:

- Full test suite (unit, integration, E2E)
- Full lint and type checking
- Security scanning
- Visual regression (for UI projects)
- Required status checks that block merge

### Output

Generate the following artifacts, leveraging plugin infrastructure where available:

1. **`workflow-config.yaml`** — via `/init`; configures plugin hooks with project-specific commands (test, lint, format, validate)
2. **`CLAUDE.md`** — via `/generate-claude-md` for generated sections; add project-specific architectural invariants (boundary rules with consequences) in the preserved sections
3. **Pre-commit configuration** — `.pre-commit-config.yaml` or equivalent with timeouts and debug commands
4. **Project-specific hook scripts** — only for enforcement gaps not covered by plugin hooks (custom boundary guards, domain-specific gates)
5. **`ARCH_ENFORCEMENT.md`** — document explaining all enforcement layers (plugin-provided and project-specific), how to run each check manually, and how to add new rules. Reference plugin skills by name (e.g., "`/tdd-workflow` for bug fixes," "`/fix-cascade-recovery` when circuit breaker triggers," "`/verification-before-completion` before claiming work is done")
6. **CI configuration** — pipeline that runs the full enforcement suite

---

## Phase 4: Peer Review (/dev-onboarding)

Read [docs/review-criteria.md](docs/review-criteria.md) for full reviewer configuration, score aggregation rules, conflict detection guidance, and revision protocol.

Invoke `/review-protocol` to critique the generated architecture:

- **subject**: "Architecture Blueprint for {project name}"
- **artifact**: The full blueprint from Phase 2 (tech stack, API design, data model, deployment) AND the Phase 3 enforcement infrastructure (plugin inventory, architectural invariants, pre-commit config, hook wiring, CI config)
- **pass_threshold**: 4
- **start_stage**: 1 (include mental pre-review)
- **perspectives** (reviewer prompt files):
  - [docs/reviewers/failure-modes.md](docs/reviewers/failure-modes.md) — perspective: `"Failure Modes"`
  - [docs/reviewers/hardening.md](docs/reviewers/hardening.md) — perspective: `"Hardening"`
  - [docs/reviewers/scalability.md](docs/reviewers/scalability.md) — perspective: `"Scalability"`

After the review, present findings to the user. Once the user approves, output the final "Repository Skeleton."

---

## Goal

Produce a repository that is "Secure and Scalable by Default," allowing future agents to execute stories without manual architectural oversight.
