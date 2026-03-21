---
id: dso-9ltc
status: open
deps: []
links: []
created: 2026-03-21T18:13:10Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-ykic
---
# As a DSO practitioner, review agents are composed from source fragments and generated via a build process


## Notes

<!-- note-id: g850cbc3 -->
<!-- timestamp: 2026-03-21T18:13:47Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Description

**What**: Create a build process that composes 6 dedicated code-reviewer agent definitions from shared source fragments. A base template (reviewer-base.md) contains universal guidance (output contract, JSON schema, scoring rules, category mapping, no formatting/linting exclusion, REVIEW-DEFENSE evaluation, write-reviewer-findings.sh procedure). Per-agent delta files add tier-specific instructions (checklist scope, dimension focus). build-review-agents.sh composes base + delta + frontmatter into generated agents/code-reviewer-*.md files. A tool-use hook blocks direct edits to generated files and provides regeneration guidance during merge conflict resolution. The existing review pipeline (REVIEW-WORKFLOW.md, code-review-dispatch.md) remains fully operational — generated agents are available for dispatch but are not wired into any workflow until the classifier story (w21-jtkr) integrates them.

**Why**: Practitioners running /dso:review encounter reviewer findings that violate the required JSON schema — missing fields, wrong score scales, extra top-level keys — forcing re-dispatch cycles that waste tokens and time. These compliance failures are consistent with ~155 lines of procedure loaded as a task prompt (tier 2, the per-invocation prompt) competing for model attention. Promoting universal guidance to agent system prompts (tier 1, set once at agent creation and treated as core identity) maximizes schema adherence. A build process maintains a single source of truth while delivering tier-1 compliance across all 6 agents. Practitioner value is indirect until the classifier story (w21-jtkr) wires generated agents into the review pipeline; this story builds the infrastructure that enables that integration.

**Scope**:
- IN: Base fragment, 6 per-agent delta fragments, frontmatter definitions, build-review-agents.sh, 6 generated agent files, tool-use hook for edit blocking + merge conflict guidance, commit workflow regeneration enforcement
- OUT: Tier routing logic (w21-jtkr), Deep multi-reviewer dispatch (w21-txt8), schema rename (w21-zp4d — becomes update non-agent consumers only), telemetry (w21-0kt1), modification of REVIEW-WORKFLOW.md or code-review-dispatch.md

## Done Definitions

1. build-review-agents.sh reads reviewer-base.md + per-agent delta files and produces 6 agent files in plugins/dso/agents/. Build uses atomic write (temp dir + swap): all 6 files are generated in a temp directory and moved to the target directory only on success. On failure, no agent files are modified. Each generated file includes an embedded content hash of its source inputs (base + that agent's delta).
  <- Satisfies: Single source of truth with tier-1 compliance
2. Each generated agent file has valid YAML frontmatter (name, description, tools, model) and a body containing the full universal guidance + tier-specific instructions. Script references in generated agents use the .claude/scripts/dso shim pattern — no hard-coded plugin paths.
  <- Satisfies: Portable agent definitions
3. Generated agents are invocable via subagent_type: dso:code-reviewer-light, dso:code-reviewer-standard, dso:code-reviewer-deep-correctness, dso:code-reviewer-deep-verification, dso:code-reviewer-deep-hygiene, dso:code-reviewer-deep-arch.
  <- Satisfies: Named agent dispatch
4. Tool-use hook blocks Edit/Write to plugins/dso/agents/code-reviewer-*.md with guidance pointing to source fragments and build-review-agents.sh.
  <- Satisfies: Generated file integrity
5. Tool-use hook detects conflict markers in generated agent files, exits non-zero to block the operation, and prints regeneration guidance pointing to build-review-agents.sh. Post-conflict resolution, the embedded content hash ensures stale content is caught even when markers are cleanly resolved.
  <- Satisfies: Merge safety
6. Commit workflow detects staged changes to source fragments, computes the expected content hash, and blocks if any generated agent file's embedded hash does not match. Regeneration resolves the block.
  <- Satisfies: Staleness prevention
7. No formatting/linting findings rule is present in the base fragment and appears in all 6 generated agents.
  <- Satisfies: Universal review guidance
8. Unit tests verify: (a) build script produces expected output from known inputs, and (b) build script's declared agent list matches the delta files present on disk (no orphaned deltas, no missing deltas).
  <- Satisfies: Build correctness
9. This story does NOT modify REVIEW-WORKFLOW.md, code-review-dispatch.md, or any existing review dispatch logic. The existing review pipeline remains fully operational. Generated agents are available for dispatch but are not wired into any workflow until the classifier story (w21-jtkr) integrates them.
  <- Satisfies: Zero-risk transition
10. Before merging, capture a directional schema compliance baseline by running the existing review pipeline against 3 representative diffs and recording first-attempt schema validation pass/fail from write-reviewer-findings.sh. This baseline is stored in the epic notes for comparison after w21-jtkr integrates the generated agents.
  <- Satisfies: Validation signal

## Considerations

- [Reliability] Atomic build prevents partial updates from leaving inconsistent agent sets
- [Reliability] Content hash enforcement prevents source-to-generated drift across commits, merges, and conflict resolution
- [Portability] DSO shim pattern ensures generated agents work in host projects with non-standard plugin paths
- [Testing] Unit tests verify build mechanics with fixtures; integration-level agent invocation testing belongs in w21-jtkr

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.

