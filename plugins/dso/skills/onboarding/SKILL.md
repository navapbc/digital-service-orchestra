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

**Goal:** Pre-fill as many answers as possible by reading project files BEFORE asking the user anything.

### Step 1: Read Project Files for Auto-Detection

Before asking any questions, scan the project filesystem to gather facts:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

# 1. Detect stack and test suites via DSO scripts
DETECT_OUT=$(bash "$REPO_ROOT/.claude/scripts/dso project-detect.sh" "$REPO_ROOT" 2>/dev/null || echo "")
STACK_OUT=$(bash "$REPO_ROOT/.claude/scripts/dso detect-stack.sh" "$REPO_ROOT" 2>/dev/null || echo "unknown")

# 2. Read specific project files to fill understanding areas
# Node / JavaScript ecosystem
[ -f "$REPO_ROOT/package.json" ] && PACKAGE_JSON=$(cat "$REPO_ROOT/package.json" 2>/dev/null)
# Python ecosystem
[ -f "$REPO_ROOT/pyproject.toml" ] && PYPROJECT=$(cat "$REPO_ROOT/pyproject.toml" 2>/dev/null)

# 3. Detect pre-commit hooks
HUSKY_HOOK=""
[ -f "$REPO_ROOT/.husky/pre-commit" ] && HUSKY_HOOK=$(cat "$REPO_ROOT/.husky/pre-commit" 2>/dev/null)
[ -f "$REPO_ROOT/.pre-commit-config.yaml" ] && PRECOMMIT_CONFIG=$(cat "$REPO_ROOT/.pre-commit-config.yaml" 2>/dev/null)

# 4. Discover CI workflows — list actual filenames before asking about workflow names
CI_WORKFLOWS=""
if [ -d "$REPO_ROOT/.github/workflows" ]; then
    CI_WORKFLOWS=$(ls "$REPO_ROOT/.github/workflows"/*.yml "$REPO_ROOT/.github/workflows"/*.yaml 2>/dev/null | xargs -I{} basename {})
fi

# 5. Discover test directories
TEST_DIRS=""
for candidate in tests test spec __tests__ src/__tests__; do
    [ -d "$REPO_ROOT/$candidate" ] && TEST_DIRS="$TEST_DIRS $candidate"
done
TEST_DIRS="${TEST_DIRS# }"  # trim leading space
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
package.json: ${PACKAGE_JSON:+present}
pyproject.toml: ${PYPROJECT:+present}
.husky/ pre-commit hook: ${HUSKY_HOOK:+present}
CI workflow filenames: ${CI_WORKFLOWS:-none found}
Test directories: ${TEST_DIRS:-none found}
EOF
```

After each user answer, append to the scratchpad:

```bash
echo "## $AREA_NAME" >> "$SCRATCHPAD"
echo "$USER_ANSWER" >> "$SCRATCHPAD"
```

### Step 3: Present Detected Configuration for Confirmation

Before asking any questions, present what was found and ask the user to confirm or correct:

```
I've scanned the project and found:
- Stack: [detected stack or "unknown"]
- Test suites: [detected suites or "none detected"]
- Test directories: [TEST_DIRS or "none found"]
- CI workflow filenames: [CI_WORKFLOWS or "none found"]
- Pre-commit hooks: [.husky/ present / .pre-commit-config.yaml present / "none"]
- package.json: [present / not found]
- pyproject.toml: [present / not found]

Does this look right, or is anything missing?
```

Wait for the user to confirm or correct before continuing. Update the scratchpad with any corrections, then proceed to Phase 2 for areas still needing clarification.

---

## Phase 2: Socratic Dialogue Loop (/dso:onboarding)

**Goal:** Fill gaps in the 7 understanding areas through focused, conversational questions. Present detected configuration for confirmation rather than asking open-ended discovery questions.

### Dialogue Rules

**One question at a time** — never present multiple questions in a single message. Pick the most important unknown and ask about it.

**Confirmation over discovery** — when detection already answered an area, present the detected value and ask the user to confirm or correct it. Do not ask from scratch.

**Skip confirmed areas** — if detection already answered an area with confidence, confirm briefly ("I see you're using pytest — is that the main test runner?") rather than asking from scratch.

**Use "Tell me more about..."** to go deeper when an answer is vague or incomplete.

**No rigid menus** — use open-ended questions with natural follow-ups rather than lettered option lists. Ask what the user does, not which letter they pick.

### Question Guide by Area

Work through each area in the checklist order, but adapt based on what detection already found.

#### 1. stack

Ask about: primary language and version, framework (if any), package manager, runtime target.

If `package.json` was found, present the detected Node/JavaScript stack for confirmation:
```
I see a package.json — it looks like this is a [framework] project using Node [version]. Is that right? What version are you targeting, and is there anything about the runtime or package manager I should know?
```

If `pyproject.toml` was found, present the detected Python stack for confirmation:
```
I see a pyproject.toml — it looks like a Python project. What version are you targeting, and are you using poetry, pip, or something else?
```

For unknown stacks, ask openly:
```
What language and runtime is this project built on? And what's the primary framework or library, if any?
```

#### 2. commands

Ask about: how to run tests, how to start the dev server, how to lint/format, any project-specific Makefile targets.

Present detected test directories for confirmation:
```
I found these test directories: [TEST_DIRS]. How do you actually run the test suite — is there a make target, a script, or do you run the test runner directly?
```

#### 3. architecture

Ask about: top-level module layout, key service boundaries, any notable design patterns (event sourcing, CQRS, hexagonal, etc.), where the main entry point is.

Ask openly:
```
How would you describe the top-level structure of this project — is it a single deployable unit, a monorepo, or something else? What's the main entry point?
```

#### 4. infrastructure

Ask about: where it runs (cloud provider, on-prem, local-only), databases used, external services or APIs it calls, how secrets are managed.

Ask openly:
```
Where does this project run in production, and what external services or databases does it depend on? How are secrets managed?
```

#### 5. CI

List the actual `.github/workflows/*.yml` filenames discovered in Step 1. Use those filenames to confirm the CI workflow name rather than asking the user to type it from memory.

```
I found these workflow filenames: [CI_WORKFLOWS]. Which one is your primary CI gate — the one that runs on pull requests?
```

If no workflows were found:
```
I don't see any CI workflows yet. What CI system are you planning to use, if any?
```

#### 6. design

Ask about: whether there is a UI layer, which framework/library is used, any established design system, accessibility targets.

Ask openly:
```
Does this project have a UI or frontend layer? If so, what framework are you using and is there an established design system?
```

##### Design Questions: Conditional Activation (UI Projects Only)

**If the answer is "No" (CLI tool, library, infrastructure, or backend-only project):** skip the deep design questions below and record "backend-only / no UI" in the design area of the scratchpad. Do NOT ask vision, archetype, or visual language questions — they are irrelevant for non-UI projects.

**If the answer is "Yes" (project has a UI/frontend component):** continue with the following focused design questions, one at a time:

1. **Vision**: "In one sentence, what is the specific value this UI delivers to the user? (e.g., 'Reduces tax filing time by 50% for freelancers')"

2. **User archetypes**: "Describe 2–3 user archetypes — not just demographics, but behaviors. (e.g., 'The Panicked Auditor' who needs speed vs. 'The Relaxed Browser' who wants to explore)"

3. **Golden paths**: "What are the top 1–2 workflows that must be frictionless? Walk me through the steps."

4. **Anti-patterns**: "What should this UI explicitly avoid? (e.g., 'No pop-ups', 'No endless scrolling', 'No dark patterns')"

5. **Visual language**: "Describe the intended visual feel in 3 adjectives. (e.g., 'Trustworthy, Dense, Clinical' or 'Playful, Round, Airy')"

6. **Accessibility**: "What's your target accessibility standard — WCAG AA, WCAG AAA, or something else?"

After completing these design questions, append findings to the scratchpad under a `## Design (Extended)` section.

#### 7. enforcement

Ask about: linting tools, commit message conventions, pre-commit hooks in use, code review requirements, test coverage policies.

Present detected hooks for confirmation:
```
I see [.husky/pre-commit present / .pre-commit-config.yaml present / no hooks detected]. What enforcement tools are active — any linters, commit message conventions, or code review requirements a new contributor would need to know?
```

#### 8. Jira Bridge

Ask whether the project uses Jira and, if so, confirm the project key:

```
Does this project use Jira for issue tracking? If so, what's the Jira project key (e.g., "MYAPP" or "DSO")?
Note: credentials (JIRA_URL, JIRA_USER, JIRA_API_TOKEN) stay as environment variables — only the project key goes in config.
```

If the user provides a Jira project key, write `jira.project_key=<KEY>` to `.claude/dso-config.conf`. The Jira Bridge connects DSO to Jira via the `JIRA_URL` environment variable.

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

### Step 2: Write .claude/project-understanding.md

After the user confirms the summary (or provides corrections), write the findings to a structured, human-readable artifact using the Write tool. This file is the lasting record of everything the onboarding conversation learned.

**Attribution convention:**
- Mark each finding as `(detected)` when it came from `project-detect.sh` or automated discovery.
- Mark each finding as `(user-stated)` when it came from a direct user answer during the dialogue.

The file is **human-readable and editable** — the user can update it at any time without re-running onboarding.

Write `.claude/project-understanding.md` using this template:

```markdown
# Project Understanding
<!-- Generated by /dso:onboarding — human-readable and editable. Last updated: <date> -->

## Stack
- Language/runtime: <value> (detected|user-stated)
- Framework: <value> (detected|user-stated)
- Package manager: <value> (detected|user-stated)
- Runtime versions: <value> (detected|user-stated)

## Architecture
- Structure: <monolith|monorepo|microservices|plugin|other> (detected|user-stated)
- Module layout: <description> (user-stated)
- Key design patterns: <description> (user-stated)
- Entry point: <path or description> (detected|user-stated)

## Design Summary
- UI layer: <yes/no and description, or "backend-only"> (user-stated)
- UI framework: <value or "N/A"> (user-stated)
- Design system: <value or "none"> (user-stated)
- Accessibility targets: <value or "not specified"> (user-stated)

## Commands
- Test: <command> (detected|user-stated)
- Lint: <command> (detected|user-stated)
- Format: <command> (detected|user-stated)
- Dev server: <command or "N/A"> (user-stated)
- Build: <command or "N/A"> (detected|user-stated)

## Infrastructure
- Hosting: <provider or "local-only"> (user-stated)
- Databases: <list or "none"> (user-stated)
- External services: <list or "none"> (user-stated)
- Secrets management: <approach or "not specified"> (user-stated)

## CI
- Provider: <value or "none"> (detected|user-stated)
- Pipeline stages: <description> (user-stated)
- Test gates: <description> (detected|user-stated)
- Deployment triggers: <description or "not specified"> (user-stated)

## Enforcement
- Pre-commit hooks: <list or "none"> (detected|user-stated)
- Linting tools: <list> (detected|user-stated)
- Commit message convention: <description or "none"> (user-stated)
- Review requirements: <description or "none"> (user-stated)
- Test coverage policy: <description or "none"> (user-stated)

## Additional Notes
<!-- Anything the user flagged as important that doesn't fit above -->
<notes from Phase 2 Gate response, or "none">
```

Populate each field from the scratchpad. Use the appropriate `(detected)` or `(user-stated)` tag for each entry. Leave fields as "not specified" or "N/A" where the conversation produced no answer — do not fabricate.

### Step 2a: Write .claude/design-notes.md (UI Projects Only)

**Condition:** Only write this file if the design area conversation confirmed a UI/frontend layer. Skip this step entirely for CLI tools, libraries, and infrastructure projects.

Write `.claude/design-notes.md` as a lightweight companion to `.claude/project-understanding.md`, capturing the extended design findings from the conditional design questions:

```markdown
# Design Notes
<!-- Generated by /dso:onboarding — human-readable and editable. Last updated: <date> -->
<!-- For full design system specification, run /dso:onboarding -->

## Vision
<one-sentence value proposition, or "not specified">

## User Archetypes
<behavioral archetypes discovered in onboarding, or "not specified">

## Golden Paths
<top 1–2 frictionless workflows, or "not specified">

## Anti-Patterns (Do Not Do)
<explicit UI constraints, or "not specified">

## Visual Language
<3-adjective vibe description, or "not specified">

## Accessibility Target
<WCAG AA | WCAG AAA | not specified>

## UI Framework
<framework/library detected or user-stated, or "not specified">

## Design System
<established design system or "none">
```

This file is intentionally brief — it records what was learned during onboarding. For a full, structured design North Star document, offer to run `/dso:onboarding` separately.

### Step 2b: Generate dso-config.conf

After writing `.claude/project-understanding.md`, generate a starter `.claude/dso-config.conf` from the conversation findings. This file configures DSO for the host project.

#### Detect and Merge with Existing Config

Before writing any values, check whether a `.claude/dso-config.conf` already exists:

```bash
EXISTING_CONFIG="$REPO_ROOT/.claude/dso-config.conf"
if [ -f "$EXISTING_CONFIG" ]; then
    # Detect existing config — merge new keys, do NOT overwrite existing values
    EXISTING_CONTENT=$(cat "$EXISTING_CONFIG")
fi
```

If an existing dso-config.conf is found, merge the new keys into it rather than overwriting. Only add keys that are not already present. Existing config values take precedence — do not overwrite them unless the user explicitly confirms the new value.

#### Required Config Keys

Generate all of the following config keys (flat `KEY=VALUE` format). For each key that cannot be auto-detected, apply the fallback behavior described below.

**DSO plugin location** (required):
```
# Absolute path to the DSO plugin directory (resolved via realpath or git rev-parse)
dso.plugin_root=<absolute path — e.g., /Users/name/project/plugins/dso>
```

Resolve to an absolute path using `realpath` or `git rev-parse --show-toplevel` — never a relative path.

**Format settings** (detected from stack):
```
format.extensions=<e.g., .py or .ts,.js>
format.source_dirs=<e.g., src or app,lib>
```

Detect from `package.json` (TypeScript/JavaScript) or `pyproject.toml` (Python) if present.

**Test gate** (detected from test directory scan):
```
test_gate.test_dirs=<e.g., tests or test,spec>
```

Populate from the `$TEST_DIRS` variable discovered in Phase 1 auto-detection.

**Validate command** (composed from detected test/lint/format commands):
```
commands.validate=<e.g., make test || poetry run pytest || npm test>
```

Compose from the test and lint commands confirmed in the commands area of Phase 2.

**Tickets and checkpoints** (use documented defaults):
```
tickets.directory=.tickets-tracker
checkpoint.marker_file=.checkpoint-pending-rollback
```

**Behavioral patterns** (semicolon-delimited globs based on project structure):
```
# Semicolon-delimited glob patterns for review behavioral analysis
review.behavioral_patterns=<e.g., src/**/*.py;tests/**/*.py;*.sh>
```

Generate from the detected source and test directories. The value is semicolon-delimited — multiple glob patterns separated by `;` with no spaces around the semicolons.

**CI workflow name** (confirmed from actual workflow filenames):

Use the workflow filenames discovered in Phase 1 (`$CI_WORKFLOWS`) to confirm the `ci.workflow_name`. Present the actual filenames rather than asking the user to type a name from memory:
```
# CI workflow filename confirmation
ci.workflow_name=<filename confirmed from .github/workflows/ scan>
```

**Additional categories to populate**:

| Category | Keys to set | Source |
|----------|-------------|--------|
| `format` | `format.line_length`, `format.indent` | Enforcement answers |
| `ci` | `ci.workflow_name` | Confirmed from workflow filenames |
| `commands` | `commands.test`, `commands.lint`, `commands.format` | Commands area answers |
| `jira` | `jira.project_key` (if Jira integration desired) | User-stated |
| `design` | `design.system`, `design.tokens_path` | Design area answers |
| `tickets` | `tickets.prefix` | Derived from project name (see below) |
| `merge` | `merge.ci_workflow_name` | CI area answers |
| `version` | `version.file_path` | Detected or user-stated |
| `test` | `test.suite.<name>.command`, `test.suite.<name>.speed_class` | Commands + detection |

#### Fallback Behavior for Undetected Config

When a config key cannot be auto-detected and the user does not provide a value, apply this fallback priority:

1. **Prompt user** — ask one focused question to get the value
2. **Documented default** — if a well-known default exists (e.g., `tickets.directory=.tickets-tracker`), use it and note it was defaulted
3. **Omit with explanatory comment** — if no default is safe to assume, omit the key and add an explanatory comment in the config file:

```
# commands.validate — could not be auto-detected; set to your validation command
# Example: commands.validate=make test
```

Never silently skip a required key — always leave a comment so the user knows what to fill in.

#### Ticket prefix derivation

Derive the `tickets.prefix` from the project name by taking the first letter of each hyphen- or underscore-separated word and uppercasing them. For example:

- `my-app` → `MA`
- `digital-service-orchestra` → `DSO`
- `myapp` (single word) → first 2–3 characters uppercased → `MYA`

Confirm the derived prefix with the user before writing it to config:

```
I'll use ticket prefix "MA" for this project (derived from "my-app").
Does that work, or would you prefer a different prefix?
```

#### CI workflow examples

When the conversation reveals **no `.github/workflows/` files exist**, offer example workflow templates before prompting for workflow names:

```
I don't see any CI workflows yet. Would you like me to create starter workflows?
I can generate:
- ci.yml — fast-gate tests on pull requests
- ci-slow.yml — slow/integration tests on push to main
- both, or skip if you plan to set up CI manually

Accepted examples will be auto-populated into dso-config.conf and generated
via ci-generator.sh using the test suites discovered during onboarding.
```

If the user accepts, invoke `ci-generator.sh` via the detected test suite list from `project-detect.sh` — do not prompt for workflow names separately.

#### ACLI_VERSION auto-suggestion

When the project uses Claude Code (Claude CLI / `acli`), suggest the current version and checksum automatically by running:

```bash
bash "$REPO_ROOT/.claude/scripts/dso" acli-version-resolver.sh 2>/dev/null
```

If the script is unavailable or returns non-zero, fall back to a WebFetch of the latest release from the acli releases endpoint. Present the suggestion as a pre-filled config value:

```
Suggested ACLI_VERSION: 1.x.y  (resolved via acli-version-resolver.sh)
Suggested ACLI_SHA256: <checksum>

Accept these values? [Y/n]
```

Write `commands.acli_version` and `commands.acli_sha256` to `.claude/dso-config.conf` on acceptance.

### Step 2c: Infrastructure Initialization

After writing `.claude/dso-config.conf`, set up the supporting infrastructure for the host project. These steps ensure the enforcement gates, ticket system, and documentation templates are in place before the first commit.

#### Hook Installation

Install the DSO git pre-commit hooks (`pre-commit-test-gate.sh` and `pre-commit-review-gate.sh`) into the project's hooks directory. Hook installation must account for the detected hook manager:

**Detect hook manager and install accordingly:**

1. **Husky** — if `.husky/` exists, add DSO hook calls to `.husky/pre-commit` (create if absent). **Idempotency**: check whether the hook call already exists before appending to avoid duplicates on re-run:
   ```bash
   HOOKS_DIR="$REPO_ROOT/.husky"
   grep -qF 'pre-commit-test-gate' "$HOOKS_DIR/pre-commit" 2>/dev/null || \
     echo 'bash "$REPO_ROOT/plugins/dso/hooks/dispatchers/pre-commit-test-gate.sh"' >> "$HOOKS_DIR/pre-commit"
   grep -qF 'pre-commit-review-gate' "$HOOKS_DIR/pre-commit" 2>/dev/null || \
     echo 'bash "$REPO_ROOT/plugins/dso/hooks/dispatchers/pre-commit-review-gate.sh"' >> "$HOOKS_DIR/pre-commit"
   ```

2. **pre-commit framework** — if `.pre-commit-config.yaml` exists, add DSO hooks as local hooks in the config.

3. **Bare `.git/hooks/`** — if neither Husky nor the pre-commit framework is detected, install directly into the git hooks directory. Use `git rev-parse --git-common-dir` to find the correct hooks path (supports worktrees and submodules where `.git` may be a file rather than a directory):
   ```bash
   GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
   HOOKS_DIR="$GIT_COMMON_DIR/hooks"
   cp "$REPO_ROOT/plugins/dso/hooks/dispatchers/pre-commit-test-gate.sh" "$HOOKS_DIR/pre-commit-test-gate"
   cp "$REPO_ROOT/plugins/dso/hooks/dispatchers/pre-commit-review-gate.sh" "$HOOKS_DIR/pre-commit-review-gate"
   # Ensure the pre-commit hook calls both
   PRECOMMIT_HOOK="$HOOKS_DIR/pre-commit"
   if [[ ! -f "$PRECOMMIT_HOOK" ]]; then
       echo '#!/usr/bin/env bash' > "$PRECOMMIT_HOOK"
       chmod +x "$PRECOMMIT_HOOK"
   fi
   echo 'bash "$(git rev-parse --git-common-dir)/hooks/pre-commit-test-gate"' >> "$PRECOMMIT_HOOK"
   echo 'bash "$(git rev-parse --git-common-dir)/hooks/pre-commit-review-gate"' >> "$PRECOMMIT_HOOK"
   ```

After hook installation, confirm with the user which hook manager was used and where the hooks were installed.

#### Ticket System Initialization

Initialize the DSO ticket system by creating an orphan branch and setting up the `.tickets-tracker/` directory:

```bash
# Create orphan branch for ticket event storage
cd "$REPO_ROOT"
git checkout --orphan tickets
git rm -rf . --quiet 2>/dev/null || true
mkdir -p .tickets-tracker
echo "# DSO Ticket System" > .tickets-tracker/README.md
git add .tickets-tracker/README.md
git commit -m "chore: initialize ticket system"
git checkout -  # return to previous branch
```

**Push verification:** After creating the orphan branch, push it to the remote and verify push success. If the push fails, warn the user:

```bash
if git push origin tickets 2>&1; then
    echo "Ticket system initialized and pushed successfully."
else
    echo "WARNING: push to origin tickets failed. The ticket system is initialized locally but not synced to remote. Run 'git push origin tickets' when remote access is available."
fi
```

#### Ticket Smoke Test

After initialization, perform a ticket smoke test to verify the system works end-to-end. Create a test ticket and read it back:

```bash
# Smoke test: create and read a ticket
TEST_ID=$(.claude/scripts/dso ticket create task "DSO smoke test — delete me" 2>/dev/null | grep -oE '[0-9a-f]{4}-[0-9a-f]{4}')
if [[ -n "$TEST_ID" ]]; then
    .claude/scripts/dso ticket show "$TEST_ID" > /dev/null 2>&1 && echo "Ticket smoke test PASSED (id: $TEST_ID)" || echo "WARNING: ticket smoke test failed — show returned non-zero"
    .claude/scripts/dso ticket transition "$TEST_ID" open closed --reason="Fixed: smoke test cleanup" 2>/dev/null
else
    echo "WARNING: ticket smoke test failed — could not create test ticket"
fi
```

#### Generate Test Index

If test directories were detected during Phase 1 auto-detection, run `generate-test-index.sh` to build the initial `.test-index` file mapping source files to test files:

```bash
if [[ -n "$TEST_DIRS" ]]; then
    bash "$REPO_ROOT/plugins/dso/scripts/generate-test-index.sh" "$REPO_ROOT" 2>/dev/null && \
        echo "Test index generated." || \
        echo "NOTE: generate-test-index.sh unavailable — create .test-index manually if needed."
fi
```

#### Generate CLAUDE.md

Generate a `CLAUDE.md` at the HOST PROJECT root (not the plugin's `CLAUDE.md`) using the `/dso:generate-claude-md` skill. This file should include:
- Project-specific defaults drawn from `project-understanding.md` and `dso-config.conf`
- Ticket command references (the ticket commands table: create, show, list, transition, etc.)
- CI trigger strategy notes from the onboarding conversation (do NOT assume PR-based workflow)

```
Invoke: /dso:generate-claude-md
```

The generated `CLAUDE.md` must include a Quick Reference table of ticket commands so that future Claude sessions can manage work items without re-reading the full DSO documentation.

#### Copy KNOWN-ISSUES Template

Copy the DSO `KNOWN-ISSUES` template to `.claude/docs/` in the host project:

```bash
KNOWN_ISSUES_SRC="$REPO_ROOT/plugins/dso/docs/templates/KNOWN-ISSUES.md"
KNOWN_ISSUES_DEST="$REPO_ROOT/.claude/docs/KNOWN-ISSUES.md"
if [[ -f "$KNOWN_ISSUES_SRC" ]] && [[ ! -f "$KNOWN_ISSUES_DEST" ]]; then
    mkdir -p "$REPO_ROOT/.claude/docs"
    cp "$KNOWN_ISSUES_SRC" "$KNOWN_ISSUES_DEST"
    echo "KNOWN-ISSUES template copied to .claude/docs/KNOWN-ISSUES.md"
fi
```

#### CI Trigger Strategy

Ask the user about the CI trigger strategy — do NOT assume a PR-based workflow:

```
What events should trigger CI? Common options:
- Pull request (on open, sync, reopen)
- Push to specific branches (e.g., main, develop)
- Manual dispatch only
- Scheduled (cron)

This affects the ci.workflow_name setting and any generated workflow templates.
```

Record the CI trigger strategy in `dso-config.conf` under `ci.workflow_name` and in `.claude/project-understanding.md` under the CI section.

---

### Step 3: Offer /dso:architect-foundation

After writing `.claude/project-understanding.md`, offer the next step:

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
| 2: Socratic Dialogue | Fill gaps in 7 areas | One question at a time, confirmation-based (not rigid menus), skip confirmed areas |
| 3: Completion | Finalize and hand off | Present summary, write .claude/project-understanding.md (detected/user-stated tags), write .claude/design-notes.md (UI projects only: vision, archetypes, golden paths, visual language, accessibility), generate dso-config.conf (ticket prefix, CI workflow examples, ACLI_VERSION), infrastructure init (hook install with Husky/pre-commit framework/.git/hooks manager detection, git-common-dir for worktree support, ticket system orphan branch + .tickets-tracker/ + push verification + smoke test, generate-test-index.sh, CLAUDE.md with ticket commands, KNOWN-ISSUES template, CI trigger strategy), offer /dso:architect-foundation |
