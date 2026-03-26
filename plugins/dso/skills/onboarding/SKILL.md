---
name: onboarding
description: Use when starting a new project or joining an existing one — conducts a Socratic dialogue to build a shared understanding of the project's stack, commands, architecture, infrastructure, CI pipeline, design system, and enforcement preferences.
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires direct user interaction (prompts, confirmations, interactive choices). If you are running as a sub-agent dispatched via the Task tool, STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:onboarding cannot run in sub-agent context — it requires direct user interaction. Invoke this skill directly from the main session instead."

Do NOT proceed with any skill logic if you are running as a sub-agent.
</SUB-AGENT-GUARD>

# Onboarding: Socratic Project Understanding

Role: **Senior Engineering Lead** conducting a structured onboarding dialogue to build a shared mental model of the project before writing any code or running any automation.

**Goal:** Through a series of focused questions — one at a time — discover and record the project's key dimensions. At the end, offer to invoke `/dso:architect-foundation` to codify the findings into durable project artifacts.
<!-- REVIEW-DEFENSE: /dso:architect-foundation is created by story cc36-54a7 in epic 8fdd-a993.
     This forward reference is intentional — the offer is inert until the skill is created. -->

---

## Usage

```
/dso:onboarding          # Start a full onboarding session for the current project
```

---

## Understanding Areas Checklist

The onboarding session probes seven areas. Track your progress through each:

| # | Area | What to Discover |
|---|------|-----------------|
| 1 | **stack** | Languages, frameworks, runtime versions, package managers |
| 2 | **commands** | How to build, test, lint, format, and run the project locally |
| 3 | **architecture** | Module structure, service boundaries, data flow, key design patterns |
| 4 | **infrastructure** | Hosting, deployment targets, databases, external services, secrets management |
| 5 | **CI** | CI provider, pipeline stages, test gates, deployment triggers |
| 6 | **design** | UI framework, design system, visual tokens, accessibility targets |
| 7 | **enforcement** | Linting rules, commit hooks, review gates, code style policies |

---

## Phase 1: Auto-Detection (/dso:onboarding)

**Goal:** Pre-fill as many answers as possible before asking the user anything.

### Step 1: Run Project Detection

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

# Detect stack and test suites
DETECT_OUT=$(bash "$REPO_ROOT/.claude/scripts/dso project-detect.sh" "$REPO_ROOT" 2>/dev/null || echo "")
STACK_OUT=$(bash "$REPO_ROOT/.claude/scripts/dso detect-stack.sh" "$REPO_ROOT" 2>/dev/null || echo "unknown")
```

Run `project-detect.sh` to discover test suites, CI configuration, and project conventions. Note which understanding areas are already answered by the detection output so you can skip or confirm rather than ask from scratch.

### Step 2: Initialize Scratchpad

Create a temp scratchpad file to accumulate findings. Use append-only writes throughout the session to protect against context loss:

```bash
SCRATCHPAD=$(mktemp /tmp/onboarding-scratchpad-XXXXXX.md)
cat > "$SCRATCHPAD" <<EOF
# Onboarding Scratchpad — $(date)
## Auto-detected
Stack: $STACK_OUT
Detection output: $DETECT_OUT
EOF
```

After each user answer, append to the scratchpad:

```bash
echo "## $AREA_NAME" >> "$SCRATCHPAD"
echo "$USER_ANSWER" >> "$SCRATCHPAD"
```

### Step 3: Summarize What You Know

Before asking any questions, present a brief summary of what auto-detection found:

```
I've scanned the project and found:
- Stack: [detected stack or "unknown"]
- Test suites: [detected suites or "none detected"]
- CI: [detected CI config or "none detected"]

I'll ask about the areas where I need more context. This should take 5–10 minutes.
```

---

## Phase 2: Socratic Dialogue Loop (/dso:onboarding)

**Goal:** Fill gaps in the 7 understanding areas through focused, conversational questions.

### Dialogue Rules

**One question at a time** — never present multiple questions in a single message. Pick the most important unknown and ask about it.

**Prefer multiple-choice questions** over open-ended when possible — they're faster to answer and produce more consistent results.

**Skip confirmed areas** — if detection already answered an area with confidence, confirm briefly ("I see you're using pytest — is that the main test runner?") rather than asking from scratch.

**Use "Tell me more about..."** to go deeper when an answer is vague or incomplete.

### Question Guide by Area

Work through each area in the checklist order, but adapt based on what detection already found.

#### 1. stack

Ask about: primary language and version, framework (if any), package manager, runtime target.

Example question:
```
I detected this looks like a Python project. Which version are you targeting?
a) Python 3.11
b) Python 3.12
c) Python 3.13
d) Other (please specify)
```

#### 2. commands

Ask about: how to run tests, how to start the dev server, how to lint/format, any project-specific Makefile targets.

Example question:
```
How do you run the test suite locally?
a) make test
b) pytest / poetry run pytest
c) npm test / yarn test
d) Other (please describe)
```

#### 3. architecture

Ask about: top-level module layout, key service boundaries, any notable design patterns (event sourcing, CQRS, hexagonal, etc.), where the main entry point is.

Example question:
```
How would you describe the top-level structure?
a) Monolith — single deployable unit
b) Monorepo — multiple packages/services in one repo
c) Microservices — separate repos per service
d) Plugin architecture — core + extension plugins
```

#### 4. infrastructure

Ask about: where it runs (cloud provider, on-prem, local-only), databases used, external services or APIs it calls, how secrets are managed.

Example question:
```
Where does this project run in production?
a) AWS
b) GCP / Google Cloud
c) Azure
d) Local / self-hosted
e) No production deployment yet
```

#### 5. CI

Ask about: which CI provider, what gates must pass before merge, whether there are separate fast/slow test pipelines, deployment pipeline stages.

Example question:
```
Which CI system does this project use?
a) GitHub Actions
b) CircleCI
c) GitLab CI
d) Jenkins
e) No CI configured yet
```

#### 6. design

Ask about: whether there is a UI layer, which framework/library is used, any established design system, accessibility targets.

Example question:
```
Does this project have a UI/frontend layer?
a) Yes — web UI (ask follow-up about framework)
b) Yes — native/mobile UI
c) No — it's a backend service or CLI tool
```

#### 7. enforcement

Ask about: linting tools, commit message conventions, pre-commit hooks in use, code review requirements, test coverage policies.

Example question:
```
Which enforcement tools are active?
a) Pre-commit hooks (e.g., ruff, eslint, husky)
b) CI lint gate only
c) Code review required before merge
d) All of the above
e) None / minimal enforcement
```

### Phase 2 Gate

When all 7 areas have at least a basic answer recorded in the scratchpad, ask:

```
I now have a working model of the project across all 7 areas. Is there anything important I missed — any constraint, convention, or quirk that a new team member would need to know?
```

Wait for the user's response before proceeding to Phase 3.

---

## Phase 3: Completion (/dso:onboarding)

**Goal:** Summarize the findings and hand off to the next step.

### Step 1: Present Understanding Summary

Compile the scratchpad into a readable summary:

```
=== Project Understanding Summary ===

**Stack**: [language/version, framework, package manager]
**Commands**: [test command, lint command, dev server command]
**Architecture**: [brief description]
**Infrastructure**: [hosting, databases, external services]
**CI**: [provider, key gates]
**Design**: [UI framework/design system, or "backend-only"]
**Enforcement**: [hooks, lint tools, review requirements]

Any corrections before I finalize this?
```

Wait for the user to confirm or correct. Update the scratchpad with any corrections.

### Step 2: Offer /dso:architect-foundation

After the user confirms the summary:

```
I can now codify this understanding into durable project artifacts using /dso:architect-foundation. This will:
- Write or update ARCHITECTURE.md with the module map and key patterns
- Register test suites and commands in .claude/dso-config.conf
- Capture enforcement preferences and CI pipeline structure

Would you like me to invoke /dso:architect-foundation now?
```

If the user says yes, invoke:

```
Skill tool:
  skill: "dso:architect-foundation"
```

If the user says no or wants to continue manually, summarize what was learned and close the session.

---

## Guardrails

**One question at a time** — never ask multiple questions in a single message.

**Socratic, not interrogative** — frame questions as collaborative discovery, not a form to fill out.

**Ground in detection output** — always start from what `project-detect.sh` found; ask to confirm, not to re-discover from scratch.

**Append-only scratchpad** — never overwrite scratchpad entries; only append to preserve the conversation history.

**No code changes** — this skill is read-only; it discovers and records but does not modify project files (that is `/dso:architect-foundation`'s job).

---

## Quick Reference

| Phase | Goal | Key Activities |
|-------|------|---------------|
| 1: Auto-Detection | Pre-fill answers | Run project-detect.sh, initialize scratchpad temp file, summarize findings |
| 2: Socratic Dialogue | Fill gaps in 7 areas | One question at a time, multiple-choice preferred, skip confirmed areas |
| 3: Completion | Finalize and hand off | Present summary, get confirmation, offer /dso:architect-foundation |
