# ADR 0008: Onboarding Confidence Context Schema and Batch Group Protocol

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-04-15

Technical Story: 1a6f-086b (Onboarding skill remediation), 26d0-eccf

## Context and Problem Statement

The `/dso:onboarding` skill previously treated all users as equivalent and all projects as fully unknown. It asked every question in full regardless of the user's experience level and had no mechanism to incorporate existing project documentation. Additionally, the batch execution of setup commands had no named structure — users could not track which group of operations was executing or provide scoped approval at group boundaries.

Two related architectural questions needed answering:

1. How should onboarding adapt its dialogue depth and question set to what it already knows about the user and project, without resorting to ad-hoc if/else branching?
2. How should groups of setup commands be organized and presented so users can give informed approval at logical batch boundaries, and so the system can detect and avoid fresh-repo hook deadlocks?

## Decision Drivers

- Onboarding must degrade gracefully on unknown stacks while accelerating when facts are available from existing docs
- Confidence state must never decrease mid-session (read-only elevation principle)
- Users with high confidence in a given dimension should not be asked questions that presuppose they need guidance
- The hook bootstrap commit on a fresh repo must not block on the pre-commit hooks it is installing
- Batch group names must be stable identifiers that agents and users can reference in logs and approval prompts

## Considered Options

### Confidence Context

1. Ad-hoc boolean flags per question (e.g., `STACK_KNOWN=true`)
2. A flat dictionary of free-form confidence scores
3. A typed schema with enumerated dimensions and a fixed 3-level confidence scale, with an elevation-only update rule

### Batch Groups

1. Unnamed sequential phases ("Phase 1", "Phase 2", …)
2. Named batch groups with explicit membership lists and a single approval gate per group
3. Per-command approval with no grouping

## Decision Outcome

### CONFIDENCE_CONTEXT Schema

Chosen option: **Option 3 — typed schema with 7 enumerated dimensions and a 3-level scale.**

`CONFIDENCE_CONTEXT` is a structured object initialized in Phase 0 and elevated (never lowered) by Phase 0.5 doc scanning. It has exactly 7 dimensions:

| Dimension | Covers |
|-----------|--------|
| `stack` | Tech stack and language detection |
| `app_name` | Project or application name |
| `wcag_level` | Accessibility compliance target |
| `team_size` | Team and collaboration context |
| `ci_platform` | CI/CD system in use |
| `deploy_target` | Hosting and deployment environment |
| `test_framework` | Testing stack and patterns |

Each dimension takes one of three values: `low`, `medium`, or `high`.

**Elevation-only rule**: once a dimension is set to `high`, no subsequent operation may lower it. `medium` may be elevated to `high` but not lowered to `low`. This invariant is enforced by the Phase 0.5 doc scan logic in `scan-docs.sh` and the SKILL.md routing logic.

**Comfort-level initialization** (Phase 0): a single comfort assessment question sets a baseline for all dimensions based on self-reported experience level. Phase 0.5 may then elevate individual dimensions based on concrete evidence from scanned docs, regardless of the comfort baseline.

**Phase 2 routing by confidence**:

| Dimension confidence | Dialogue behavior |
|----------------------|-------------------|
| `high` | Skip question; emit one-line summary instead |
| `medium` | Prefill answer with detected value; ask user to confirm |
| `low` | Ask question in full |

Engineering-specific questions (CI platform, deploy target, test framework) are suppressed on the non-technical path regardless of confidence level.

### Batch Group Protocol

Chosen option: **Option 2 — 6 named batch groups with a single approval gate per group.**

The 6 groups are:

| Group name | Contents |
|------------|----------|
| `dependency-install` | Required and optional dependency checks and installs |
| `scaffold-claude-structure` | `.claude/` directory scaffolding |
| `config-write` | `dso-config.conf` and related config file writes |
| `initial-commit` | First git commit of scaffolded files |
| `hook-install` | Pre-commit hook installation and registration |
| `final-commit` | Commit of hook configuration files |

**Hook install sequencing fix**: `hook-install` is placed in Group 5 (after `initial-commit`) rather than before the first commit. This prevents a fresh-repo deadlock where the pre-commit hooks being installed would block the very commit needed to establish the repo. The hook bootstrap commit in `final-commit` uses `--no-verify` to bypass the hooks it just installed; this is the sole sanctioned use of `--no-verify` in the onboarding flow. The CLAUDE.md rule against `--no-verify` does not apply to this bootstrap case because the hook installation state is not yet consistent at the time of the final commit.

**pre-commit as required dependency**: `pre-commit` is promoted from an optional dependency to a required one. It is checked in Step 0 alongside `bash 4.0+`, `coreutils`, and `git`. Onboarding will not proceed past Step 0 without `pre-commit` available on PATH.

### New artifacts

| File | Role |
|------|------|
| `plugins/dso/skills/onboarding/scan-docs.sh` | Scans `--doc-folder` path for structured facts; outputs confidence elevations |
| Phase 0 in SKILL.md | Comfort assessment + silent stack detection + CONFIDENCE_CONTEXT initialization |
| Phase 0.5 in SKILL.md | Optional `--doc-folder` scan and dimension elevation |

## Consequences

### Positive

- Onboarding adapts to what it already knows — experienced users on well-documented projects complete onboarding faster with fewer redundant questions.
- The elevation-only invariant prevents confidence regression during a session, making routing deterministic once a dimension is set.
- Named batch groups give users a clear mental model of what each approval covers and allow agents to reference group state in logs.
- Moving hook installation to Group 5 eliminates the fresh-repo deadlock without any workaround flags in normal operation.

### Negative

- `pre-commit` is now a hard prerequisite; projects that do not use pre-commit must install it or modify their onboarding flow.
- The CONFIDENCE_CONTEXT schema is fixed at 7 dimensions — adding a new dimension requires a SKILL.md and `scan-docs.sh` update.
- The `--no-verify` use in `final-commit` is a deliberate exception to the project-wide rule; future maintainers must understand the bootstrap context to avoid misapplying the pattern.

### Risks

- If `scan-docs.sh` incorrectly elevates a dimension (false positive), the user may skip a question that would have surfaced important configuration detail. Mitigation: `medium` confidence always asks for confirmation; only `high` confidence silently skips.
- The 3-level scale is coarse — future use cases may require more granularity. This is deferred as a known limitation.
