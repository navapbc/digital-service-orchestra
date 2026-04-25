# Model Complexity Tiers Reference

> **Audience**: Human skill authors and maintainers. This document is NOT referenced from CLAUDE.md, inline comments, or any agent-visible location. Agents should never need to read this file.
>
> **Date**: 2026-02
> **Status**: Active

## Overview

Sub-agents are dispatched at one of three model tiers. Each tier upgrade increases cost and latency, so assignments must be justified by a specific failure mode that the lower tier cannot handle. The guiding principle: **use the cheapest tier that reliably produces correct output for the task**.

---

## Tier 1: Haiku — Fast Classification & Status Polling

**Use when**: The task has a small, well-defined input/output contract with minimal ambiguity. The agent reads structured data (JSON, exit codes, short text) and produces a simple decision or extraction.

**Boundaries**: If the agent must reason about relationships between multiple entities, interpret nuanced prose, or produce multi-paragraph output, upgrade to Sonnet.

### Examples

| Skill / Context | Task | Why Haiku Suffices |
|-----------------|------|--------------------|
| `/dso:validate-work` | CI status polling (`gh run list` + JSON field extraction) | Single API call, parse one JSON field |
| `/dso:sprint` | File existence checks before dispatching sub-agents | Boolean check, no judgment needed |
| `/dso:sprint` | Classifying changed files into categories (test/src/config) | Pattern matching on file paths |
| `/dso:debug-everything` | Reading a single test's exit code and error line | Structured output, one error to extract |
| General | Checking if a string matches a known pattern | Regex-level classification |
| General | Counting items in a list or summarizing a number | Arithmetic on structured input |

### Cost/Quality Tradeoff

Haiku is ~10x cheaper than Sonnet. Use it aggressively for structured I/O tasks. Upgrade only when you observe haiku producing incorrect classifications on ambiguous inputs.

---

## Tier 2: Sonnet — Code Generation & Structured Reasoning

**Use when**: The task requires generating code, parsing complex/nested output, reasoning about multiple related items, or producing structured multi-step analysis. The agent must exercise judgment but within well-defined constraints.

**Boundaries**: If the agent must evaluate architectural tradeoffs, review code for subtle design issues, or synthesize information across many files with competing concerns, upgrade to Opus.

### Examples

| Skill / Context | Task | Why Sonnet Is Needed |
|-----------------|------|----------------------|
| `/dso:sprint` | Code generation sub-agents (write implementation + tests) | Must produce syntactically and semantically correct code |
| `/dso:review-protocol` | Multi-perspective rubric review of code changes | Must evaluate code against multiple criteria simultaneously |
| `/dso:oscillation-check` | Structural diff analysis between fix attempts | Must identify semantic patterns in code changes, not just textual diffs |
| `/dso:plan-review` | Implementation plan review (sequencing, dependencies) | Must reason about task ordering and identify gaps |
| `/dso:debug-everything` | Routine bug fixes (single-file, clear root cause) | Must read error context and produce a targeted fix |
| `/dso:debug-everything` | Diagnostic sub-agent (Phase B failure inventory) | Must correlate failures across validation categories and cluster related errors |
| `/dso:debug-everything` | Triage sub-agent (Phase C issue creation) | Must cross-reference failure clusters with existing ticket issues and make severity judgments |
| `/dso:validate-work` | Staging deployment check with nested JSON responses | Must navigate nested structures and correlate fields |

### Cost/Quality Tradeoff

Sonnet is ~10x cheaper than Opus. It handles the vast majority of code generation and analysis tasks. Upgrade to Opus only when the task involves cross-cutting architectural concerns or high-blast-radius files where subtle errors have outsized impact.

---

## Tier 3: Opus — Architectural Analysis & High-Stakes Review

**Use when**: The task requires evaluating architectural tradeoffs, reviewing changes to infrastructure/configuration that affect the entire project, or synthesizing information across many files where subtle errors have outsized blast radius.

**Boundaries**: If you're reaching for Opus, verify the task genuinely involves cross-cutting concerns or high-blast-radius files. A complex single-file bug fix is still Sonnet territory.

### Examples

| Skill / Context | Task | Why Opus Is Needed |
|-----------------|------|---------------------|
| `/dso:plan-review` | Design review (API contracts, data model changes) | Must evaluate architectural coherence across system boundaries |
| `/dso:debug-everything` Phase G | Complex multi-file bugs spanning multiple modules | Must hold full system context to trace subtle interaction bugs |
| `/dso:sprint` | Code review of high-blast-radius files (see list below) | Subtle errors in these files cascade across the entire project |
| General | Reviewing changes to pipeline stage ordering or dependencies | Must reason about 9-stage pipeline interactions |
| General | Evaluating tradeoffs between competing design approaches | Must weigh multiple non-obvious factors simultaneously |

### High-Blast-Radius Files (Always Use Opus for Review)

Changes to these files affect project-wide behavior. Code review sub-agents for these paths must use Opus:

```
.claude/skills/**
.claude/hooks/**
.claude/docs/**
CLAUDE.md
.github/workflows/**
scripts/**
.pre-commit-config.yaml
Makefile
```

### Cost/Quality Tradeoff

Opus is the most expensive tier. Every Opus assignment should cite a specific failure mode: "Sonnet missed X because it couldn't reason about Y." If you can't articulate that failure mode, use Sonnet.

---

## Anti-Patterns: Common Mis-Assignments

These are real examples found during audit. Each shows a model assignment that is too low for the task's actual complexity.

### Haiku Assigned to Tasks Requiring Judgment

| Skill | Task | Problem | Correct Tier |
|-------|------|---------|--------------|
| `/dso:debug-everything` | Critic review of complex multi-file fixes | Haiku misses subtle architectural issues in fix correctness | **Sonnet** |
| `/dso:debug-everything` | Post-batch validation parsing complex type errors | Initially flagged, but audit determined these agents relay structured PASS/FAIL output from scripts — no judgment needed | **Haiku** (confirmed) |
| `/dso:validate-work` | Local validation parsing structured script output | Runs validate.sh and parses structured PASS/FAIL lines — mechanical output relay | **Haiku** (confirmed) |
| `/dso:validate-work` | Ticket health running validate-issues.sh | Runs validate-issues.sh and ticket commands that emit structured counts — no relationship reasoning needed | **Haiku** (confirmed) |
| `/dso:validate-work` | Staging deployment check with nested JSON | Nested JSON correlation requires structured reasoning | **Sonnet** |

### The Pattern

The common mistake is assigning Haiku to a task that *looks* like simple output parsing but actually requires **judgment about ambiguous output**. If the agent must decide whether an output represents a real problem or noise, that's Sonnet territory.

---

## Escalation Policy

When a sub-agent fails at its assigned tier, retry at the next tier up:

```
haiku (fail) → sonnet (retry) → opus (retry) → report failure to orchestrator
```

- **One retry per tier**: Don't retry at the same tier with the same input.
- **Log the escalation**: Note which tier failed and why, so the skill can be updated.
- **Update the skill**: If a task consistently escalates, update its default tier. Three escalations for the same task type means the default tier is wrong.

---

## Inline Comment Convention

When assigning a model in skill code, use a self-contained inline comment that explains the tier choice. Do NOT reference this file or any external documentation in the comment.

### Format

```
model="<tier>"  # Tier <N>: <specific reason this tier is needed>
```

### Good Examples

```python
model="haiku"   # Tier 1: CI status check — single JSON field extraction
model="haiku"   # Tier 1: file existence check — boolean result
model="sonnet"  # Tier 2: code generation — must produce correct implementation + tests
model="sonnet"  # Tier 2: complex output parsing — mypy errors require judgment
model="sonnet"  # Tier 2: multi-perspective rubric review — evaluates against 4 criteria
model="opus"    # Tier 3: design review — must evaluate architectural coherence
model="opus"    # Tier 3: high-blast-radius file review — changes to hooks affect all agents
```

### Bad Examples

```python
model="sonnet"  # Code gen                          # Too vague — why not haiku?
model="opus"    # Complex task                       # "Complex" is meaningless
model="haiku"   # See MODEL-TIERS.md for rationale   # Never reference this file
model="sonnet"  # Default                            # No rationale at all
```

### Rule

The comment must be **self-contained**: anyone reading the inline comment should understand why that tier was chosen without consulting any external document.

---

## Decision Checklist for Skill Authors

When assigning a model tier to a sub-agent task, answer these questions:

1. **Is the input/output contract simple and unambiguous?** (single field, boolean, count) -> Haiku
2. **Must the agent generate code or reason about multiple related items?** -> Sonnet
3. **Must the agent evaluate architectural tradeoffs or review high-blast-radius files?** -> Opus
4. **Can you articulate a specific failure mode for the lower tier?** If not, use the lower tier.
5. **Add a self-contained inline comment** explaining your choice.
