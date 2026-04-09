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

Wait for the user to confirm or correct before continuing. Update the scratchpad with any corrections.

---

## Phase 1.5: Template Selection Gate (Empty Project)

**Condition:** Run this phase ONLY when `detect-stack.sh` returned `"unknown"` (no recognized framework was found). If the stack was detected as anything other than `"unknown"`, skip this phase entirely and proceed directly to Phase 2.

**Goal:** Offer the user a curated set of starter templates so they can bootstrap from a known-good foundation instead of starting from scratch.

### Step 1: Load the Template Registry

Run `parse-template-registry.sh` to fetch available templates:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
REGISTRY_OUTPUT=$(bash "$PLUGIN_SCRIPTS/parse-template-registry.sh" 2>/tmp/template-registry-warn.txt)  # shim-exempt: internal orchestration script
```

**Fallback behavior**: If `$REGISTRY_OUTPUT` is empty (regardless of exit code), the template registry is missing or malformed. In that case:
- Log a warning (do not display to user): append `"WARNING: template registry unavailable — skipping template gate"` to the scratchpad.
- Skip Phase 1.5 silently and proceed directly to Phase 2 (existing manual flow).

Do NOT surface registry errors to the user unless they ask why no templates were offered.

### Step 2: Present Template Menu

Parse `$REGISTRY_OUTPUT` (tab-separated: `name\trepo_url\tinstall_method\tframework_type\tdata_flags`) and present a numbered menu:

```
I didn't detect a recognized framework in this project. Would you like to start from a template?

Available templates:
  1. nextjs       — Next.js application (nava-platform)
  2. flask        — Flask application (nava-platform)
  3. rails        — Ruby on Rails application (nava-platform)
  4. jekyll-uswds — Jekyll + USWDS site (git-clone)

  0. No template — I'll configure this project manually

Enter a number, or press Enter to skip:
```

Present each template on its own numbered line. Always include option `0` (or equivalent "no template" choice) so the user can decline without being forced to pick a template.

### Step 3: Handle User Choice

#### If the user selects a template (options 1–N):

1. Store the template selection in the scratchpad:

```bash
SELECTED_TEMPLATE_NAME="<name>"          # e.g., "nextjs"
SELECTED_TEMPLATE_REPO="<repo_url>"      # e.g., "https://github.com/navapbc/template-application-nextjs.git"
SELECTED_TEMPLATE_INSTALL="<install_method>"  # "nava-platform" or "git-clone"
SELECTED_TEMPLATE_FRAMEWORK="<framework_type>"  # e.g., "node-npm"
SELECTED_TEMPLATE_DATA_FLAGS="<data_flags>"   # e.g., "app_name" (comma-separated, may be empty)

echo "## Template Selection Result" >> "$SCRATCHPAD"
echo "name: $SELECTED_TEMPLATE_NAME" >> "$SCRATCHPAD"
echo "repo_url: $SELECTED_TEMPLATE_REPO" >> "$SCRATCHPAD"
echo "install_method: $SELECTED_TEMPLATE_INSTALL" >> "$SCRATCHPAD"
echo "framework_type: $SELECTED_TEMPLATE_FRAMEWORK" >> "$SCRATCHPAD"
echo "required_data_flags: $SELECTED_TEMPLATE_DATA_FLAGS" >> "$SCRATCHPAD"
```

2. Route to the install path based on `install_method`:
   - **`nava-platform`**: Notify the user that this template uses the nava-platform installer. Collect any required `required_data_flags` values (e.g., `app_name`) one at a time before proceeding. After collection, write the collected values to the scratchpad:
     ```bash
     echo "collected_data: app_name=my-app, node_version=20" >> "$SCRATCHPAD"
     ```
     (comma-separated `key=value` pairs for each flag the user provided)
   - **`git-clone`**: Notify the user that this template will be cloned via `git clone <repo_url>`. No additional data flags are required — write an empty collected_data line:
     ```bash
     echo "collected_data: " >> "$SCRATCHPAD"
     ```

3. After collecting required data (or confirming none needed for git-clone), proceed to the install path. The scratchpad now has the complete `## Template Selection Result` section per the output contract below. The selected framework type fills in the stack area automatically — confirm with the user rather than asking from scratch.

#### If the user declines (option 0 or empty input):

Record in scratchpad:
```bash
echo "## Template Selection Result" >> "$SCRATCHPAD"
echo "Declined — proceeding with manual configuration" >> "$SCRATCHPAD"
```

Proceed to Phase 2 (existing manual flow) unchanged. Do NOT reference templates again during Phase 2.

### Output Contract: Template Selection Result

When a template is selected, the selection result is recorded in the scratchpad under `## Template Selection Result`. This structure is the contract consumed by install path stories:

```
## Template Selection Result
name: <string>               # Template name (e.g., "nextjs")
install_method: <string>     # "nava-platform" or "git-clone"
repo_url: <string>           # Full git URL of the template repo
framework_type: <string>     # Framework type string (e.g., "node-npm", "python-poetry", "ruby-rails", "ruby-jekyll")
required_data_flags: <csv>   # Comma-separated list of data flags collected (empty string if none)
collected_data: <map>        # Key-value pairs for each required_data_flag (e.g., app_name=my-app)
```

This structure is append-only — downstream install path steps read it from the scratchpad to complete installation without re-prompting the user.

---

## Phase 1.6a: nava-platform Template Installation

**Trigger**: Run ONLY when Phase 1.5 selected `install_method: nava-platform`.

Read and execute `phases/1.6a-nava-platform-install.md`.

---

## Phase 1.6b: Jekyll Git Clone Installation

**Trigger**: Run ONLY when Phase 1.5 selected `install_method: git-clone` with `framework_type: jekyll`.

Read and execute `phases/1.6b-jekyll-git-clone-install.md`.

---

## Phase 1.7: Post-Install Re-Detection and Phase 2 Skip

**Trigger:** Run this phase ONLY after Phase 1.6a or Phase 1.6b completes successfully. If no template was installed (user declined in Phase 1.5 or installation failed and manual flow was selected), skip this phase entirely and proceed to Phase 2.

**Goal:** Re-run auto-detection against the freshly scaffolded project, verify the detected framework matches the registry's `framework_type`, record detection results in the scratchpad, and skip Phase 2 entirely — proceeding directly to Phase 3 (DSO infrastructure setup) with configuration inferred from the registry metadata and detection output.

### Step 1: Re-Run detect-stack.sh Against the Installed Project

Now that template files are present in the project directory, re-run `detect-stack.sh` to detect the actual installed framework:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
POST_INSTALL_STACK=$(bash "$REPO_ROOT/.claude/scripts/dso detect-stack.sh" "$REPO_ROOT" 2>/dev/null || echo "unknown")
```

### Step 2: Verify Detected Stack Matches Registry Framework Type

Read the `framework_type` recorded in the scratchpad's `## Template Selection Result` section (written by Phase 1.5):

```bash
REGISTRY_FRAMEWORK_TYPE=$(grep "^framework_type:" "$SCRATCHPAD" | sed 's/^framework_type:[[:space:]]*//')
```

Compare `POST_INSTALL_STACK` against `REGISTRY_FRAMEWORK_TYPE`:

- **If they match** (e.g., `POST_INSTALL_STACK="node-npm"` and `REGISTRY_FRAMEWORK_TYPE="node-npm"`): proceed normally.
- **If they differ** (mismatch): log a warning to the scratchpad but do NOT crash or abort:

```bash
echo "WARNING: post-install stack mismatch — detected='$POST_INSTALL_STACK' registry='$REGISTRY_FRAMEWORK_TYPE' (possible partial install?)" >> "$SCRATCHPAD"
```

Do NOT surface this warning to the user as an error — continue to Step 3 regardless. If `POST_INSTALL_STACK` is `"unknown"` after installation, this typically indicates an incomplete install; record it as a warning and use `REGISTRY_FRAMEWORK_TYPE` as the canonical value for Phase 3 configuration.

### Step 3: Re-Run project-detect.sh to Pick Up Template Files

Re-run `project-detect.sh` to pick up the `package.json`, `pyproject.toml`, CI workflows, and test directories introduced by the template:

```bash
POST_INSTALL_DETECT=$(bash "$REPO_ROOT/.claude/scripts/dso project-detect.sh" "$REPO_ROOT" 2>/dev/null || echo "")

# Refresh file-level detection now that template files are present
[ -f "$REPO_ROOT/package.json" ] && POST_INSTALL_PKG=$(cat "$REPO_ROOT/package.json" 2>/dev/null) || POST_INSTALL_PKG=""
[ -f "$REPO_ROOT/pyproject.toml" ] && POST_INSTALL_PYPROJECT=$(cat "$REPO_ROOT/pyproject.toml" 2>/dev/null) || POST_INSTALL_PYPROJECT=""

# Refresh CI workflow filenames
POST_INSTALL_CI_WORKFLOWS=""
if [ -d "$REPO_ROOT/.github/workflows" ]; then
    POST_INSTALL_CI_WORKFLOWS=$(ls "$REPO_ROOT/.github/workflows"/*.yml "$REPO_ROOT/.github/workflows"/*.yaml 2>/dev/null | xargs -I{} basename {})
fi

# Refresh test directories
POST_INSTALL_TEST_DIRS=""
for candidate in tests test spec __tests__ src/__tests__; do
    [ -d "$REPO_ROOT/$candidate" ] && POST_INSTALL_TEST_DIRS="$POST_INSTALL_TEST_DIRS $candidate"
done
POST_INSTALL_TEST_DIRS="${POST_INSTALL_TEST_DIRS# }"
```

### Step 4: Record Post-Install Detection Results in Scratchpad

Append the re-detection results to the scratchpad under a dedicated section:

```bash
echo "## Post-Install Detection (Phase 1.7)" >> "$SCRATCHPAD"
echo "post_install_stack: $POST_INSTALL_STACK" >> "$SCRATCHPAD"
echo "post_install_detect_output: $POST_INSTALL_DETECT" >> "$SCRATCHPAD"
echo "post_install_package_json: ${POST_INSTALL_PKG:+present}" >> "$SCRATCHPAD"
echo "post_install_pyproject_toml: ${POST_INSTALL_PYPROJECT:+present}" >> "$SCRATCHPAD"
echo "post_install_ci_workflows: ${POST_INSTALL_CI_WORKFLOWS:-none found}" >> "$SCRATCHPAD"
echo "post_install_test_dirs: ${POST_INSTALL_TEST_DIRS:-none found}" >> "$SCRATCHPAD"
```

Update the working detection variables used by later phases to reflect the post-install state:

```bash
# Promote post-install values to primary detection variables for Phase 3 use
STACK_OUT="$POST_INSTALL_STACK"
DETECT_OUT="$POST_INSTALL_DETECT"
CI_WORKFLOWS="${POST_INSTALL_CI_WORKFLOWS:-$CI_WORKFLOWS}"
TEST_DIRS="${POST_INSTALL_TEST_DIRS:-$TEST_DIRS}"
```

### Step 5: Skip Phase 2 — Record Skip Note in Scratchpad

Templates pre-answer the Socratic dialogue questions (stack, commands, architecture, CI, enforcement) via the registry metadata and installed project structure. Phase 2 is therefore redundant after a successful template installation.

Append the skip note to the scratchpad:

```bash
echo "## Phase 2 Status" >> "$SCRATCHPAD"
echo "Phase 2 skipped — template pre-configured" >> "$SCRATCHPAD"
echo "Phase 3 config source: registry framework_type='$REGISTRY_FRAMEWORK_TYPE' + post-install detection output" >> "$SCRATCHPAD"
```

Do NOT ask the user any Socratic dialogue questions from Phase 2. Proceed directly to Phase 3.

### Step 6: Proceed Directly to Phase 3

Proceed directly to Phase 3 (DSO infrastructure setup) without entering Phase 2. Phase 3 configuration is inferred from:

1. **Registry `framework_type`** — read from `REGISTRY_FRAMEWORK_TYPE` (from `## Template Selection Result` scratchpad section)
2. **Post-install detection output** — `POST_INSTALL_STACK`, `POST_INSTALL_DETECT`, and refreshed file-level variables

Phase 3 must use the post-install `STACK_OUT`, `DETECT_OUT`, `CI_WORKFLOWS`, and `TEST_DIRS` values (promoted in Step 4) for all configuration inference — not the original Phase 1 values, which were collected before template installation.

Notify the user before entering Phase 3:

```
Template installation complete. Detected stack: [POST_INSTALL_STACK].
Skipping project dialogue (template pre-configured) — proceeding directly to DSO infrastructure setup.
```

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

If the user provides a Jira project key, write `jira.project=<KEY>` to `.claude/dso-config.conf`. The Jira Bridge connects DSO to Jira via the `JIRA_URL` environment variable.

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

### Step 1.5: Artifact Review Before Writing

Before writing any artifact to disk, present the full content for user review and approval. Do NOT write files without explicit approval.

- **Present each artifact** in a fenced code block so the user can review the complete content before it is written.
- **For files that already exist** (such as `.claude/dso-config.conf` or `CLAUDE.md`), show a diff against the existing content rather than presenting full replacement. Highlight only the lines being added, changed, or removed so the user can see exactly what will change. Showing the existing diff lets the user verify that no existing configuration is being silently overwritten.
- Ask: "Does this look right? Should I write this file?"
- Wait for explicit approval before using the Write tool.

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

#### Deprecated Key Auto-Migration: merge.ci_workflow_name → ci.workflow_name

After reading the existing config, check for the deprecated `merge.ci_workflow_name` key and auto-migrate it to `ci.workflow_name`. This migration is non-blocking — no user prompt is required.

```
Migration logic (run silently during config merge):
1. If merge.ci_workflow_name is present in the existing config:
   a. If ci.workflow_name already exists: skip migration, log that merge.ci_workflow_name
      can be manually removed (it is now superseded by ci.workflow_name).
   b. If ci.workflow_name does NOT already exist: auto-write the value from
      merge.ci_workflow_name into ci.workflow_name, then log a deprecation notice:
      "Note: merge.ci_workflow_name is deprecated — its value has been automatically
      migrated to ci.workflow_name. You may remove merge.ci_workflow_name from your
      dso-config.conf."
2. If merge.ci_workflow_name is not present: no action needed.
```

This deprecation migration ensures existing projects continue to work without manual config edits when upgrading to the `ci.workflow_name` key introduced in a later DSO version.

#### Required Config Keys

Generate all of the following config keys (flat `KEY=VALUE` format). For each key that cannot be auto-detected, apply the fallback behavior described below.

**DSO plugin location** (required):
```
# Absolute path to the DSO plugin directory (resolved via realpath or git rev-parse)
dso.plugin_root=<absolute path to plugins/dso>  # portability-ok
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

**CI job and integration workflow keys** (populated from `project-detect.sh` `ci_workflow_names` output):

```
ci.fast_gate_job=<job name for fast gate — e.g., lint-and-unit>
ci.fast_fail_job=<job name for fast-fail gate — e.g., fast-fail>
ci.test_ceil_job=<job name for test ceiling — e.g., test-all>
ci.integration_workflow=<integration workflow filename from ci_workflow_names>
```

> **Key distinction**: `ci.workflow_name` is the primary CI workflow used by `merge-to-main.sh` for `gh workflow run` (CI trigger recovery). `ci.integration_workflow` identifies the integration test workflow for `/dso:sprint` Phase 6 verification. They may reference the same file or different ones.

Populate these keys from the `ci_workflow_names` (comma-separated) and `ci_workflow_confidence` (high|low) output of `project-detect.sh`.

#### Confidence-Gated CI Workflow Selection

After running `project-detect.sh`, inspect `ci_workflow_confidence` and `ci_workflow_names`:

**When `ci_workflow_confidence=high` AND `ci_workflow_names` contains exactly one entry:**
- Skip the CI clarification question entirely — use the single detected workflow filename as `ci.integration_workflow` without asking.

**When `ci_workflow_confidence=low` OR `ci_workflow_names` contains 2+ comma-separated entries (multiple workflows detected):**
- Present a numbered selection dialogue so the user can identify which workflow maps to which purpose:

```
I detected the following CI workflow files:
  1. ci.yml
  2. ci-slow.yml
  3. deploy.yml

Multiple workflows found (or low confidence in detection). Please identify:
  - Which workflow is your fast-gate (lint + unit tests on PR)?
  - Which is your integration workflow (full test suite)?

Enter the numbers or type filenames directly.
```

Use the user's response to populate `ci.integration_workflow` and the CI job keys. If the user cannot answer immediately, omit the key with an explanatory comment per the fallback behavior below.

**Additional categories to populate**:

| Category | Keys to set | Source |
|----------|-------------|--------|
| `format` | `format.line_length`, `format.indent` | Enforcement answers |
| `ci` | `ci.workflow_name`, `ci.fast_gate_job`, `ci.fast_fail_job`, `ci.test_ceil_job`, `ci.integration_workflow` | Confirmed from workflow filenames + `ci_workflow_names` detection (`ci.workflow_name` replaces deprecated `merge.ci_workflow_name`; see auto-migration above) |
| `commands` | `commands.test`, `commands.lint`, `commands.format` | Commands area answers |
| `jira` | `jira.project` (if Jira integration desired) | User-stated |
| `design` | `design.system_name`, `design.component_library` | Design area answers |
| `tickets` | `tickets.prefix` | Derived from project name (see below) |
| `version` | `version.file_path` | Detected from `version_files` output or user-stated |
| `stack` | `stack` | Detected from `detect-stack.sh` output |
| `test` | `test.suite.<name>.command`, `test.suite.<name>.speed_class` | Commands + detection |

#### version.file_path — Detection from version_files

Populate `version.file_path` from the `version_files` key emitted by `project-detect.sh`. The `version_files` output is a comma-separated list of file paths relative to the project root.

**When `version_files` contains exactly one path**: write that path directly to `version.file_path`:
```
version.file_path=package.json
```

**When `version_files` contains 2 or more paths**: present a numbered selection dialogue so the user can choose the canonical version file:
```
I found multiple version files in this project:
  1. package.json
  2. pyproject.toml

Which file is the single source of truth for the project version? [1/2]
```
Write only the selected repo-root-relative path to `version.file_path`.

**When `version_files` is empty or absent**: omit `version.file_path` from the config and add an explanatory comment:
```
# version.file_path — not detected; set to the file that carries your project version
# Example: version.file_path=package.json
```

#### stack — Detection from detect-stack.sh

Populate the `stack` config key from the `$STACK_OUT` variable detected in Phase 1 (via `detect-stack.sh`). This value is already available in the scratchpad:
```
stack=<value from STACK_OUT — e.g., python, node, ruby-rails, unknown>
```

If `STACK_OUT` is `"unknown"`, write `stack=unknown` and note that the user can update it after framework installation or manual configuration.

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

#### DSO Shim Installation

Before any other infrastructure steps, install the `.claude/scripts/dso` shim that all subsequent commands depend on:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/dso-setup.sh" "$REPO_ROOT" "${CLAUDE_PLUGIN_ROOT}"  # shim-exempt: bootstrap install — shim does not yet exist
```

This is idempotent — safe to re-run on projects that already have the shim installed.

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

#### Prettier Ignore Configuration

If the host project uses Prettier (detected by the presence of `.prettierrc`, `.prettierrc.json`, `.prettierrc.js`, `prettier.config.js`, or `.prettierignore`), add DSO infrastructure directories to `.prettierignore` to prevent Prettier from attempting to format ticket event files and UI discovery cache:

```bash
if [ -f ".prettierignore" ] || [ -f ".prettierrc" ] || [ -f ".prettierrc.json" ] || [ -f ".prettierrc.js" ] || [ -f "prettier.config.js" ]; then
    PRETTIERIGNORE="${PRETTIERIGNORE:-.prettierignore}"
    touch "$PRETTIERIGNORE"
    for dir in ".tickets-tracker/" ".ui-discovery-cache/"; do
        if ! grep -qF "$dir" "$PRETTIERIGNORE"; then
            echo "$dir" >> "$PRETTIERIGNORE"
            echo "Added $dir to .prettierignore"
        fi
    done
fi
```

This prevents Prettier from attempting to format the ticket event store and UI discovery cache, which contain JSON/YAML that Prettier may reformat in ways that break the ticket CLI's parsing.

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
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
if [[ -n "$TEST_DIRS" ]]; then
    bash "$PLUGIN_SCRIPTS/generate-test-index.sh" "$REPO_ROOT" 2>/dev/null && \  # shim-exempt: internal orchestration script
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

#### Optional Tools

After completing required infrastructure setup, recommend optional tools that enhance the DSO workflow. These tools are not required — all workflows fall back to standard alternatives when unavailable.

Present the following as a brief, non-blocking note (do not prompt for input — just inform):

```
Optional recommended tool:

  ast-grep (sg) — structural code search for cross-file dependency discovery
  Install (macOS):  brew install ast-grep
  Install (Linux):  cargo install ast-grep --locked

  When ast-grep is available, dependency discovery uses structural search for
  more precise results. All workflows fall back to grep when it is unavailable.
```

Do NOT block onboarding progress on tool installation — present the suggestion and continue immediately.

#### Semgrep Installation and Test Quality Configuration

After optional tool recommendations, install Semgrep as a static analysis tool and configure test quality settings based on the detected project stack and language.

**Step 1: Install Semgrep**

Attempt to install Semgrep for the detected language stack. Semgrep provides language-aware static analysis rules for Python, JavaScript, TypeScript, Go, Java, and other languages:

```bash
# Attempt Semgrep installation
if command -v semgrep >/dev/null 2>&1; then
    echo "Semgrep already installed: $(semgrep --version)"
elif command -v pip3 >/dev/null 2>&1; then
    pip3 install semgrep 2>/dev/null && echo "Semgrep installed successfully" || SEMGREP_INSTALL_FAILED=true
elif command -v brew >/dev/null 2>&1; then
    brew install semgrep 2>/dev/null && echo "Semgrep installed successfully" || SEMGREP_INSTALL_FAILED=true
else
    SEMGREP_INSTALL_FAILED=true
fi
```

**Graceful degradation:** If Semgrep installation fails, disable the Semgrep gate rather than blocking onboarding. Set `test_quality.tool=bash-grep` as a fallback and continue:

```bash
if [[ "${SEMGREP_INSTALL_FAILED:-}" == "true" ]]; then
    echo "NOTE: Semgrep installation failed — falling back to bash-grep for test quality analysis."
    echo "You can install Semgrep later: pip3 install semgrep"
fi
```

**Step 2: Generate Semgrep config for detected languages**

Based on the project language detection from Phase 1, generate a `.semgrep.yml` config file with language-appropriate Semgrep rules:

```bash
# Generate .semgrep.yml based on detected stack
SEMGREP_CONFIG="$REPO_ROOT/.semgrep.yml"
if [[ ! -f "$SEMGREP_CONFIG" ]]; then
    cat > "$SEMGREP_CONFIG" <<SEMGREP_EOF
rules: []
# Auto-generated by /dso:onboarding
# Add project-specific Semgrep rules here
# Language detected: $STACK_OUT
# See: https://semgrep.dev/docs/writing-rules/
SEMGREP_EOF
    echo "Generated .semgrep.yml for $STACK_OUT"
fi
```

For Python projects, include `p/python` rulesets. For JavaScript/TypeScript projects, include `p/javascript` and `p/typescript` rulesets. Tailor the Semgrep rules to the detected project languages.

**Step 3: Configure test quality settings**

Add test quality configuration to `dso-config.conf`. The `test_quality` config keys control test quality tooling:

```bash
# Test quality configuration keys for dso-config.conf
# test_quality.enabled — enable/disable test quality gates (default: true)
# test_quality.tool — analysis tool: semgrep | bash-grep (fallback if Semgrep unavailable)
```

Write the `test_quality` section to `dso-config.conf`:

```
# Test quality configuration
test_quality.enabled=true
test_quality.tool=semgrep
```

If Semgrep installation failed, write `test_quality.tool=bash-grep` instead. The test quality gate will still function using grep-based pattern matching as a fallback.

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

## Step 6: Offer /dso:architect-foundation (/dso:onboarding)

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

If the user says no or wants to continue manually, proceed to Step 7.

---

## Step 7: Onboarding Integration Offer (/dso:onboarding)

After `/dso:architect-foundation` completes (or is skipped), offer additional onboarding skills that produce durable project artifacts.

**Artifact detection**: Before prompting, check whether the target artifacts already exist:
- Check for `ARCH_ENFORCEMENT.md` — produced by `/dso:architect-foundation`
- Check for `.claude/design-notes.md` (or `design-notes.md` at repo root) — produced by `/dso:onboarding` Phase 3

If both artifacts already exist, skip this step entirely — the onboarding integration is already complete and no additional steps are needed.

**When `/dso:architect-foundation` has not been run** (ARCH_ENFORCEMENT.md does not exist), present an AskUserQuestion:

```
I can run /dso:architect-foundation to set up architectural enforcement scaffolding
(produces ARCH_ENFORCEMENT.md with architecture enforcement rules).

1) Run /dso:architect-foundation
2) Skip — setup is complete, no additional steps

Which would you like?
```

**If the user selects skip**: Setup is complete. No additional steps are needed. Summarize what was learned and close the session.

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
| 1.5: Template Selection Gate | Offer starter templates (empty projects only) | Only when detect-stack returns "unknown"; load parse-template-registry.sh; numbered menu; handle select → store result + route to install path; handle decline → proceed to Phase 2 unchanged; missing registry → skip silently |
| 1.6a: nava-platform Install | Install nava-platform templates | Probe uv/pipx, install CLI, verify, run app install with --data flags, timeout handling, error fallback to manual flow |
| 1.6b: Jekyll Git Clone | Install Jekyll USWDS template | Clone via git, non-empty dir check, captive portal detection, error fallback to manual flow |
| 1.7: Post-Install Re-Detection | Re-detect after template install; skip Phase 2 | Re-run detect-stack.sh + project-detect.sh; verify registry framework_type match (warn on mismatch, do not crash); record post-install detection in scratchpad; skip Phase 2 entirely ("Phase 2 skipped — template pre-configured"); proceed directly to Phase 3 using registry framework_type + detection output |
| 2: Socratic Dialogue | Fill gaps in 7 areas | One question at a time, confirmation-based (not rigid menus), skip confirmed areas |
| 3: Completion | Finalize and hand off | Present summary, write .claude/project-understanding.md (detected/user-stated tags), write .claude/design-notes.md (UI projects only: vision, archetypes, golden paths, visual language, accessibility), generate dso-config.conf (ticket prefix, CI workflow examples, ACLI_VERSION), infrastructure init (hook install with Husky/pre-commit framework/.git/hooks manager detection, git-common-dir for worktree support, ticket system orphan branch + .tickets-tracker/ + push verification + smoke test, generate-test-index.sh, CLAUDE.md with ticket commands, KNOWN-ISSUES template, CI trigger strategy), offer /dso:architect-foundation |
