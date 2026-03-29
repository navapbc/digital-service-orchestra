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

## Running Evals

### run-skill-evals.sh

The orchestrator script at `plugins/dso/scripts/run-skill-evals.sh` has two modes:

**Tier 1 -- Changed-path mapping** (CI / pre-commit):

```bash
plugins/dso/scripts/run-skill-evals.sh plugins/dso/skills/oscillation-check/SKILL.md
```

Maps each changed file path to its parent skill directory, finds `evals/promptfooconfig.yaml`, and runs it. Multiple paths can be passed; skills are deduplicated.

**Tier 2 -- Run all evals**:

```bash
plugins/dso/scripts/run-skill-evals.sh --all
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
bash plugins/dso/scripts/run-skill-evals.sh plugins/dso/skills/oscillation-check/SKILL.md 2>&1 | head -5
```

If the config is malformed, you will see: `ERROR: Invalid config ... missing required fields`.

### Step 2: Run the eval

```bash
# Tier 1: run evals for a specific skill
plugins/dso/scripts/run-skill-evals.sh plugins/dso/skills/oscillation-check/SKILL.md

# Or Tier 2: run all evals
plugins/dso/scripts/run-skill-evals.sh --all
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
plugins/dso/scripts/run-skill-evals.sh plugins/dso/skills/oscillation-check/SKILL.md 2>&1 | grep -q "Running eval"
echo "Path mapping works: exit $?"
```
