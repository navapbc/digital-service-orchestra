---
name: update-docs
description: Invoke the doc-writer agent to update project documentation based on recent changes. Scoped to a commit range (default main...HEAD). Use after an epic completes or when documentation is out of sync.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:update-docs requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Update Documentation

Invoke the `dso:doc-writer` agent to review and update project documentation based on recent changes. Accepts an optional commit range to scope the git diff.

## Usage

```
/dso:update-docs                      # Diff scoped to main...HEAD (default)
/dso:update-docs <commit-range>       # Diff scoped to the specified commit range
```

Examples:
- `/dso:update-docs` — updates docs for all commits since main
- `/dso:update-docs HEAD~5..HEAD` — updates docs for the last 5 commits
- `/dso:update-docs abc123..def456` — updates docs for a specific range

---

## Step 1: Resolve the Commit Range

Determine the commit range to use:

- If a `<commit-range>` argument was provided, use it as-is.
- Otherwise, default to `main...HEAD`.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_RANGE="${1:-main...HEAD}"
```

## Step 2: Gather Context

Collect the inputs the doc-writer agent requires:

```bash
# Git diff scoped to the commit range
git diff "$COMMIT_RANGE"

# Recent git log for the range (context for the agent)
git log --oneline "$COMMIT_RANGE"

# Project context
cat "$REPO_ROOT/CLAUDE.md" 2>/dev/null | head -200
```

If `git diff "$COMMIT_RANGE"` returns empty output, inform the user:

> "No changes found in commit range `<commit-range>`. Nothing to document."

And stop — do not dispatch the agent.

## Step 3: Dispatch dso:doc-writer

**Inline dispatch is required — `dso:doc-writer` is an agent file identifier, NOT a valid `subagent_type` value.** The Agent tool only accepts built-in types (`general-purpose`, `Explore`, `Plan`, etc.).

Read `agents/doc-writer.md` inline and dispatch as `subagent_type: "general-purpose"` with `model: "sonnet"`. Pass the agent file content verbatim as the prompt, appending the context below.

```
Agent tool:
  subagent_type: "general-purpose"
  model: "sonnet"
  prompt: |
    {verbatim content of ${CLAUDE_PLUGIN_ROOT}/agents/doc-writer.md}

    --- PER-RUN CONTEXT ---
context:
  epic_context: |
    ## Commit Range
    <commit-range>

    ## Recent Commits
    <output of git log --oneline for the range>

    ## Project Context (from CLAUDE.md)
    <first 200 lines of CLAUDE.md, or "Not available">

  git_diff: |
    <full output of git diff for the commit range>
```

If the git diff is very large (>10,000 lines), warn before dispatching:

> "Warning: git diff is large (<N> lines). The doc-writer agent may truncate context. Consider narrowing the commit range."

## Step 4: Parse and Report Results

After the doc-writer agent returns, parse its output and report results to the user.

### If the agent returned a no-op report:

```
Documentation update: No changes needed

Reason: <reason from agent>

Gates evaluated:
  No-Op Gate:      PASS (fired — no behavioral change)
  User Impact:     FAIL
  Architectural:   FAIL
  Constraint:      FAIL
```

### If the agent made documentation changes:

```
Documentation updated

Files modified:
  - <file path> — <brief description of change>
  - ...

Gates that fired:
  User Impact:     <PASS/FAIL>
  Architectural:   <PASS/FAIL>
  Constraint:      <PASS/FAIL>
```

If the agent reported any CLAUDE.md suggested changes, display them to the user:

```
CLAUDE.md Suggested Changes (requires manual review):
  Section: <section>
  Current: <current text>
  Proposed: <proposed change>
```

### If the agent reported a structural breakout:

Present the breakout notification to the user and ask for confirmation before treating the run as complete.

### If the agent failed or returned malformed output:

Report the error and suggest narrowing the commit range or running again.

---

## Guardrails

- **Never write to CLAUDE.md** — the doc-writer agent emits suggested changes for safeguard files; present them to the user for manual application.
- **Empty diffs stop early** — do not dispatch the agent if there are no changes in the specified range.
- **Commit range is required to be valid git syntax** — if `git diff` errors out, report the error and stop.
