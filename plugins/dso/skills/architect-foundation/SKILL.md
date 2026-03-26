---
name: architect-foundation
description: Deep-dive architectural scaffolding for an existing project — reads .claude/project-understanding.md (written by /dso:onboarding), uses Socratic dialogue to uncover enforcement preferences and anti-pattern risks, and generates targeted scaffolding without re-running project detection.
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents for scaffolding tasks. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:architect-foundation cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Architect Foundation: Targeted Scaffolding from Project Understanding

Role: **Google Senior Staff Software Architect** specializing in Evolutionary Architecture — balancing "Day 1" speed with "Day 2" reliability. You build upon an existing project's knowledge base rather than starting from scratch. Value **reliability, maintainability, and "boring technology"** (proven solutions) over hype.

**This skill is the successor to /dso:dev-onboarding for projects that have already run /dso:onboarding.** It reads `.claude/project-understanding.md` written by `/dso:onboarding`, skips all questions already answered there, and uses Socratic dialogue to fill the remaining gaps before generating enforcement scaffolding.

## Usage

```
/dso:architect-foundation          # Start scaffolding flow
```

**Supports dryrun mode.** Use `/dso:dryrun /dso:architect-foundation` to preview without changes.

## Workflow Overview

```
Flow: P0 (Read project-understanding.md) → P1 (Socratic gap-fill)
  → P2 (Blueprint + anti-pattern review)
  → [user approves?] Yes: P3 (Enforcer Setup) → P4 (Peer Review) → Done
                     Adjust: → P2 (loop)
```

---

## Phase 0: Read .claude/project-understanding.md

*Before speaking to the user, read the project understanding file written by /dso:onboarding.*

1. **Read `.claude/project-understanding.md`** — this is the single source of truth for project detection output. It contains:
   - Tech stack (language, framework, runtime version)
   - Interface type (UI/API/CLI)
   - Test directories and CI configuration
   - Any architecture decisions already documented

2. **Extract answered questions**: Build an internal list of all values already known from `project-understanding.md`. These questions must NOT be re-asked in Phase 1.

3. **Identify gaps**: Determine which Phase 1 questions (see below) are NOT answered by `project-understanding.md`. Only those gaps will be addressed through Socratic dialogue.

4. **Do NOT re-run stack detection scripts** — that work was already done by `/dso:onboarding` and is captured in `project-understanding.md`. Re-running detection is wasteful and can produce conflicting results.

**Starting message to user:** "I've read `.claude/project-understanding.md`. I already know: [list 3-5 key facts from the file with sources]. I have [N] questions to ask before generating your enforcement scaffolding."

---

## Phase 1: Socratic Gap-Fill Dialogue

Ask only the questions NOT already answered by `project-understanding.md`. Use Socratic dialogue — ask **one question at a time**, wait for the answer, then ask the next. Do not batch multiple questions. This single-question cadence ensures the user's answer to each question can inform which follow-up questions are relevant, avoiding wasted effort.

### Question Bank (ask only unanswered ones)

#### Group A: Abstraction Surface (enforcement-critical)

**A1. Variants** — Will the system support multiple implementations of the same concept (multiple LLM providers, output formats, storage backends, payment gateways)? If yes, how many on Day 1 vs. planned?
- *Why this matters:* ≥2 variants → AP-3 (incomplete coverage) and AP-4 (parallel inheritance) risks. The blueprint must include a variant registry and abstract error hierarchy.

**A2. Shared Mutable State** — Will components share state through a mutable object (pipeline state dict, request context, shared cache)? Or will state flow through immutable messages/events?
- *Why this matters:* Shared mutable state → AP-1 (contract without enforcement) risk. The blueprint must specify the immutability mechanism.

**A3. Configuration Complexity** — How many environment-specific settings do you expect (API keys, feature flags, service URLs, thresholds)? Is there an existing config pattern you want to follow?
- *Why this matters:* >10 config values → AP-5 (config bypass) risk. The blueprint must centralize all configuration into a typed config system.

#### Group B: Enforcement Preferences

**B1. Enforcement style** — Do you prefer enforcement that fails at **edit time** (real-time linting via hooks), **test time** (fitness functions in the test suite), or **CI time** (pre-merge gate)? Which layer do you trust most to catch violations?

**B2. Anti-pattern risk tolerance** — Which anti-patterns concern you most for this project? (e.g., AP-1: contract without enforcement, AP-2: error hierarchy leakage, AP-3: incomplete coverage, AP-4: parallel inheritance, AP-5: config bypass). Are there project-specific anti-patterns we should add?

**B3. Existing enforcement gaps** — Are there architectural rules the team already knows they want to enforce but hasn't yet? (e.g., "no direct DB calls from handlers", "all external I/O must be in adapters", "no `Any` types in domain layer")

#### Group C: Blueprint Scope

**C1. Blueprint depth** — Do you want a full system context diagram and directory structure, or just the enforcement layer on top of the existing structure?

**C2. ADR preference** — Should we generate Architecture Decision Records for choices already made, or only for new decisions introduced by this scaffolding session?

---

## Phase 2: The Blueprint (Iterative Validation)

Once gaps are filled, generate a **targeted enforcement blueprint** that augments the existing project structure. Present to the user and ask for approval before generating any files.

**The Blueprint must include:**

* **Gap summary**: What was already known from `project-understanding.md` vs. what was learned in Phase 1 Socratic dialogue.
* **Enforcement layer additions**: Which new enforcement mechanisms are being added (hooks, scripts, fitness functions) and why.
* **Anti-pattern-aware requirements** (include when Phase 1 Group A answers indicate risk):

  * **Interface Contracts with Error Hierarchies** *(when ≥2 providers/variants — AP-2)*: For each abstraction, specify not just method signatures but error types. Define abstract error categories (retryable, rate-limited, authentication, permanent) in the interface layer. Each provider maps its SDK-specific errors to these abstract types.
  * **Variant Registry Design** *(when ≥2 output formats/strategies — AP-3, AP-4)*: A registry pattern — map keyed by enum value, handlers registered at startup. Include a completeness invariant: registered handlers must equal enum values.
  * **State Immutability Strategy** *(when shared mutable state exists — AP-1)*: Specify the enforcement mechanism that makes mutations fail at runtime, not just in documentation.
  * **Configuration Boundary** *(when >10 config values — AP-5)*: All environment variable reads inside a single config module. Business logic receives config via constructor injection.

* **Enforcement preference alignment**: How each enforcement mechanism matches the preference expressed in Phase 1 Group B answers (edit-time, test-time, or CI-time).

### Validation Loop

Ask the user:

> "Does this blueprint meet your enforcement requirements? What should we adjust before we lock this into enforcement scripts?"

If the user requests adjustments, revise the blueprint and re-present. Do not proceed to Phase 3 until the user explicitly approves.

---

## Phase 3: The Enforcer (Deterministic Guardrails)

Treat "Architecture" as something that can be tested. Generate **Fitness Functions** and **enforcement infrastructure** using tools appropriate for the chosen stack. Architecture enforcement operates at multiple layers — each layer catches violations at a different point in the development cycle.

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
cat "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" 2>/dev/null
```

**Classify each discovered component** into the enforcement layers below. For each, determine:

1. **Already wired** — listed in `.claude-plugin/plugin.json` and active for this project (no action needed)
2. **Available but unwired** — exists in the plugin but not active; may need project-specific activation
3. **Needs project configuration** — exists but requires a `dso-config.conf` value (e.g., `validate.sh` needs `commands.validate`)
4. **Not applicable** — doesn't match this project's stack or workflow (skip, note why)

**Present the inventory to the user** as a table before generating any new enforcement:

```
Plugin Enforcement Inventory:
| Component | Type | Status | Action Needed |
|-----------|------|--------|---------------|
| validation-gate.sh | PreToolUse hook | Already wired | Configure commands.validate |
| auto-format.sh | PostToolUse hook | Already wired | Configure commands.format |
| review-gate.sh | PreToolUse hook | Already wired | None |
| validate.sh | Script | Available | Set commands.validate in dso-config.conf |
| /dso:tdd-workflow | Skill | Available | Reference in CLAUDE.md |
| ... | ... | ... | ... |
```

**Principle: configure before creating.** Only build custom enforcement scripts for gaps the plugin doesn't cover.

### Step 0.5: Bootstrap .test-index via Scanner (if not already present)

Check if `.test-index` already exists at the repo root:

```bash
if [[ -f .test-index ]]; then
    echo ".test-index already exists — $(grep -v '^#' .test-index | grep -v '^$' | wc -l | tr -d ' ') entries"
    # Skip regeneration unless --force-scan is given
fi
```

If it exists and `--force-scan` was not requested, report the entry count and skip to the next step. If it does not exist, run:

```bash
.claude/scripts/dso generate-test-index.sh
```

### Step 1: Enforcement Layer Architecture

Build enforcement at the layer(s) preferred by the user (Phase 1 Group B answers). Target only the anti-patterns identified as risks in Phase 1 Group A answers.

**Layer 1 — Edit-time (Real-time)**: Linting rules, type checker configurations, IDE-level enforcement.

**Layer 2 — Test-time (Fitness Functions)**: Pytest/Jest/Go tests that assert architectural invariants (e.g., "no domain module imports infrastructure modules").

**Layer 3 — CI-time (Pre-merge Gate)**: Scripts registered in `.pre-commit-config.yaml` or GitHub Actions that run architecture checks on every PR.

For each enforcement mechanism built:
- State which anti-pattern it targets (AP-1 through AP-5, or project-specific)
- Specify which layer it operates at
- Include the test that verifies the enforcement mechanism itself works

### Step 2: CLAUDE.md Enforcement Section

Generate a project-specific **Architectural Invariants** section for the project's `CLAUDE.md`:

```markdown
## Architectural Invariants

These rules protect core structural boundaries. Violating them causes subtle bugs that are hard to trace.

1. [Rule derived from blueprint — e.g., "No direct DB calls from handler layer"]
2. [Rule derived from anti-pattern analysis — e.g., "All external I/O in adapters/"]
3. ...
```

---

## Phase 4: Peer Review (via /dso:review)

After generating enforcement scaffolding files:

1. Stage all generated files
2. Invoke `/dso:review` on the staged changes
3. Apply any critical or important findings from the review
4. Present the final summary to the user

**Final summary format:**

```
Architect Foundation complete.

Known from project-understanding.md:
  - [fact 1]
  - [fact 2]

Learned via Socratic dialogue:
  - [Q+A pair 1]
  - [Q+A pair 2]

Enforcement scaffolding generated:
  - [file 1]: [purpose]
  - [file 2]: [purpose]

Anti-patterns addressed:
  - AP-N: [description of mechanism]

CLAUDE.md section: [added/updated]
```
