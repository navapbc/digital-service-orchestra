# Contract: Absence-Claim Anchors

- Signal Name: Absence-Claim Anchors
- Status: accepted
- Scope: validate-review-output.sh, code-reviewer-* agents
- Date: 2026-05-14

## Purpose

`absence-claim-anchors.json` (in this same directory) is the **canonical machine-readable source** for absence-language trigger phrases used by the DSO review pipeline. It defines the set of substring patterns and prefix patterns that, when found in a reviewer finding's `description`, require the finding to include a `verification_evidence` field.

This markdown file (`absence-claim-anchors.md`) documents the contract for humans and LLM reviewer agents.

## Why This Exists

Code reviewers (and LLM-based reviewer agents) sometimes flag symbols, functions, or behaviors as absent — "does not exist", "is not found", "is undefined" — without actually verifying the absence. These findings frequently turn out to be wrong: the symbol exists under a different import path, the function is defined in a base class, or the reviewer is pattern-matching against a superficially similar but distinct name.

The absence-claim anchor mechanism enforces that any finding claiming something is absent must include a `verification_evidence` field showing the command run and its output, proving the absence was actually verified.

## Canonical Anchor List

The full list lives in `absence-claim-anchors.json`. At time of writing, the anchors are:

### Exact-Substring Anchors (`anchors` array)

These phrases, when found anywhere in a finding's `description` string, trigger the `verification_evidence` requirement:

- `is not present`
- `does not exist`
- `is missing`
- `is not found`
- `was not found`
- `are not found`
- `not defined`
- `never defined`
- `is absent`
- `has no`
- `lacks`
- `does not contain`
- `is undefined`
- `no handler`
- `not implemented`

### Prefix Patterns (`anchors_prefix_patterns` array)

These are regex patterns matched against the **start** of the description string:

- `^Missing ` — description beginning with "Missing " (e.g., "Missing import for module X")
- `^No ` — description beginning with "No " (e.g., "No definition found for function Y")

## How `validate-review-output.sh` Uses This File

At validation time (`validate-review-output.sh code-review-dispatch`), each finding's `description` is checked against the anchors. If a match is found:

1. **Soft mode** (no `absence-claim-enforcement-v1` sentinel): emits a `WARNING` on stderr and exits 0.
2. **Hard mode** (`absence-claim-enforcement-v1` sentinel present at `$CLAUDE_PLUGIN_ROOT/contracts/`): exits non-zero with a validation error.

The anchors file is loaded **fail-closed**: if a finding contains absence language and `absence-claim-anchors.json` is missing or malformed at the expected location, the validator exits non-zero with an explanatory error message. This ensures the absence-claim detection system is not silently bypassed.

## How Code Reviewer Agents Use This (S2 Reviewer Instructions)

When your finding description includes any of the phrases listed above, you **MUST** include a `verification_evidence` field in your finding with `command` and `output` sub-fields:

```json
{
  "severity": "important",
  "category": "correctness",
  "description": "The function `process_event` does not exist in handlers.py",
  "file": "src/handlers.py",
  "cited_lines": ["src/handlers.py:42"],
  "cited_excerpt": "result = process_event(payload)",
  "verification_evidence": {
    "command": "grep -rn 'def process_event' src/",
    "output": "(no output — function not found in src/)"
  }
}
```

The `command` field should show the exact shell command you would run to verify the absence. The `output` field should show the actual output (or explicit note that the command produced no results).

## Sentinel File for Hard Enforcement

Hard-mode enforcement is activated by the presence of:

```
${CLAUDE_PLUGIN_ROOT}/contracts/absence-claim-enforcement-v1
```

This file acts as a feature flag. When present, the validator exits non-zero for any absence-language finding without `verification_evidence`. When absent, the validator emits a warning only.

## How to Add New Anchors

1. Edit `absence-claim-anchors.json` in this directory.
2. Bump the `version` field (e.g., `"1.0"` → `"1.1"`).
3. Add the new entry to the appropriate array:
   - Exact-substring match: add a string to `anchors`
   - Start-of-description regex: add a pattern string to `anchors_prefix_patterns`
4. Update the anchor list in this markdown file.
5. Add or update tests in `tests/hooks/test-validate-review-output.sh` to cover the new phrase.
6. Run `bash tests/hooks/test-validate-review-output.sh` to verify.

**Do not embed anchor lists in scripts or agent prompts.** The JSON file is the single source of truth. Scripts should load it at runtime; agent prompts should reference this document.
