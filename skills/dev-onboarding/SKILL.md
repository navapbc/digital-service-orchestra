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

### Group 3: The Abstraction Surface

These questions identify which anti-patterns (see Phase 3, Step 1) will apply to this project. Ask them after the stack is established, as the answers shape the blueprint's interface contracts and enforcement requirements.

6. **Variants:** Will the system support multiple implementations of the same concept — e.g., multiple LLM providers, output formats, storage backends, payment gateways? If yes, how many on Day 1 vs. planned?
   - *Why this matters:* ≥2 variants → AP-3 (incomplete coverage) and AP-4 (parallel inheritance) risks. ≥2 providers of the same service → AP-2 (error hierarchy leakage) risk. The blueprint must include a variant registry and abstract error hierarchy.
7. **Shared Mutable State:** Will components share state through a mutable object — e.g., a pipeline state dict, a request context, a shared cache? Or will state flow through immutable messages/events?
   - *Why this matters:* Shared mutable state → AP-1 (contract without enforcement) risk. The blueprint must specify the immutability mechanism (frozen types, proxy wrappers, event sourcing).
8. **Configuration Complexity:** How many environment-specific settings do you expect (API keys, feature flags, service URLs, thresholds)? Is there an existing config pattern you want to follow?
   - *Why this matters:* >10 config values → AP-5 (config bypass) risk. The blueprint must centralize all configuration into a typed config system from Day 1, before business logic is written.

---

## Phase 2: The Blueprint (Iterative Validation) (/dev-onboarding)

Once requirements are clear, generate a **"System Design Blueprint."** Present this to the user and ask for approval before generating any code.

**The Blueprint must include:**

* **System Context Diagram:** (Use `mermaid.js`) showing high-level boundaries and data flow.
* **Directory Structure:** A complete file tree following **Clean Architecture** (separating Domain, Application, and Infrastructure).
* **ADR 001 (Architecture Decision Record):** A document explaining *why* we chose this stack (e.g., "Why Postgres over Mongo?").
* **Standardization Guide:** Rules for Naming (e.g., `*Controller.ts`), Error Handling, and Logging standards.
* **Key Configuration Files:** Initial `Dockerfile`, `docker-compose.yaml`, and config files appropriate to the chosen stack (e.g., `tsconfig.json`, `pyproject.toml`).

**Anti-pattern-aware blueprint requirements** (include when Group 3 answers indicate risk):

* **Interface Contracts with Error Hierarchies** *(when ≥2 providers/variants — AP-2)*: For each abstraction in the blueprint (e.g., a client interface for an external service), specify not just the method signatures but the error types. Define abstract error categories (retryable, rate-limited, authentication, permanent) in the interface layer. Each provider implementation maps its SDK-specific errors to these abstract types. Consumer code catches only the abstract types. Include this in the Standardization Guide. Use `WebSearch` to find the idiomatic error abstraction pattern for the chosen stack.
* **Variant Registry Design** *(when ≥2 output formats/strategies — AP-3, AP-4)*: Instead of scattered conditional chains, specify a registry pattern — a map keyed by an enum value, with handler implementations registered at startup. Include a completeness invariant: the set of registered handlers must equal the set of enum values. When ≥2 implementations share >30% logic, the directory structure must include a shared base type with abstract methods for variant-specific behavior. Use `WebSearch` to find the idiomatic registry/strategy pattern for the chosen stack.
* **State Immutability Strategy** *(when shared mutable state exists — AP-1)*: Specify the enforcement mechanism for state boundaries. The mechanism must make mutations fail at runtime, not just in documentation. Use `WebSearch` to find the chosen stack's idiomatic immutability enforcement (e.g., read-only wrappers, frozen types, persistent data structures, event sourcing).
* **Configuration Boundary** *(when >10 config values — AP-5)*: The blueprint must place all environment variable reads inside a single config module. Business logic receives config via constructor injection. The config module is the only file permitted to read from the environment. Include this boundary in the Standardization Guide so it's enforced from the first line of code.

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

### Step 1: Anti-Pattern Risk Assessment

Before designing enforcement rules, assess the blueprint for these **known architectural anti-patterns** — failure modes observed in production codebases where documentation existed but enforcement did not. Each anti-pattern maps to a specific enforcement mechanism. Flag any that apply to the blueprint and wire up the corresponding enforcement in the layers below.

#### AP-1: Documented Contracts Without Runtime Enforcement

**The pattern**: A base class docstring or ADR mandates an invariant (e.g., "never mutate the input state," "always return a new copy"), but nothing prevents violations at runtime. New implementations silently diverge because the contract lives in prose, not in code.

**Why it recurs**: Docstrings are invisible to linters. Code review catches some violations but not all — especially when the correct pattern is followed by *some* implementations (creating a false sense of compliance). Tests may exist but run only on the "happy path" implementations.

**Enforcement mechanisms** — use `WebSearch` to find the idiomatic implementation for the chosen stack:

| Mechanism | Goal | Properties |
|-----------|------|------------|
| **Runtime immutability wrapper** | Make mutations raise an error at the call site | Wraps shared state so direct field assignment throws. Must work at the boundary where state is passed to implementations. |
| **Frozen/readonly types** | Prevent mutation at the type level | Compiler or runtime enforces that instances cannot be modified after construction. |
| **Self-discovering architectural test** | Verify contract across all implementations automatically | Test dynamically discovers all implementations of the interface (e.g., via reflection, subclass walking, or module scanning) and asserts each one leaves input state unchanged. New implementations are covered without editing the test. |
| **Static analysis check** | Catch mutation patterns at commit time | Pre-commit check that scans implementation files for direct state assignment patterns. Must be scoped to the relevant file patterns for the project. |

**Rule of thumb**: If you document a contract in prose, you must also enforce it in code. A contract without enforcement is a suggestion.

#### AP-2: Abstraction Leakage in Error Hierarchies

**The pattern**: A system defines a provider-agnostic interface (e.g., `LLMClient`) but the error handling or retry logic catches *provider-specific* exception types. When a new provider is added, it wraps errors into a generic type that the retry logic doesn't recognize — silently degrading resilience.

**Why it recurs**: The first implementation and the abstraction are built together, so provider-specific types leak into the "generic" layer unnoticed. Each new provider wraps errors correctly into the generic type, but the *consumer* still catches the original provider's types.

**Enforcement mechanisms**:

| Mechanism | When | Goal |
|-----------|------|------|
| **Abstract error hierarchy** | Blueprint phase | Define error categories (retryable, rate-limited, auth, permanent) in the interface layer. Each provider maps its SDK-specific errors to these types. Consumer catches only abstract types. |
| **Provider-parity integration test** | CI | Test that injects a transient error from *each* provider and asserts retry occurs. Fails immediately when a new provider is added without retry support. Self-discovering: dynamically finds all registered providers. |
| **Import boundary rule** | Pre-commit | Provider SDK types must not appear outside the provider's own module. Use the stack's dependency boundary tool (see Layer 5) to enforce. |

**Rule of thumb**: If the abstraction layer defines a contract, the error hierarchy must be part of that contract — not an afterthought.

#### AP-3: Incomplete Variant Coverage (The Missing Switch Arm)

**The pattern**: A system supports N variants (output formats, providers, storage backends) via switch/match statements scattered across the codebase. A new variant is added and the "main" paths are updated, but secondary paths (conflict resolution, metadata display, error formatting) silently fall through to a default or no-op.

**Why it recurs**: Conditional chains on strings don't produce compiler/linter errors when a new case is missing. Enums help but only if *exhaustive matching* is enforced.

**Enforcement mechanisms**:

Use `WebSearch` to find how the chosen stack enforces exhaustive matching (e.g., compiler-enforced match, lint rules, `never`/`NoReturn` types in default branches):

| Mechanism | Goal | Properties |
|-----------|------|------------|
| **Exhaustive enum matching** | Every conditional on a variant type handles all values | Must produce a compile-time or lint-time error when a new enum value is added without a corresponding handler. Never use a silent default/fallthrough. |
| **Registry pattern** | Centralize variant dispatch | Map keyed by enum value with handlers registered at startup. A CI test asserts the set of registered handlers equals the set of enum values. Adding a value without a handler fails the test immediately. |
| **String-to-enum boundary** | Eliminate raw string comparisons in business logic | Parse strings into enum/union types at system boundaries (API input, config). Internal code uses only typed values — linters flag raw string comparisons. |
| **"Add a variant" integration test** | Verify all code paths handle every variant | For each variant value, assert that secondary code paths (not just the main path) produce a meaningful result, not a no-op or passthrough. |

**Rule of thumb**: Every conditional on a variant type must either use exhaustive matching or route through a registry with a completeness test.

#### AP-4: Parallel Inheritance Without Shared Abstraction

**The pattern**: Two or more implementations share 50%+ of their logic but have no common base class. Methods are copy-pasted and diverge over time. Bug fixes and improvements must be applied N times.

**Why it recurs**: The first implementation is written, then the second is created by copying and modifying. The shared logic isn't obvious until the third variant makes the duplication painful. By then, the implementations have diverged enough that extraction feels risky.

**Enforcement mechanisms**:

| Mechanism | When | Example |
|-----------|------|---------|
| **Duplication detection** | CI | `jscpd` (JS/TS/Python/Java), PMD CPD (Java), custom AST diff. Threshold: flag blocks >15 lines with >80% similarity. |
| **Blueprint-phase rule** | Phase 2 | When the blueprint specifies N≥2 implementations of the same concept, require a shared base class or trait in the directory structure. Abstract methods for variant-specific logic; shared methods for common logic. |
| **Code review checklist item** | Review | "If this PR adds a new implementation of an existing pattern, does it extend the shared base or does it duplicate?" |

**Rule of thumb**: Two implementations sharing >30% logic is a coincidence. Three is a missing abstraction. Design the base class when N=2.

#### AP-5: Configuration System Bypass

**The pattern**: A typed configuration system exists but business logic reads environment variables directly, bypassing it. The config system's validators, type coercion, and defaults are silently skipped. Tests can't override these values through the config mechanism.

**Why it recurs**: Direct env var reads are the path of least resistance — one line vs. adding a field to a config class, updating tests, and wiring the dependency. Infrastructure code (storage backends, SDK clients) is often written before the config system is fully established.

**Enforcement mechanisms**:

| Mechanism | Goal | Properties |
|-----------|------|------------|
| **Grep-based pre-commit hook** | Block direct environment reads in business logic | Scan source directories (excluding the config module and test fixtures) for the stack's env-read API. Use `WebSearch` to identify the specific API calls to block for the chosen stack. |
| **Import/dependency boundary rule** | Prevent env-read imports outside config layer | Use the stack's dependency boundary tool (see Layer 5) to restrict which modules may access environment APIs. |
| **Constructor injection** | Decouple business logic from config source | Config values are injected via constructor, not read at call time. SDK clients receive credentials as constructor args sourced from the config system. |

**Rule of thumb**: If you have a typed config system, any direct env var read outside the config layer is a bug, not a shortcut.

#### AP-6: Naming Collisions Across Sibling Modules

**The pattern**: Two interfaces or abstract types in the same package share the same name (e.g., two `Validator` interfaces with incompatible signatures). Any import is ambiguous, and refactoring tools can't distinguish them.

**Why it recurs**: The second interface is created during a refactoring that isn't completed. The old interface persists because existing implementations depend on it.

**Enforcement mechanisms**:

| Mechanism | When | Goal |
|-----------|------|------|
| **Naming convention in blueprint** | Phase 2 | Require interface/trait/protocol names to include their role (e.g., `SyntaxValidator`, `SemanticValidator`) — not bare generic names like `Validator`. |
| **Package/module export audit** | Pre-commit | If a package or module exports two types with the same name, the check fails. Use `WebSearch` to find the stack's module export analysis tool. |
| **Deprecation protocol** | Process | When replacing an interface, mark the old one deprecated with a removal target. CI warns on usage of deprecated types. Use the stack's built-in deprecation mechanism. |

**Rule of thumb**: If two things in the same package need the same name, they either do the same thing (consolidate) or they don't (rename).

---

#### Applying the Assessment

For each anti-pattern above, evaluate:

1. **Does the blueprint create conditions for this anti-pattern?** (e.g., multiple output formats → AP-3, AP-4; provider abstraction → AP-2; shared pipeline state → AP-1)
2. **If yes, which enforcement mechanism fits the stack?** Select from the tables above.
3. **Wire the enforcement into the appropriate layer below** (Layer 1 for invariant docs, Layer 2/3 for hooks, Layer 4 for pre-commit, Layer 5 for import rules, Layer 6 for CI).

Present the assessment to the user as a risk table:

```
Anti-Pattern Risk Assessment:
| Anti-Pattern | Applies? | Risk Level | Proposed Enforcement |
|-------------|----------|------------|---------------------|
| AP-1: Contract without enforcement | Yes — shared pipeline state | HIGH | Immutability wrapper + architectural test |
| AP-2: Error hierarchy leakage | Yes — multi-provider service | HIGH | Abstract error types + provider-parity test |
| AP-3: Missing switch arm | Yes — 3 output formats | MEDIUM | Registry pattern + completeness test |
| AP-4: Parallel inheritance | Yes — format-specific handlers | MEDIUM | Shared base type in blueprint |
| AP-5: Config bypass | Low — config system is new | LOW | Grep pre-commit hook |
| AP-6: Naming collision | Low — small package count | LOW | Naming convention rule |
```

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

### Layer 7: Foundational Architectural Tests

Generate **skeleton architectural tests** based on the Step 1 anti-pattern assessment. These tests are the first tests written — before any business logic — and they define the structural contracts that all future code must satisfy. They start by passing trivially (no implementations yet) and begin failing the moment a new implementation violates the contract.

**Generate tests for each applicable anti-pattern.** Name the test files using the project's test naming convention. Use `WebSearch` to find the stack's idiomatic mechanisms for reflection, subclass/implementation discovery, and AST scanning.

| Anti-Pattern | Test Name | What It Asserts |
|-------------|-----------|-----------------|
| **AP-1** | `test_state_immutability` | For each component that receives shared state: call the processing method, assert input state is unchanged after the call. Uses deep comparison or an immutability wrapper to detect mutations. **Must be self-discovering**: dynamically finds all implementations of the state-processing interface via reflection or module scanning. |
| **AP-2** | `test_provider_error_parity` | For each provider implementation: inject a transient error, assert the consumer's retry logic fires. Inject a permanent error, assert it surfaces without retry. **Must be self-discovering**: dynamically finds all registered providers so new providers are automatically covered. |
| **AP-3** | `test_variant_completeness` | For each variant registry: assert the set of registered handlers equals the full set of enum/union values. Fails immediately when a new variant value is added without a corresponding handler. |
| **AP-4** | `test_no_excessive_duplication` | (Optional — CI-level) Run the stack's duplication detection tool with a threshold. Or: assert all implementations of a concept extend the shared base type, not the root type directly. |
| **AP-5** | `test_no_env_var_bypass` | Scan source directories (excluding the config module) for direct environment variable reads using the stack's env-read API pattern. Fails if any business logic file reads env vars directly. |

**Design principles for architectural tests:**

- **Self-discovering**: Tests should dynamically find all implementations (e.g., walk subclasses, scan a registry, glob for files matching a pattern). This ensures new implementations are automatically covered without editing the test.
- **Fail on addition, not omission**: The test should break when someone *adds* a new implementation that violates the contract — not require someone to remember to add a test case.
- **Run fast**: These are structural assertions, not integration tests. They should run in <1 second and be part of the unit test suite.
- **First tests written**: Generate these as part of the initial repository skeleton, before any business logic. They define the shape of the codebase.

### Output

Generate the following artifacts, leveraging plugin infrastructure where available:

1. **`workflow-config.yaml`** — via `/init`; configures plugin hooks with project-specific commands (test, lint, format, validate)
2. **`CLAUDE.md`** — via `/generate-claude-md` for generated sections; add project-specific architectural invariants (boundary rules with consequences) in the preserved sections
3. **Pre-commit configuration** — `.pre-commit-config.yaml` or equivalent with timeouts and debug commands
4. **Project-specific hook scripts** — only for enforcement gaps not covered by plugin hooks (custom boundary guards, domain-specific gates)
5. **`ARCH_ENFORCEMENT.md`** — document explaining all enforcement layers (plugin-provided and project-specific), how to run each check manually, and how to add new rules. Reference plugin skills by name (e.g., "`/tdd-workflow` for bug fixes," "`/fix-cascade-recovery` when circuit breaker triggers," "`/verification-before-completion` before claiming work is done")
6. **CI configuration** — pipeline that runs the full enforcement suite
7. **Architectural test suite** — skeleton tests from Layer 7, placed in `tests/arch/` (or equivalent). These are generated based on the Step 1 anti-pattern assessment and the Phase 2 blueprint's interface contracts. They run as part of the unit test suite from Day 1.

---

## Phase 4: Peer Review (/dev-onboarding)

Read [docs/review-criteria.md](docs/review-criteria.md) for full reviewer configuration, score aggregation rules, conflict detection guidance, and revision protocol.

Invoke `/review-protocol` to critique the generated architecture:

- **subject**: "Architecture Blueprint for {project name}"
- **artifact**: The full blueprint from Phase 2 (tech stack, API design, data model, deployment, anti-pattern-aware requirements) AND the Phase 3 enforcement infrastructure (plugin inventory, anti-pattern risk assessment, architectural invariants, pre-commit config, hook wiring, architectural test suite, CI config)
- **pass_threshold**: 4
- **start_stage**: 1 (include mental pre-review)
- **perspectives** (reviewer prompt files):
  - [docs/reviewers/failure-modes.md](docs/reviewers/failure-modes.md) — perspective: `"Failure Modes"`
  - [docs/reviewers/hardening.md](docs/reviewers/hardening.md) — perspective: `"Hardening"`
  - [docs/reviewers/scalability.md](docs/reviewers/scalability.md) — perspective: `"Scalability"`

**Additional review criteria** (reviewers should evaluate alongside their perspective-specific criteria):

- **Enforcement coverage**: For each anti-pattern flagged in the Step 1 risk assessment, is there a corresponding enforcement mechanism (architectural test, hook, or CI check)? An identified risk without enforcement is an open vulnerability.
- **Self-discovering tests**: Do the Layer 7 architectural tests dynamically discover implementations, or do they enumerate them manually? Manual enumeration means new implementations can silently bypass the contract.
- **Error hierarchy completeness**: If the blueprint specifies multiple providers, does every provider map its errors to the abstract error types? Is there a parity test?
- **Day 2 variant addition**: Walk through adding a new variant (format, provider, backend). How many files need to change? Which tests would catch a missed file? If the answer is "none," the enforcement has a gap.

After the review, present findings to the user. Once the user approves, output the final "Repository Skeleton."

---

## Goal

Produce a repository that is "Secure and Scalable by Default," allowing future agents to execute stories without manual architectural oversight.
