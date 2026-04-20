---
name: onboarding
description: Use when starting a new project or joining an existing one — conducts a Socratic dialogue to build a shared understanding of the project's stack, commands, architecture, infrastructure, CI pipeline, design system, and enforcement preferences.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
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

## Onboarding Overview

**This is a one-time setup.** DSO onboarding configures your project so all DSO workflows (`/dso:sprint`, `/dso:brainstorm`, etc.) know your tech stack, commands, and enforcement rules.

At the end of this process, three artifacts will be written:
- **`project-understanding.md`** — records your tech stack, architecture, commands, and CI pipeline
- **`.claude/dso-config.conf`** — configures DSO workflow commands, paths, and enforcement settings
- **`.claude/scripts/dso`** (shim) — CLI entrypoint for all DSO operations

Work through each phase below. Answer what you know and skip what doesn't apply.

---

## Phase 0: Comfort Assessment (/dso:onboarding)

**Goal:** Before showing any detection output or asking project questions, calibrate explanation style with a single comfort-level question, run detection silently, assign confidence levels to all 7 dimensions, and initialize the CONFIDENCE_CONTEXT object in the scratchpad.

### Step 0.1: Comfort Level Question (first user interaction)

Display the following question **before any auto-detection output, before any dependency scan results, and before any other questions**:

```
Before we begin, I'd like to calibrate how I explain things.
Are you more comfortable with technical engineering details, or would you prefer plain-language explanations?

1) Technical — I'm comfortable with engineering terms, CLI commands, and configuration details
2) Non-technical — Plain language please; skip the jargon where possible

(Enter 1 or 2)
```

Record the answer as `COMFORT_LEVEL`:
- If the user enters `1` (or "technical"): `COMFORT_LEVEL="technical"`
- If the user enters `2` (or "non-technical"): `COMFORT_LEVEL="non_technical"`
- If no answer or ambiguous: default to `COMFORT_LEVEL="non_technical"` (safer, more guided path)

### Step 0.1a: Permissions Mode Instruction

Immediately after recording `COMFORT_LEVEL`, display this advisory message before proceeding to any detection:

```
Onboarding writes ~30 files and runs setup scripts. To avoid approving each one individually,
consider switching to auto-accept mode now: press Shift+Tab in the input box to cycle through
permission modes until "auto" is shown, or accept all prompts with 'y' when asked.

You can switch back to your preferred mode any time by pressing Shift+Tab again.
```

This is advisory — do not wait for a response. Continue to Step 0.2 immediately.

### Step 0.2: Stack and Project Auto-Detection

Run detection scripts **silently** (before showing output to the user):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
DETECT_OUT=$(bash "$REPO_ROOT/.claude/scripts/dso project-detect.sh" "$REPO_ROOT" 2>/dev/null || echo "")
STACK_OUT=$(bash "$REPO_ROOT/.claude/scripts/dso detect-stack.sh" "$REPO_ROOT" 2>/dev/null || echo "unknown")
```

These results are reused in Phase 1 — do NOT re-run detect-stack.sh or project-detect.sh again in Phase 1 Step 1. Reference the `$DETECT_OUT` and `$STACK_OUT` variables set here.

Also read supporting project files silently:

```bash
# Node / JavaScript ecosystem
[ -f "$REPO_ROOT/package.json" ] && PACKAGE_JSON=$(cat "$REPO_ROOT/package.json" 2>/dev/null) || PACKAGE_JSON=""

# Detect pre-commit hooks
HUSKY_HOOK=""
[ -f "$REPO_ROOT/.husky/pre-commit" ] && HUSKY_HOOK=$(cat "$REPO_ROOT/.husky/pre-commit" 2>/dev/null)
PRECOMMIT_CONFIG=""
[ -f "$REPO_ROOT/.pre-commit-config.yaml" ] && PRECOMMIT_CONFIG=$(cat "$REPO_ROOT/.pre-commit-config.yaml" 2>/dev/null)

# Discover CI workflows
CI_WORKFLOWS=""
if [ -d "$REPO_ROOT/.github/workflows" ]; then
    CI_WORKFLOWS=$(ls "$REPO_ROOT/.github/workflows"/*.yml "$REPO_ROOT/.github/workflows"/*.yaml 2>/dev/null | xargs -I{} basename {} 2>/dev/null || echo "")
fi

# Discover test directories
TEST_DIRS=""
for candidate in tests test spec __tests__ src/__tests__; do
    [ -d "$REPO_ROOT/$candidate" ] && TEST_DIRS="$TEST_DIRS $candidate"
done
TEST_DIRS="${TEST_DIRS# }"
```

### Step 0.3: Confidence Level Assignment

Assign confidence levels (`high` / `medium` / `low`) for all 7 dimensions based on the detection output collected in Step 0.2:

#### Confidence Assignment Rules

| Dimension | Assignment rule |
|-----------|----------------|
| **stack** | `high` if `STACK_OUT` is a recognized named stack (e.g., `"node-npm"`, `"python-poetry"`, `"ruby-rails"`); `low` if `STACK_OUT` is `"unknown"` |
| **commands** | `high` if `DETECT_OUT` includes test and build command entries; `medium` if test directories were found but commands not confirmed; `low` otherwise |
| **architecture** | `medium` if multiple source directories were detected; `low` otherwise |
| **infrastructure** | `low` by default (no automated detection exists for this area) |
| **ci** | `high` if CI workflow files were found in `.github/workflows/` AND `DETECT_OUT` contains `ci_workflow_confidence=high` with exactly one entry; `medium` if multiple workflows found or `ci_workflow_confidence=low`; `low` if no `.github/workflows/` directory found |
| **design** | `medium` if `package.json` was found with a UI framework reference; `low` otherwise |
| **enforcement** | `high` if `.pre-commit-config.yaml` or `.husky/` was found; `low` otherwise |

Apply the rules above to produce a confidence level value (`high`, `medium`, or `low`) for each of the 7 dimensions. Examples:

- `STACK_OUT="node-npm"` → stack confidence: `high`
- `STACK_OUT="unknown"` → stack confidence: `low`
- `.github/workflows/ci.yml` found, `ci_workflow_confidence=high` → ci confidence: `high`
- No `.github/workflows/` → ci confidence: `low`

### Step 0.4: Initialize Confidence Context Object in Scratchpad

After completing Steps 0.1–0.3, write the `CONFIDENCE_CONTEXT` object (the `confidence_context` signal) to the scratchpad under a dedicated section header. Schema contract: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/confidence-context.md`.

```bash
SCRATCHPAD_PHASE0=$(mktemp /tmp/onboarding-phase0-XXXXXX.md)
cat > "$SCRATCHPAD_PHASE0" <<EOF
## CONFIDENCE_CONTEXT
\`\`\`json
{
  "dimensions": {
    "stack": "<high|medium|low>",
    "commands": "<high|medium|low>",
    "architecture": "<high|medium|low>",
    "infrastructure": "<high|medium|low>",
    "ci": "<high|medium|low>",
    "design": "<high|medium|low>",
    "enforcement": "<high|medium|low>"
  },
  "comfort_level": "$COMFORT_LEVEL",
  "detected_stack": "$STACK_OUT",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
}
\`\`\`
EOF
```

Replace each `<high|medium|low>` placeholder with the actual confidence level determined in Step 0.3. This object is written to `$SCRATCHPAD_PHASE0` (a temp file) because `$SCRATCHPAD` does not yet exist — Phase 1 Step 2 creates it. After Phase 1 Step 2 initializes `$SCRATCHPAD`, append the Phase 0 context:

```bash
# Merge Phase 0 context into main scratchpad (after Phase 1 Step 2 creates $SCRATCHPAD)
cat "$SCRATCHPAD_PHASE0" >> "$SCRATCHPAD"
rm -f "$SCRATCHPAD_PHASE0"
```

This makes `## CONFIDENCE_CONTEXT` visible to all downstream parsers (Phase 2 question routing, S2 doc folder scan, S3 routing logic) that scan `$SCRATCHPAD`.

**Phase 1 scratchpad skip**: Because Step 0.2 already ran `detect-stack.sh` and `project-detect.sh`, Phase 1 Step 1 must **not** re-run these scripts. Phase 1 Step 1 should reference the existing `$DETECT_OUT` and `$STACK_OUT` variables.

**Phase plan update**: When Phase 1 Step 2 writes the phase plan to the scratchpad, include Phase 0 at position 1 (before Phase 1: Auto-Detection). The complete phase list should be: Phase 0: Comfort Assessment → Phase 1: Auto-Detection → Phase 1.5 → Phase 1.6 → Phase 1.7 → Phase 2 → Phase 3.

---

## Phase 0.5: Document Folder Pre-Scan (/dso:onboarding)

**Trigger**: Run ONLY when `--doc-folder <path>` is specified on the onboarding invocation. If omitted, skip this phase entirely and proceed to Phase 1.

**Goal**: Before asking questions, scan the user-specified document folder for structured facts (app name, stack signals, WCAG requirements). Update CONFIDENCE_CONTEXT with any elevated confidence levels found from the doc scan.

**Step 0.5.1: Parse --doc-folder Parameter**
Accept the optional `--doc-folder <path>` flag from the user's invocation. Validate it is a non-empty string and a readable directory before proceeding.

**Step 0.5.2: Invoke scan-docs.sh**
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
CONTEXT_TEMP=$(mktemp /tmp/onboarding-context-XXXXXX.json)
# Extract CONFIDENCE_CONTEXT JSON from $SCRATCHPAD_PHASE0 and write to $CONTEXT_TEMP

SCAN_OUT=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/onboarding/scan-docs.sh" "$DOC_FOLDER" --context-file="$CONTEXT_TEMP" 2>/tmp/scan-docs-warn.txt)
SCAN_EXIT=$?
```

- If scan-docs.sh exits non-zero, log the error to scratchpad and skip Phase 0.5 (do not abort onboarding)
- Binary/large file skips are in /tmp/scan-docs-warn.txt — surface to user: "Note: N files were skipped (binary or too large)"

**Step 0.5.3: Parse Facts and Elevate CONFIDENCE_CONTEXT**
- Parse SCAN_OUT JSON to extract `facts` array and `elevated_dimensions` map
- For each elevated dimension from the doc scan, apply elevation-only update to CONFIDENCE_CONTEXT: new_level = max(existing_level, elevated_level) where high > medium > low
- Never lower any confidence level (contract requirement from `${CLAUDE_PLUGIN_ROOT}/docs/contracts/confidence-context.md`)
- Append a `## DOC_SCAN_FACTS` section to scratchpad with the extracted facts
- Display a brief summary to the user: "Found N facts in your documents — I'll use these to pre-fill answers where possible."

**Step 0.5.4: File Count Cap Warning**
If scan output includes `WARNING:file_cap_reached`, surface to user: "Note: Document scan processed the first 50 files. Additional files were not read."

**Error handling**: Wrap all of Phase 0.5 in a guard — if any step fails (parse error, missing binary, permission denied), log to scratchpad and continue to Phase 1. Phase 0.5 failure must never abort onboarding.

**Security note**: DOC_FOLDER is passed directly to scan-docs.sh which validates path traversal — do not attempt additional path resolution before invoking it.

**Phase plan update**: When Phase 0.5 runs, add it to the phase plan between Phase 0 and Phase 1. When skipped, do not add it.

---

## Batch Group Protocol

This skill organizes its commands into **at most 6 batch groups** (fewer when groups are skipped). Before executing any commands in a batch group, the agent presents a single grouped approval prompt to the user and waits for a response.

### Rules

1. **One approval per group boundary.** At each `## Batch Group N: <name>` boundary, present the user with a single grouped approval:

   ```
   Approve: <group-name> — <brief description of what this batch does>
   ```

   Wait for the user to approve before executing any commands in that group. Do NOT ask again mid-group or between individual commands within the same group boundary.

2. **Execute all commands under one approval.** Once the user approves a batch group, execute ALL commands in that group without requesting further approval until the next `## Batch Group N:` boundary is reached.

3. **Skip silently when the skip-guard is met.** Each batch group has a `<!-- Skip guard: ... -->` comment that specifies the condition under which the entire group is skipped. When the skip-guard condition is met, skip the entire group without presenting an approval prompt. The total approval count decreases accordingly (at most 6, fewer when groups are skipped).

4. **Approval prompt format.** The prompt must always include the group name so the user knows what they are approving. Example:

   ```
   Approve: dependency-install — installs required tools (bash 4+, coreutils, git) and optional analysis tools (ast-grep, semgrep)
   ```

### Batch Group Inventory

The 6 batch groups and their skip conditions are:

| Group | Name | Skip condition |
|-------|------|---------------|
| 1 | dependency-install | No deps missing AND optional deps already installed |
| 2 | scaffold-claude-structure | `.claude/` structure already present and shim already installed |
| 3 | config-write | All config files already exist with current content |
| 4 | initial-commit | All artifacts already committed |
| 5 | hook-install | Hooks already installed AND no new hook artifacts to commit; OR project is not a git repository (skip entirely — ticket system init and hook install both require git) |
| 6 | final-commit | No hook artifacts to commit |

---

## Batch Group 1: dependency-install
<!-- Skip guard: if no deps missing AND optional deps already installed, skip this prompt -->

## Phase 1: Auto-Detection (/dso:onboarding)

**Goal:** Pre-fill as many answers as possible by reading project files BEFORE asking the user anything.

### Step 0: Dependency Pre-Scan (Phase 1 of Y)

Run BEFORE any user interaction or scratchpad initialization. Check for required and optional dependencies and resolve any gaps before proceeding.

**Required dependencies:**

```bash
MISSING_DEPS=()

# Check bash >= 4.0 — use /bin/bash explicitly (macOS ships bash 3.x on PATH)
BASH_VERSION_STR=$(/bin/bash --version 2>/dev/null | head -1)
BASH_MAJOR=$(echo "$BASH_VERSION_STR" | grep -oE 'version [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -z "$BASH_MAJOR" ] || [ "$BASH_MAJOR" -lt 4 ]; then
    MISSING_DEPS+=("bash (>= 4.0, detected: ${BASH_MAJOR:-unknown})")
fi

# Check GNU coreutils (provides GNU date; macOS ships BSD date by default)
if ! date --version >/dev/null 2>&1 && ! gdate --version >/dev/null 2>&1; then
    MISSING_DEPS+=("coreutils (GNU date)")
fi

# Check git
if ! command -v git >/dev/null 2>&1; then
    MISSING_DEPS+=("git")
fi

# Check pre-commit — required for hook management and enforcement gates
if ! command -v pre-commit >/dev/null 2>&1; then
    MISSING_DEPS+=("pre-commit")
fi
```

If `MISSING_DEPS` is non-empty, collect all items into a single install command and **pause for user confirmation before continuing**:

```
The following required tools are missing:
  - <item 1>
  - <item 2>

Install them with:
  brew install bash coreutils git pre-commit python uv

Would you like me to install them for you?

(Adjust the package list to match only what is missing above.)
```

- If Homebrew is unavailable: explain that automated installation is out of scope, list the missing deps, and ask the user to install them manually before re-running `/dso:onboarding`.
- If the user requests installation, perform installation automatically
- If not, wait until the user confirms manual installation.
- Re-run the checks. Abort if any required dep is still missing.

**Optional dependencies (ast-grep, semgrep):**

```bash
HAS_ASG=false; HAS_SEMGREP=false
command -v sg >/dev/null 2>&1 && HAS_ASG=true
command -v semgrep >/dev/null 2>&1 && HAS_SEMGREP=true
```

If either is absent, offer installation:

```
Optional tools not found: ast-grep (sg), semgrep
These improve code analysis but are not required.
Install now? [y/N] (press Enter or say "no" to skip)
```

If the user accepts, run with a 120-second process-level timeout to prevent hanging in restricted network environments. Use pip3 first for semgrep (preferred), then brew as fallback; use brew for ast-grep (no pip3 package):

```bash
# semgrep: pip3-first (same install path used in Phase 3 Step 2c)
if ! command -v semgrep >/dev/null 2>&1; then
    if command -v pip3 >/dev/null 2>&1; then
        timeout 120 pip3 install semgrep 2>/dev/null || \
            { command -v brew >/dev/null 2>&1 && timeout 120 brew install semgrep 2>/dev/null; } || true
    elif command -v brew >/dev/null 2>&1; then
        timeout 120 brew install semgrep 2>/dev/null || true
    fi
fi
# ast-grep: brew only (no pip3 package)
if ! command -v sg >/dev/null 2>&1; then
    command -v brew >/dev/null 2>&1 && timeout 120 brew install ast-grep 2>/dev/null || true
fi
```

- Never block progress if they are absent — if no prompt response is received, default to "N" and skip.
- Never block progress if installation fails or times out — continue without the optional tools.
- Record availability in a variable for later use (e.g., `HAS_ASG`, `HAS_SEMGREP`).

---

### Step 1: Read Project Files for Auto-Detection

**Note:** Phase 0 Step 0.2 already ran `project-detect.sh` and `detect-stack.sh` and captured the results in `$DETECT_OUT`, `$STACK_OUT`, `$PACKAGE_JSON`, `$HUSKY_HOOK`, `$PRECOMMIT_CONFIG`, `$CI_WORKFLOWS`, and `$TEST_DIRS`. Do NOT re-run those scripts here. Reference the existing variables and supplement only with data not already collected:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

# Variables already set by Phase 0 Step 0.2:
#   DETECT_OUT, STACK_OUT, PACKAGE_JSON, HUSKY_HOOK, PRECOMMIT_CONFIG
#   CI_WORKFLOWS, TEST_DIRS

# Read additional project files not covered in Phase 0
# Python ecosystem
[ -f "$REPO_ROOT/pyproject.toml" ] && PYPROJECT=$(cat "$REPO_ROOT/pyproject.toml" 2>/dev/null)
```

Note which understanding areas are already answered by the detection output so you can skip or confirm rather than ask from scratch.

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

After initializing the scratchpad, write the PHASE_PLAN:

```bash
# Write PHASE_PLAN to scratchpad (line-per-entry for easy removal of skipped phases)
echo "" >> "$SCRATCHPAD"
echo "## PHASE_PLAN" >> "$SCRATCHPAD"
echo "Phase 0: Comfort Assessment" >> "$SCRATCHPAD"
echo "Phase 1: Auto-Detection" >> "$SCRATCHPAD"
echo "Phase 1.5: Template Selection Gate" >> "$SCRATCHPAD"
echo "Phase 1.6: Template Installation" >> "$SCRATCHPAD"
echo "Phase 1.7: Post-Install Re-Detection" >> "$SCRATCHPAD"
echo "Phase 2: Socratic Dialogue Loop" >> "$SCRATCHPAD"
echo "Phase 3: Completion" >> "$SCRATCHPAD"
```

Then compute and display the phase counter for Phase 1:

```bash
# Count PHASE_PLAN entries scoped to the ## PHASE_PLAN section (avoids counting "Phase" text elsewhere)
Y=$(awk '/^## PHASE_PLAN/{flag=1; next} /^##/{flag=0} flag && /^Phase /{count++} END{print count+0}' "$SCRATCHPAD")
N=1
echo "(Phase ${N} of ${Y})"  # e.g. "Phase 1 of 6" when all phases are present
```

Display to user: **(Phase 1 of Y)** where Y = number of phase entries remaining in the `## PHASE_PLAN` section. Y starts at 6 when all phases apply; it decreases as optional phases (1.5, 1.6, 1.7, 2) are removed at their skip points.

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

At the start of this phase, use the same awk expression to count `## PHASE_PLAN` entries (Y). Phase 1.5 is always position N=2 (it comes right after Phase 1, before any removals). Display to user: **(Phase 2 of Y)** — e.g. `(Phase 2 of 6)` when all phases apply.

**Condition:** Run this phase ONLY when `detect-stack.sh` returned `"unknown"` (no recognized framework was found). If the stack was detected as anything other than `"unknown"`, skip this phase entirely and proceed directly to Phase 2.

When skipping Phase 1.5/1.6/1.7, remove them from PHASE_PLAN so the counter reflects only phases that actually ran:

```bash
# Remove skipped phases from PHASE_PLAN (patterns must match exactly as written in Step 2 init)
sed -i '/^Phase 1\.5: Template Selection Gate$/d' "$SCRATCHPAD"
sed -i '/^Phase 1\.6: Template Installation$/d' "$SCRATCHPAD"
sed -i '/^Phase 1\.7: Post-Install Re-Detection$/d' "$SCRATCHPAD"
```

Note: if phase names in Step 2's PHASE_PLAN initialization are updated, update these sed patterns to match.

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

At the start of this phase, read the `## PHASE_PLAN` section from `$SCRATCHPAD`. Count total entries (Y). Compute this phase's position N. Display to user: **(Phase N of Y)** — e.g. `(Phase 4 of 6)`.

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

Also remove Phase 2 from PHASE_PLAN since it is being skipped via the template path:

```bash
# Remove Phase 2 from PHASE_PLAN (skipped via template path)
# Pattern must match exactly as written in Step 2 init; update here if the name changes there
sed -i '/^Phase 2: Socratic Dialogue Loop$/d' "$SCRATCHPAD"
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

At the start of this phase, read the `## PHASE_PLAN` section from `$SCRATCHPAD`. Count total entries (Y). Compute this phase's position N. Display to user: **(Phase N of Y)** — e.g. `(Phase 2 of 3)` when phases 1.5/1.6/1.7 were skipped.

**Goal:** Fill gaps in the 7 understanding areas through focused, conversational questions. Present detected configuration for confirmation rather than asking open-ended discovery questions.

### Dialogue Rules

**One question at a time** — never present multiple questions in a single message. Pick the most important unknown and ask about it. Do NOT combine questions in a single sentence or append follow-up questions with "and" or "or" (e.g., "Where does this run? And does it connect to external services?" is a violation — ask only the first question, then wait for the response before asking the next).

**Confirmation over discovery** — when detection already answered an area, present the detected value and ask the user to confirm or correct it. Do not ask from scratch.

**Skip confirmed areas** — if detection already answered an area with confidence, confirm briefly ("I see you're using pytest — is that the main test runner?") rather than asking from scratch.

**Use "Tell me more about..."** to go deeper when an answer is vague or incomplete.

**No rigid menus** — use open-ended questions with natural follow-ups rather than lettered option lists. Ask what the user does, not which letter they pick.

### Confidence Routing

Before asking each question, read the `## CONFIDENCE_CONTEXT` section from `$SCRATCHPAD` and route based on the dimension's confidence level:

| Confidence level | Action |
|-----------------|--------|
| **high** | Skip the question entirely. Show a one-line summary: "Detected [value] — skipping [area] question." |
| **medium** | Show pre-filled detected value: "I detected [value]. Does this look right? [Y/n]" — accept confirmation or correction. |
| **low** (or missing) | Ask normally using the Question Guide below. |

When CONFIDENCE_CONTEXT is absent or a dimension is missing, default to **low** (ask normally).
Doc-folder-elevated confidence (from Phase 0.5) is already reflected in CONFIDENCE_CONTEXT — no special handling needed.

### Non-Technical Path

When `comfort_level` is `"non-technical"`, skip or default engineering-specific questions for non-technical users:

| Area | Non-technical handling |
|------|-----------------------|
| commands | Use detected commands or defaults (`make test` / `make lint`); never ask about npm vs. Docker invocation style |
| ci | Use detected CI workflow filename; skip deep CI trigger configuration questions |
| enforcement | Apply recommended DSO defaults; skip technical gate configuration questions (linting tools, commit message conventions, coverage thresholds) |
| design | Ask only the high-level UI question ("Does this project have a UI layer?"); skip WCAG standard selection and deep accessibility questions — default to WCAG AA |

For non-technical users: confirm detected values rather than asking open-ended engineering questions. Show summaries, not prompts.

### Question Guide by Area

Work through each area in the checklist order, but adapt based on what detection already found.

#### 1. stack

**Confidence routing:**
- **high**: "Detected [stack] — skipping stack question."
- **medium**: "I detected [stack]. Does this look right? [Y/n]"
- **low**: Ask using templates below.

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

**Confidence routing:**
- **high**: "Detected [commands] — skipping commands question."
- **medium**: "I detected [commands]. Does this look right? [Y/n]"
- **low**: Ask using templates below.

Ask about: how to run tests, how to start the dev server, how to lint/format, any project-specific Makefile targets.

Present detected test directories for confirmation:
```
I found these test directories: [TEST_DIRS]. How do you actually run the test suite — is there a make target, a script, or do you run the test runner directly?
```

#### 3. architecture

**Confidence routing:**
- **high**: "Detected [architecture] — skipping architecture question."
- **medium**: "I detected [architecture]. Does this look right? [Y/n]"
- **low**: Ask using templates below.

Ask about: top-level module layout, key service boundaries, any notable design patterns (event sourcing, CQRS, hexagonal, etc.), where the main entry point is.

Ask openly:
```
How would you describe the top-level structure of this project — is it a single deployable unit, a monorepo, or something else? What's the main entry point?
```

#### 4. infrastructure

**Confidence routing:**
- **high**: "Detected [infrastructure] — skipping infrastructure question."
- **medium**: "I detected [infrastructure]. Does this look right? [Y/n]"
- **low**: Ask using templates below.

Ask about: where it runs (cloud provider, on-prem, local-only), databases used, external services or APIs it calls, how secrets are managed.

Ask openly:
```
Where does this project run in production, and what external services or databases does it depend on? How are secrets managed?
```

#### 5. CI

**Confidence routing:**
- **high**: "Detected [ci] — skipping ci question."
- **medium**: "I detected [ci]. Does this look right? [Y/n]"
- **low**: Ask using templates below.

List the actual `.github/workflows/*.yml` filenames discovered in Step 1. Use those filenames to confirm the CI workflow name rather than asking the user to type it from memory.

```
I found these workflow filenames: [CI_WORKFLOWS]. Which one is your primary CI gate — the one that runs on pull requests?
```

If no workflows were found:
```
I don't see any CI workflows yet. What CI system are you planning to use, if any?
```

#### 6. design

**Confidence routing:**
- **high**: "Detected [design] — skipping design question."
- **medium**: "I detected [design]. Does this look right? [Y/n]"
- **low**: Ask using templates below.

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

**Confidence routing:**
- **high**: "Detected [enforcement] — skipping enforcement question."
- **medium**: "I detected [enforcement]. Does this look right? [Y/n]"
- **low**: Ask using templates below.

Ask about: linting tools, commit message conventions, pre-commit hooks in use, code review requirements, test coverage policies.

Present detected hooks for confirmation:
```
I see [.husky/pre-commit present / .pre-commit-config.yaml present / no hooks detected]. What enforcement tools are active — any linters, commit message conventions, or code review requirements a new contributor would need to know?
```

#### 8. Jira Bridge

**MANDATORY PROMPT — always ask this question. Do NOT skip based on project type or assumptions.**

Ask whether the project uses Jira and, if so, confirm the project key:

```
Does this project use Jira for issue tracking? If so, what's the Jira project key (e.g., "MYAPP" or "DSO")?
Note: credentials (JIRA_URL, JIRA_USER, JIRA_API_TOKEN) stay as environment variables — only the project key goes in config.
```

Display to user: "jira.project — records your Jira project key so DSO can sync tickets automatically."

If the user provides a Jira project key, write `jira.project=<KEY>` to `.claude/dso-config.conf`. The Jira Bridge connects DSO to Jira via the `JIRA_URL` environment variable.

#### 9. Figma Design Collaboration

**MANDATORY PROMPT — always ask this question. The user decides yes/no; the model does NOT pre-decide to skip.**
*(Enables sprint-level design gating when Figma is used for UI collaboration.)*

Ask whether the project uses Figma for design collaboration:

```
Does this project use Figma for design collaboration? (yes / no / skip)
Note: credentials (FIGMA_PAT) stay as environment variables — only the feature flag goes in config.
```

Display to user: "design.figma_collaboration — enables Figma design integration. Your Figma token stays as an env var (FIGMA_PAT); only the enabled flag goes in config."

On YES: write `design.figma_collaboration=true` to `.claude/dso-config.conf`.

On no or skip: write `design.figma_collaboration=false` to `.claude/dso-config.conf` as an explicit disabled sentinel.

#### 10. Confluence Documentation Space

*(Optional placeholder — Confluence integration is coming soon. Recording the space key now avoids re-running onboarding later.)*

Ask whether the project uses Confluence:

```
Does this project use Confluence for documentation? If so, what's the space key (e.g., "MYAPP" or "ENG")?
(yes <KEY> / no / skip)
```

On YES: write `confluence.space_key=<KEY>` to `.claude/dso-config.conf`.

On no or skip: write `confluence.enabled=false` to `.claude/dso-config.conf` as an explicit disabled sentinel.

### Phase 2 Gate

When all 7 core areas (stack, commands, architecture, infrastructure, CI, design, enforcement) have at least a basic answer recorded in the scratchpad, ask:

```
I now have a working model of the project across all 7 core areas. Is there anything important I missed — any constraint, convention, or quirk that a new team member would need to know?
```

Note: sections 8 (Jira), 9 (Figma), and 10 (Confluence) must be asked BEFORE reaching this gate — they are mandatory prompts that happen to come after the 7 core areas. "Optional" means the user may decline; it does NOT mean the model may skip asking. The gate requires all 10 sections complete.

Wait for the user's response before proceeding to Phase 3.

---

## Phase 3: Completion (/dso:onboarding)

At the start of this phase, read the `## PHASE_PLAN` section from `$SCRATCHPAD`. Count total entries (Y). This is the final phase, so N = Y. Display to user: **(Phase N of Y)** — e.g. `(Phase 3 of 3)` or `(Phase 6 of 6)`.

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

Artifact review and approval happens **once at the Batch Group 3: config-write boundary**, not per file. Do NOT ask for per-artifact approval inside a batch group. When the Group 3 approval prompt fires, present a consolidated summary of all artifacts to be written in that group, then wait for a single approval before writing any of them.

- **For existing files** (such as `.claude/dso-config.conf` or `CLAUDE.md`), include a diff of existing content vs. proposed changes (lines being added, changed, or removed) in the consolidated Group 3 summary so the user can verify nothing is silently overwritten.
- One approval covers the entire group. Proceed to write all artifacts in the group without pausing between them.

## Batch Group 3: config-write
<!-- Skip guard: if all config files already exist with current content, skip -->

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

Display to user: "dso-config.conf — the workflow settings file that tells DSO how your project is structured (stack, test commands, CI setup). Written to .claude/dso-config.conf."

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

#### Per-Stack Command Defaults

When writing initial config, use these per-stack defaults if the config key is absent:

| Stack | commands.lint | commands.format | commands.format_check |
|-------|--------------|-----------------|----------------------|
| python-poetry | `poetry run ruff check .` | `poetry run ruff format .` | `poetry run ruff format --check .` |
| node-npm / node-yarn | `npx eslint --no-error-on-unmatched-pattern .` | `npx prettier --write .` | `npx prettier --check .` |
| ruby / ruby-bundler | `bundle exec rubocop` | `bundle exec rubocop --autocorrect` | `bundle exec rubocop --dry-run` |
| go | `go vet ./...` | `gofmt -w .` | `gofmt -l .` |

These defaults preserve existing behavior for Python-poetry projects and add first-class support for Node.js, Ruby, and Go projects.

#### Required Config Keys

Generate all of the following config keys (flat `KEY=VALUE` format). For each key that cannot be auto-detected, apply the fallback behavior described below.

**DSO plugin location** (required):
```
# Absolute path to the DSO plugin directory (resolved via realpath or git rev-parse)
dso.plugin_root=<absolute path to the plugin directory>
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
| `commands` | `commands.test`, `commands.lint`, `commands.format`, `commands.format_check` | Commands area answers |
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

## Batch Group 2: scaffold-claude-structure
<!-- Skip guard: if .claude/ structure already present and shim already installed, skip -->

#### DSO Shim Installation

Display to user: "Installing the DSO shim — a short command-line shortcut (.claude/scripts/dso) that routes all DSO operations to the plugin scripts. You will use this for running tickets, tests, and merges."

Before any other infrastructure steps, install the `.claude/scripts/dso` shim that all subsequent commands depend on.

**Shim template location:** The shim template file is at `templates/host-project/dso` relative to the git repo root (i.e., `$REPO_ROOT/templates/host-project/dso`). This is NOT inside the plugin directory. `dso-setup.sh` uses this template to install the shim at `.claude/scripts/dso` in the host project.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
# Verify shim template exists before invoking setup
if [[ ! -f "$REPO_ROOT/templates/host-project/dso" ]]; then
    echo "ERROR: shim template not found at $REPO_ROOT/templates/host-project/dso"
    echo "Cannot install DSO shim — check that the DSO plugin is correctly installed."
    exit 1
fi
bash "$PLUGIN_SCRIPTS/dso-setup.sh" "$REPO_ROOT" "${CLAUDE_PLUGIN_ROOT}"  # shim-exempt: bootstrap install — shim does not yet exist
```

This is idempotent — safe to re-run on projects that already have the shim installed.

## Batch Group 4: initial-commit
<!-- Skip guard: if all artifacts already committed, skip -->

#### Hook Installation

**ORDERING CONSTRAINT — hooks MUST be installed LAST, after all other onboarding artifacts have been committed.** Installing hooks before the initial commit creates a bootstrap deadlock: the review gate requires a passing review, but the review system depends on the files being committed. The correct sequence is:

1. Write all artifacts (project-understanding.md, dso-config.conf, CLAUDE.md, .semgrep.yml, etc.)
2. Create the initial commit containing those artifacts (hooks are not yet active — this commit succeeds)
3. Install hooks after the initial commit completes

Do NOT install hooks earlier in Step 2c, even if the install step appears earlier in the instructions above. Hook installation is always the final infrastructure action.

## Batch Group 5: hook-install
<!-- Skip guard: if hooks already installed, skip -->
<!-- hook-install: bypass-gates -->

**Bypass note:** The hook installation commit uses `--no-verify` to skip the review and test gates. This is intentional and safe: hooks are pre-built plugin components, not custom project code, so there is no meaningful review to perform at this step. The gates are not yet active prior to this commit, and bypassing them here is the designed bootstrap sequence. This does NOT set a precedent for bypassing gates on project code changes.

**Reliability note:** If onboarding is interrupted after group 4 but before group 5 completes, re-running `/dso:onboarding` will detect that artifacts are committed but hooks are not installed, and will resume from group 5.

**Git state validation:** Before committing hook artifacts, verify there is something to commit:

```bash
if git diff --quiet && git diff --staged --quiet; then
    echo "No hook artifacts to commit — skipping hook-install commit."
else
    git add -A
    git commit --no-verify -m "chore: install DSO pre-commit hooks"
fi
```

Display to user: "Installing pre-commit hooks — automated quality checks that run before each git commit to verify tests pass and code has been reviewed. Required for the DSO enforcement pipeline."

Install the DSO git pre-commit hooks (`pre-commit-test-gate.sh` and `pre-commit-review-gate.sh`) into the project's hooks directory. Hook installation must account for the detected hook manager:

**Detect hook manager and install accordingly:**

1. **Husky** — if `.husky/` exists, add DSO hook calls to `.husky/pre-commit` (create if absent). **Idempotency**: check whether the hook call already exists before appending to avoid duplicates on re-run:
   ```bash
   HOOKS_DIR="$REPO_ROOT/.husky"
   grep -qF 'pre-commit-test-gate' "$HOOKS_DIR/pre-commit" 2>/dev/null || \
     echo 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/dispatchers/pre-commit-test-gate.sh"' >> "$HOOKS_DIR/pre-commit"
   grep -qF 'pre-commit-review-gate' "$HOOKS_DIR/pre-commit" 2>/dev/null || \
     echo 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/dispatchers/pre-commit-review-gate.sh"' >> "$HOOKS_DIR/pre-commit"
   ```

2. **pre-commit framework** — if `.pre-commit-config.yaml` exists, add DSO hooks as local hooks in the config.

3. **Bare `.git/hooks/`** — if neither Husky nor the pre-commit framework is detected, install directly into the git hooks directory. Use `git rev-parse --git-common-dir` to find the correct hooks path (supports worktrees and submodules where `.git` may be a file rather than a directory):
   ```bash
   GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
   HOOKS_DIR="$GIT_COMMON_DIR/hooks"
   cp "${CLAUDE_PLUGIN_ROOT}/hooks/dispatchers/pre-commit-test-gate.sh" "$HOOKS_DIR/pre-commit-test-gate"
   cp "${CLAUDE_PLUGIN_ROOT}/hooks/dispatchers/pre-commit-review-gate.sh" "$HOOKS_DIR/pre-commit-review-gate"
   # Ensure the pre-commit hook calls both
   PRECOMMIT_HOOK="$HOOKS_DIR/pre-commit"
   if [[ ! -f "$PRECOMMIT_HOOK" ]]; then
       echo '#!/usr/bin/env bash' > "$PRECOMMIT_HOOK"
       chmod +x "$PRECOMMIT_HOOK"
   fi
   echo 'bash "$(git rev-parse --git-common-dir)/hooks/pre-commit-test-gate"' >> "$PRECOMMIT_HOOK"
   echo 'bash "$(git rev-parse --git-common-dir)/hooks/pre-commit-review-gate"' >> "$PRECOMMIT_HOOK"
   ```

**lint-staged guard (1c71-2e90):** If adding `npx lint-staged` to any pre-commit hook (Husky or bare), first verify that lint-staged is configured — check for a `"lint-staged"` key in `package.json` or a `.lintstagedrc` / `lint-staged.config.js` file. If no lint-staged configuration exists, do NOT add the `npx lint-staged` call to the hook without also adding a configuration. Either (a) ask the user what linters to run on staged files and add a `"lint-staged"` key to `package.json`, or (b) skip the lint-staged hook call entirely. Adding `npx lint-staged` without configuration causes silent no-op pre-commit hooks.

After hook installation, confirm with the user which hook manager was used and where the hooks were installed.

#### Ticket System Initialization

**Git repository guard:** Before running any ticket system init commands, verify this is an initialized git repository. If not, skip this section and warn the user:

```bash
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "WARNING: Not a git repository. Run 'git init' first, then re-run /dso:onboarding to initialize the ticket system."
    # skip ticket system init — cannot create orphan branch without git
fi
```

If the git guard passes, initialize the DSO ticket system by creating an orphan branch and setting up the `.tickets-tracker/` directory:

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

**NAMESPACE CONSTRAINT — applies to ALL generated files (CLAUDE.md, project-understanding.md, and any other artifacts written during onboarding):** Every skill reference written into a generated file MUST use the fully-qualified `/dso:` prefix (e.g., `/dso:sprint`, `/dso:brainstorm`, `/dso:fix-bug`). Short-form references without the namespace prefix (e.g., `/<skill-name>` instead of `/dso:<skill-name>`) are invalid — they violate the DSO namespace policy and will be rejected by `check-skill-refs.sh`. Never write a skill reference without the `/dso:` prefix.

#### Copy KNOWN-ISSUES Template

Copy the DSO `KNOWN-ISSUES` template to `.claude/docs/` in the host project:

```bash
KNOWN_ISSUES_SRC="${CLAUDE_PLUGIN_ROOT}/docs/templates/KNOWN-ISSUES.md"
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
    timeout 120 pip3 install semgrep 2>/dev/null && echo "Semgrep installed successfully" || SEMGREP_INSTALL_FAILED=true
elif command -v brew >/dev/null 2>&1; then
    timeout 120 brew install semgrep 2>/dev/null && echo "Semgrep installed successfully" || SEMGREP_INSTALL_FAILED=true
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

## Batch Group 6: final-commit
<!-- Skip guard: if no hook artifacts to commit, skip -->

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

#### Preplanning Interactivity Probe

Ask the operator whether preplanning should run interactively:

```
When planning new features, would you like me to check in with you at key decisions, or should I run autonomously?
(Options: "yes, check in" / "go ahead on your own" — default: check in with you)

Checking in (default): /dso:preplanning pauses at key decisions to confirm story scope, done definitions, and decomposition with you.
Running autonomously: /dso:preplanning runs without interruption — suitable for CI or batch workflows.
```

**Response normalization:**
- yes / y / check in / pause → `true`
- no / n / autonomous / go ahead → `false`
- Empty / Enter → default `true`
- Ambiguous → ask follow-up: "Just to confirm — would you like me to pause for confirmation (yes) or run without interruption (no)?"

Write the operator's answer as `preplanning.interactive = <answer>` to `dso-config.conf`. If the operator does not respond or presses Enter, default to `true`.

**Explicit overwrite**: unlike other merge-not-overwrite config keys, `preplanning.interactive` must always be overwritten with the operator's answer — even if `preplanning.interactive` already exists in `dso-config.conf` (the repo default written by initial setup is `false`, which the operator must be able to override here):

```bash
# Always write preplanning.interactive — overwrite even if the key already exists
# This is an exception to the general merge-not-overwrite rule for this key.
PREPLANNING_INTERACTIVE="${OPERATOR_PREPLANNING_ANSWER:-true}"
if grep -q "^preplanning\.interactive" "$EXISTING_CONFIG" 2>/dev/null; then
    # Overwrite existing value
    sed -i.bak "s|^preplanning\.interactive.*|preplanning.interactive=$PREPLANNING_INTERACTIVE|" "$EXISTING_CONFIG"
else
    echo "preplanning.interactive=$PREPLANNING_INTERACTIVE" >> "$EXISTING_CONFIG"
fi
```

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

If the user says yes, invoke `/dso:architect-foundation`. When `COMFORT_LEVEL` is set, pass the appropriate flag:

- `COMFORT_LEVEL="non_technical"`: invoke with `--auto` (skips interactive prompts, applies sensible defaults)
- `COMFORT_LEVEL="technical"` or not set: invoke without flags

```
Skill tool:
  skill: "dso:architect-foundation"
  args: "--auto"   # omit if COMFORT_LEVEL != "non_technical"
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
