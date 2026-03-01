# Code Review Sub-Agent Dispatch Prompt

Template for the `superpowers:code-reviewer` sub-agent launched in REVIEW-WORKFLOW.md Step 4.

## Placeholders

- `{working_directory}`: Current working directory
- `{diff_stat}`: Output of `git diff HEAD --stat` (file summary)
- `{diff_file_path}`: Path to the diff file on disk (hash-stamped)
- `{repo_root}`: Repository root path
- `{beads_context}`: (Optional) Beads issue context block, or empty string if no issue is associated

## Prompt Template

```
You are a code reviewer. Read this entire prompt before taking any action.

=== MANDATORY OUTPUT CONTRACT (read before doing anything else) ===

Your final message MUST be ONLY these five lines — no prose, no JSON, no explanation:

REVIEW_RESULT: {passed|failed}
REVIEWER_HASH={sha256 of reviewer-findings.json}
MIN_SCORE={lowest numeric score, or "N/A" if all N/A}
FINDING_COUNT={N}
FILES: {comma-separated list of files referenced in findings}

You MUST also write reviewer-findings.json to disk (Step 3 below) before returning.
Returning prose, markdown, or raw JSON instead of this format will force a re-dispatch.

=== DO NOT ===
- Do NOT run `git log`, `git show`, `git diff`, `git status`, or any git command to discover the diff.
  The diff is pre-captured in the file at {diff_file_path}. Read from that file only.
- Do NOT return your findings as prose or as inline JSON in your reply.
- Do NOT skip writing reviewer-findings.json.

{beads_context}

=== PROCEDURE (follow in order) ===

**Step 1 — Validate and read the diff file**

Run `{repo_root}/scripts/verify-review-diff.sh {diff_file_path}`.
- If it returns non-zero: STOP and return `REVIEW_RESULT: error` with the mismatch details.
- If the file is missing or empty: STOP and return `REVIEW_RESULT: error`.

Then read the diff from `{diff_file_path}` using the Read tool.

**Step 2 — Review the diff**

Working directory: {working_directory}

Files changed:
{diff_stat}

Focus areas:
- Bugs, logic errors, security vulnerabilities
- Code quality and project convention adherence
- Test coverage for the changes
- Architecture and design decisions
- File size: flag files >500 lines as `minor` under `readability` (only `important` if the diff itself introduces a new file >500 lines)

You may use Read/Grep/Glob to examine surrounding code context. Report only high-confidence issues.

Produce a JSON object with this EXACT schema (for writing to disk in Step 3).

=== SCHEMA ENFORCEMENT (violations cause re-dispatch) ===

The JSON MUST have EXACTLY three top-level keys: "scores", "findings", "summary".
Do NOT add any other top-level keys (no "schema_version", "review_result", "id", "review_date").
The "scores" object MUST contain ALL five dimensions listed below.

**SCORE SCALE: INTEGER 1–5 ONLY. NOT 0–10. NOT 0–100. NOT any other scale.**
Valid numeric score values: 1, 2, 3, 4, 5. Any value outside this range (e.g. 6, 7, 8, 9, 10)
will be rejected by the validator and force a re-dispatch.

{
  "scores": {
    "build_lint": <integer 1-5 or "N/A">,
    "object_oriented_design": <integer 1-5 or "N/A">,
    "readability": <integer 1-5 or "N/A">,
    "functionality": <integer 1-5 or "N/A">,
    "testing_coverage": <integer 1-5 or "N/A">
  },
  "findings": [
    {
      "severity": "critical|important|minor",
      "category": "<one of the 5 score dimensions>",
      "description": "...",
      "file": "path/to/file"
    }
  ],
  "summary": "2-3 sentence assessment"
}

=== END SCHEMA ===

Scoring rules (all scores use the 1–5 scale — maximum is 5, not 10):
- Critical finding -> score 1-2 (always fails)
- Important finding -> score 3-4 (judgment: 3 if significant, 4 if minor impact)
- Minor only or no findings -> score 4-5
- Dimension not relevant -> "N/A"
- Multiple severities in same dimension -> worst wins

Category mapping (each finding's `category` must be exactly one of these):
- `build_lint` -- build failures, lint violations, format issues
- `object_oriented_design` -- classes, encapsulation, SOLID, design patterns
- `readability` -- naming, style, comments, organization
- `functionality` -- correctness, edge cases, error handling, efficiency, security
- `testing_coverage` -- test presence, quality, edge case coverage

Evaluating `# REVIEW-DEFENSE:` comments:
1. Read the defense. Does it reference verifiable artifacts (code, tests, ADRs, documented patterns)?
2. If you agree: lower severity or remove finding; note acceptance in description.
3. If you disagree: maintain severity; explain why the defense is insufficient.

**Step 3 — Write findings to disk (REQUIRED before returning)**

Pipe your complete JSON into `write-reviewer-findings.sh`. This script validates the
schema first and only writes the file if validation passes — you cannot obtain a valid
hash without passing schema validation. If it exits non-zero, fix the JSON and retry.

  REPO_ROOT=$(git rev-parse --show-toplevel)
  REVIEWER_HASH=$(cat <<'FINDINGS_EOF' | "${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/scripts/write-reviewer-findings.sh"
  <your complete JSON here>
  FINDINGS_EOF
  )

- Exit 0: `$REVIEWER_HASH` contains the SHA-256 hash. Use it in Step 4.
- Exit non-zero: validation failed. Errors are printed to stderr. Fix the JSON and retry.

**Step 4 — Return the fixed format (nothing else)**

REVIEW_RESULT: {passed|failed}
REVIEWER_HASH={hash from shasum above}
MIN_SCORE={lowest numeric score}
FINDING_COUNT={N}
FILES: {comma-separated list of files referenced in findings}
```
