# Skill Evals Guide

Convention guide for writing and running promptfoo-based evals for DSO skills.

## Directory Layout

Each skill that has evals follows this structure:

```
plugins/dso/skills/<skill-name>/
  SKILL.md
  evals/
    promptfooconfig.yaml
```

The `evals/` directory is co-located with the skill's `SKILL.md`. The eval config file must be named `promptfooconfig.yaml` (the name `run-skill-evals.sh` discovers).

## Required Config Fields

Every `promptfooconfig.yaml` must contain these top-level keys:

| Field | Required | Purpose |
|-------|----------|---------|
| `providers` | Yes | List of LLM providers for executing the skill prompt |
| `tests` | Yes | List of test cases with vars and assertions |
| `defaultTest.options.provider` | Recommended | Sets the grader model for `llm-rubric` assertions |
| `prompts` | Recommended | The prompt template(s) that simulate the skill |
| `description` | Recommended | Human-readable name for the eval suite |

`run-skill-evals.sh` validates that `providers` and `tests` exist before running. Missing either causes exit code 1.

## Grader Model Configuration

The grader model evaluates assertion results (e.g., `llm-rubric` judgments). Set it via `defaultTest.options.provider`:

```yaml
# Default: Haiku (fast, cheap, sufficient for most rubrics)
defaultTest:
  options:
    provider: "anthropic:messages:claude-haiku-4-5-20251001"
```

To override with Sonnet for rubrics requiring deeper reasoning:

```yaml
defaultTest:
  options:
    provider: "anthropic:messages:claude-sonnet-4-20250514"
```

Convention: use Haiku unless the rubric requires nuanced judgment that Haiku cannot reliably grade.

## Provider Configuration

The `providers` list defines which model executes the skill prompt (the "subject under test"):

```yaml
providers:
  - id: "anthropic:messages:claude-haiku-4-5-20251001"
```

Use the cheapest model that can meaningfully exercise the skill logic. Evals test whether the prompt elicits correct behavior, not whether a frontier model is smart enough.

## Writing Test Cases

Each test case needs:

- `description`: What the test verifies
- `vars`: Input variables referenced in the prompt template via `{{variable_name}}`
- `assert`: List of assertions to evaluate the output

### Assertion Types

**`llm-rubric`** (primary): An LLM grades the output against a natural-language rubric.

```yaml
assert:
  - type: llm-rubric
    value: >
      The output correctly identifies an oscillation pattern.
      It should report Result as OSCILLATION and note the reversal.
```

Other useful assertion types (from promptfoo):
- `contains` / `not-contains`: Substring checks
- `regex`: Pattern matching
- `javascript`: Custom JS evaluation function

### Minimum Test Coverage

Every eval config should have at least 2 test cases covering the primary decision boundary of the skill (e.g., positive detection vs. negative/clear result).

## Generating a Starter Eval Config

Use `generate-skill-eval.sh` to scaffold a `promptfooconfig.yaml` for a skill that does not yet have one.

### Usage

```bash
.claude/scripts/dso generate-skill-eval.sh <skill-name>
# With a custom skills root (for testing):
.claude/scripts/dso generate-skill-eval.sh --skills-root /tmp/skills <skill-name>
```

### What It Produces

The generator creates `plugins/dso/skills/<skill-name>/evals/promptfooconfig.yaml` with:

- The correct `description`, `providers`, and `defaultTest.options.provider` fields pre-filled (Haiku for both)
- A `prompts` block containing the skill name and a short description extracted from `SKILL.md`
- Two skeleton test cases with `TODO` markers in `description`, `vars.prompt`, and `assert[].value`

The generator will exit with an error if:
- The skill directory does not exist under the skills root
- An `evals/promptfooconfig.yaml` already exists for that skill (it will not overwrite)
- `SKILL.md` contains no parseable description (no frontmatter `description:` field and no H2 heading)

### TODO Convention

`TODO` markers appear only in **assertion values** (`assert[].value`) and input **vars** — never in structural positions such as `providers`, `tests`, or `defaultTest`. This convention allows the commit guard (see below) to distinguish an unfilled scaffold from a deliberate partial config.

Replace every `TODO` before committing. The commit guard will block the commit if any `TODO` remains.

### Worked Example: generate, fill in, commit

**Step 1 — Run the generator:**

```bash
.claude/scripts/dso generate-skill-eval.sh fix-bug
# Output: Generated evals/promptfooconfig.yaml for skill 'fix-bug'
```

**Step 2 — Replace TODO markers with real rubric assertions.**

Open `plugins/dso/skills/fix-bug/evals/promptfooconfig.yaml` and replace each `TODO` block. For example:

Before:
```yaml
  - description: "TODO: Verify fix-bug handles basic input correctly"
    vars:
      prompt: |
        TODO: Replace with a representative input for the fix-bug skill
    assert:
      - type: llm-rubric
        value: >
          TODO: Replace with evaluation criteria derived from the skill
```

After:
```yaml
  - description: "Verify fix-bug classifies a NullPointerException as a mechanical bug"
    vars:
      prompt: |
        The test suite reports: AttributeError: 'NoneType' object has no attribute 'run'
        Classify this bug and propose an investigation path.
    assert:
      - type: llm-rubric
        value: >
          The output should classify the bug as mechanical (not behavioral),
          identify the null/None reference as the root cause category,
          and propose direct code inspection as the first investigation step.
```

**Step 3 — Commit (guard passes because no TODOs remain):**

```bash
git add plugins/dso/skills/fix-bug/evals/promptfooconfig.yaml
# Use /dso:commit — the eval guard runs during the pre-commit hook
```

## Eval Config Commit Guard

The eval config commit guard runs automatically as part of the pre-commit hook (`record-test-status.sh`) whenever a `*/evals/promptfooconfig.yaml` file is staged. It performs a static scan — no API calls, no `npx` required.

### What the Guard Checks

The guard blocks a commit if any staged eval config has:

1. **TODO markers** — any occurrence of the string `TODO` anywhere in the file
2. **Empty tests list** — `tests: []` or a `tests:` key with no list items
3. **No `llm-rubric` assertion** — at least one `type: llm-rubric` entry must be present

### When It Runs

The guard runs on every commit that stages a file matching `*/evals/promptfooconfig.yaml`. It does not run for commits that do not touch eval configs.

### Error Output

When the guard blocks a commit, it prints which file failed and which checks it failed:

```
EVAL CONFIG GUARD: staged eval config(s) are incomplete — commit blocked.
ERROR: Incomplete eval config: plugins/dso/skills/fix-bug/evals/promptfooconfig.yaml
  - contains TODO marker(s)
Fix the issues above before committing.
```

Resolve all listed issues, re-stage the file, and commit again.

## Running Evals

### run-skill-evals.sh

The orchestrator script at `plugins/dso/scripts/run-skill-evals.sh` has two modes: # shim-exempt: internal implementation path reference

**Tier 1 -- Changed-path mapping** (CI / pre-commit):

```bash
.claude/scripts/dso run-skill-evals.sh plugins/dso/skills/oscillation-check/SKILL.md
```

Maps each changed file path to its parent skill directory, finds `evals/promptfooconfig.yaml`, and runs it. Multiple paths can be passed; skills are deduplicated.

**Tier 2 -- Run all evals**:

```bash
.claude/scripts/dso run-skill-evals.sh --all
```

Discovers every `evals/promptfooconfig.yaml` under the skills root and runs them all.

### Prerequisites

- `npx` must be on PATH (Node.js/npm installed)
- `ANTHROPIC_API_KEY` environment variable set (for Anthropic providers)

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All evals passed (or no evals to run) |
| 1 | One or more evals failed |
| 2 | `npx` not available |

### Output

- **stdout**: promptfoo's native JSON output (parseable by CI tools)
- **stderr**: Progress messages and errors

## Interpreting Results

promptfoo reports each test case as pass/fail. For `llm-rubric` assertions, the grader model provides a score and reasoning.

A failing eval means the skill prompt, given the test input, produced output that the grader judged inadequate against the rubric. To investigate:

1. Read the grader's reasoning in the JSON output
2. Check whether the rubric is too strict or the prompt needs adjustment
3. Re-run with `--verbose` for detailed promptfoo output: `npx promptfoo eval --config <path> --verbose`

## Example: oscillation-check

Reference implementation: `plugins/dso/skills/oscillation-check/evals/promptfooconfig.yaml`

This eval tests the oscillation-check skill's core decision: distinguishing oscillation (feedback reverting previous changes) from clear progression (feedback building on previous changes).

Test cases:
1. **OSCILLATION scenario**: Iteration 3 feedback explicitly undoes iteration 2 changes. Grader checks that the output reports OSCILLATION and identifies the reversal.
2. **CLEAR scenario**: Iteration 2 feedback adds new functionality without reverting iteration 1. Grader checks that the output reports CLEAR.

## Smoke Test Procedure

Step-by-step procedure to verify an eval config works and can detect regressions:

### Step 1: Validate the config schema

```bash
# Should exit 0 with no output (validation only, no run)
# The script validates before running -- a quick way to check is:
.claude/scripts/dso run-skill-evals.sh plugins/dso/skills/oscillation-check/SKILL.md 2>&1 | head -5
```

If the config is malformed, you will see: `ERROR: Invalid config ... missing required fields`.

### Step 2: Run the eval

```bash
# Tier 1: run evals for a specific skill
.claude/scripts/dso run-skill-evals.sh plugins/dso/skills/oscillation-check/SKILL.md

# Or Tier 2: run all evals
.claude/scripts/dso run-skill-evals.sh --all
```

### Step 3: Verify pass/fail behavior

All test cases should pass on the current skill prompt. If any fail:
- Check the grader reasoning in the JSON output
- Adjust the rubric if it is overly strict
- Adjust the prompt if the skill output is genuinely wrong

### Step 4: Verify regression detection

To confirm the eval catches regressions, temporarily break the prompt (e.g., remove the instruction to detect oscillation) and re-run. The OSCILLATION test case should now fail. Restore the prompt after verification.

### Step 5: Check Tier 1 path mapping

```bash
# Verify the script discovers the eval when given a skill file path
.claude/scripts/dso run-skill-evals.sh plugins/dso/skills/oscillation-check/SKILL.md 2>&1 | grep -q "Running eval"
echo "Path mapping works: exit $?"
```

## Regression Detection

Evals act as a behavioral specification for each skill. When a skill's prompt is changed (intentionally or accidentally), the eval suite detects whether the change breaks expected behavior.

### How llm-rubric Assertions Catch Regressions

`llm-rubric` assertions evaluate the skill's output against a natural-language rubric using a grader model. When a skill prompt is modified in a way that changes its output, the grader compares the new output against the rubric and fails the assertion if the output no longer satisfies it.

Example regression scenario:
1. A skill prompt is refactored to simplify wording.
2. The refactored prompt omits a key instruction (e.g., "always report a Result field").
3. The skill output no longer includes `Result:` in its response.
4. The `llm-rubric` assertion — which checks for `Result: OSCILLATION` or `Result: CLEAR` — fails.
5. The eval exits non-zero, blocking the change at the pre-commit gate or in CI.

### Testing Both Positive and Negative Cases

Eval configs should cover both sides of the skill's primary decision boundary:

- **Positive case**: Input that should trigger the skill's main detection (e.g., an oscillation scenario). Asserts the skill *does* flag the condition.
- **Negative case**: Input that should not trigger detection (e.g., a clear-progression scenario). Asserts the skill *does not* false-positive.

Testing only positive cases misses regressions where a broken prompt flags everything (false positives). Testing only negative cases misses regressions where a broken prompt flags nothing (false negatives).

### How Daily CI Catches Regressions Automatically

The `eval-daily.yml` GitHub Actions workflow runs all evals on a schedule. When a regression is detected:

1. The workflow exits non-zero.
2. A P0 ticket is automatically created (via the CI failure hook) to track the regression.
3. The ticket captures which skill eval failed and the CI run URL for context.

This means regressions introduced by prompt drift, model behavior changes, or unreviewed edits are surfaced within 24 hours even if pre-commit gates were bypassed.
